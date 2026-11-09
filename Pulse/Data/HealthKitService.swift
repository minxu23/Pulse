import Foundation
import HealthKit
import SwiftData

/// Reads wearable / CGM data from Apple Health and merges it into daily records (需求 10).
/// Read-only; fields the user edited by hand are never overwritten.
@MainActor
@Observable
final class HealthKitService {
    static let shared = HealthKitService()

    private let store = HKHealthStore()
    var isSyncing = false
    var lastMessage: String?
    /// What Apple Health holds for each kind of data (count, latest, which apps), from the last check.
    var inventory: [HealthInventoryItem] = []

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let ms = HKUnit.secondUnit(with: .milli)
    private static let mmolL = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let vo2 = HKUnit(from: "ml/kg*min")

    private var quantityIDs: [HKQuantityTypeIdentifier] {
        [.restingHeartRate, .heartRateVariabilitySDNN, .heartRate, .stepCount, .activeEnergyBurned,
         .appleExerciseTime, .vo2Max, .oxygenSaturation, .respiratoryRate, .bloodPressureSystolic,
         .bloodPressureDiastolic, .bloodGlucose, .bodyMass, .distanceWalkingRunning, .distanceCycling,
         .appleSleepingBreathingDisturbances,
         .bodyFatPercentage, .leanBodyMass, .waistCircumference, .heartRateRecoveryOneMinute,
         .walkingHeartRateAverage, .atrialFibrillationBurden]
    }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>(quantityIDs.map { HKQuantityType($0) })
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKCategoryType(.irregularHeartRhythmEvent))
        set.insert(HKCategoryType(.highHeartRateEvent))
        set.insert(HKCategoryType(.lowHeartRateEvent))
        set.insert(HKCategoryType(.appleStandHour))
        set.insert(HKObjectType.workoutType())
        set.insert(HKObjectType.electrocardiogramType())
        return set
    }

    /// True when Pulse reads types the user has not been asked about yet (added in an update).
    func needsAuthorizationUpdate() async -> Bool {
        guard isAvailable else { return false }
        return (try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)) == .shouldRequest
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw NSError(domain: "Pulse", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备不支持健康数据"]) }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Separate opt-in for basic profile information; this does not enable ongoing Health syncing.
    func readProfileForImport() async throws -> HealthProfileImport {
        guard isAvailable else {
            throw NSError(domain: "Pulse", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备不支持 Apple 健康，请手动填写。"])
        }
        let types: Set<HKObjectType> = [HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex),
                                       HKQuantityType(.height), HKQuantityType(.bodyMass)]
        try await store.requestAuthorization(toShare: [], read: types)
        let year = (try? store.dateOfBirthComponents())?.year
        let sex: Sex?
        switch (try? store.biologicalSex())?.biologicalSex {
        case .female: sex = .female
        case .male: sex = .male
        default: sex = nil
        }
        // Read each independently: one unavailable item must not hide the others.
        let height = try? await latestProfileSample(.height)
        let weight = try? await latestProfileSample(.bodyMass)
        return HealthProfileImport(birthYear: year, sex: sex,
                                   heightCm: height.flatMap { value($0, .meterUnit(with: .centi)) }, heightDate: height?.endDate,
                                   weightKg: weight.flatMap { value($0, .gramUnit(with: .kilo)) }, weightDate: weight?.endDate)
    }

    private func latestProfileSample(_ id: HKQuantityTypeIdentifier) async throws -> HKQuantitySample? {
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: .app, options: .strictEndDate)
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                                             sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        return try await query.result(for: store).first
    }

    // MARK: Sync

    // MARK: Updates while the app is open

    private var observers: [HKObserverQuery] = []
    private weak var observedContext: ModelContext?
    private var pendingSync: Task<Void, Never>?

    /// The types whose new samples should show at once: blood pressure (the main target for many), glucose,
    /// weight and VO2max (Docs 9). Background delivery would need another entitlement, so this runs while the
    /// app is open; returning to it syncs anyway.
    private var watchedTypes: [HKSampleType] {
        [.bloodPressureSystolic, .bloodGlucose, .bodyMass, .vo2Max].map { HKQuantityType($0) }
    }

    /// Starts watching Apple Health for new readings and syncs the last days into `ctx` when one arrives;
    /// nil (sample data, Health off) stops it.
    func observeUpdates(into ctx: ModelContext?) {
        observedContext = ctx
        guard ctx != nil, isAvailable else {
            observers.forEach(store.stop)
            observers = []
            return
        }
        guard observers.isEmpty else { return }
        for type in watchedTypes {
            let q = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, error in
                done()
                guard error == nil else { return }
                Task { @MainActor in self?.syncSoon() }
            }
            store.execute(q)
            observers.append(q)
        }
    }

    /// One sync for a burst of updates (a monitor writes systolic, diastolic and pulse together).
    private func syncSoon() {
        pendingSync?.cancel()
        pendingSync = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let ctx = self.observedContext else { return }
            await self.sync(into: ctx, days: 3)
        }
    }

    func sync(into ctx: ModelContext, days: Int = 60) async {
        guard isAvailable, !isSyncing, DataHub.profile(in: ctx)?.usesDemoData != true else { return }
        isSyncing = true
        defer { isSyncing = false }
        let start = Date.app.startOfDay.adding(days: -days)
        var counts: [String: Int] = [:]
        do {
            // Resting HR (device estimate of the day)
            let rhr = try await dailyMean(.restingHeartRate, unit: Self.bpm, from: start)
            for (day, v) in rhr {
                let r = DataHub.record(for: day, in: ctx)
                if !r.isManual("restingHR") { r.restingHR = v.rounded(); r.rhrSource = .device }
            }
            counts["静息心率", default: 0] += rhr.count

            // A band that writes heart rate but never resting heart rate (as some non-Apple wearables do
            // through their own app): estimate it from the lowest overnight heart rate. A watch that writes it
            // on some days is left alone: sleeping heart rate runs lower and would read as a change.
            var writesRHR = !rhr.isEmpty
            if !writesRHR { writesRHR = try await hasSamples(.restingHeartRate, since: Date.app.startOfDay.adding(days: -90)) }
            if !writesRHR {
                let estimated = try await overnightRestingHR(from: start, skip: Set(rhr.keys))
                for (day, v) in estimated {
                    let r = DataHub.record(for: day, in: ctx)
                    if !r.isManual("restingHR") && r.restingHR == nil { r.restingHR = v; r.rhrSource = .device }
                }
                counts["静息心率", default: 0] += estimated.count
            }

            // Overnight HRV / SpO2 / respiration (samples between 00:00 and 09:00)
            let hrv = try await dailyMean(.heartRateVariabilitySDNN, unit: Self.ms, from: start, overnight: true)
            for (day, v) in hrv { let r = DataHub.record(for: day, in: ctx); if !r.isManual("hrv") { r.hrv = v.rounded() } }
            counts["HRV"] = hrv.count

            let resp = try await dailyMean(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, overnight: true)
            for (day, v) in resp { DataHub.record(for: day, in: ctx).respiratoryRate = v.rounded(to: 0.1) }

            let spo2 = try await samples(.oxygenSaturation, from: start)
            for (day, list) in Dictionary(grouping: spo2.filter { $0.startDate.hour < 9 }, by: { $0.startDate.startOfDay }) {
                let vals = list.compactMap { value($0, .percent()) }.map { $0 * 100 }
                let r = DataHub.record(for: day, in: ctx)
                r.spo2Avg = Stats.mean(vals)?.rounded()
                r.spo2Min = vals.min()?.rounded()
            }

            let dist = try await samples(.appleSleepingBreathingDisturbances, from: start)
            for s in dist {
                let unitOptions: [HKUnit] = [HKUnit.count().unitDivided(by: .hour()), .count()]
                if let u = unitOptions.first(where: { s.quantity.is(compatibleWith: $0) }) {
                    DataHub.record(for: s.endDate.startOfDay, in: ctx).breathingDisturbances = s.quantity.doubleValue(for: u).rounded(to: 0.1)
                }
            }

            let vo2 = try await samples(.vo2Max, from: start)
            for s in vo2 { if let v = value(s, Self.vo2) { DataHub.record(for: s.startDate, in: ctx).vo2Max = v.rounded(to: 0.1) } }

            // Body composition: the day's last reading (a smart scale writes weight and body fat together).
            let body: [(HKQuantityTypeIdentifier, HKUnit, Double, ReferenceWritableKeyPath<DailyRecord, Double?>, Double)] = [
                (.bodyFatPercentage, .percent(), 100, \.bodyFatPct, 0.1),
                (.leanBodyMass, .gramUnit(with: .kilo), 1, \.leanMassKg, 0.1),
                (.waistCircumference, .meterUnit(with: .centi), 1, \.waistCm, 0.5),
            ]
            for (id, unit, factor, key, step) in body {
                for s in try await samples(id, from: start) {
                    if let v = value(s, unit) { DataHub.record(for: s.startDate, in: ctx)[keyPath: key] = (v * factor).rounded(to: step) }
                }
            }

            // Heart: walking heart rate, recovery after workouts, AFib History.
            let walking = try await dailyMean(.walkingHeartRateAverage, unit: Self.bpm, from: start)
            for (day, v) in walking { DataHub.record(for: day, in: ctx).walkingHR = v.rounded() }
            let recoveries = try await samples(.heartRateRecoveryOneMinute, from: start)
            for (day, list) in Dictionary(grouping: recoveries, by: { $0.startDate.startOfDay }) {
                DataHub.record(for: day, in: ctx).hrRecovery = Stats.mean(list.compactMap { value($0, Self.bpm) })?.rounded()
            }
            for s in try await samples(.atrialFibrillationBurden, from: start) {
                if let v = value(s, .percent()) { DataHub.record(for: s.endDate, in: ctx).afBurden = (v * 100).rounded(to: 0.1) }
            }

            // Stand hours, and steps by the hour for the last 4 weeks (when in the day someone moves).
            let stood = try await standHours(from: start)
            for (day, n) in stood { DataHub.record(for: day, in: ctx).standHours = n }
            let hourly = try await hourlySteps(from: Date.app.startOfDay.adding(days: -28))
            for (day, list) in hourly { DataHub.record(for: day, in: ctx).stepsByHour = list }

            // Activity totals
            let steps = try await dailySum(.stepCount, unit: .count(), from: start)
            for (day, v) in steps { let r = DataHub.record(for: day, in: ctx); if !r.isManual("steps") { r.steps = Int(v) } }
            let exercise = try await dailySum(.appleExerciseTime, unit: .minute(), from: start)
            for (day, v) in exercise { DataHub.record(for: day, in: ctx).exerciseMinutes = v.rounded() }
            let kcal = try await dailySum(.activeEnergyBurned, unit: .kilocalorie(), from: start)
            for (day, v) in kcal { DataHub.record(for: day, in: ctx).activeKcal = v.rounded() }
            counts["活动"] = steps.count

            // Sleep
            let nights = try await sleepNights(from: start)
            for n in nights {
                let r = DataHub.record(for: n.day, in: ctx)
                guard !r.isManual("sleep") else { continue }
                r.sleepStart = n.start; r.sleepEnd = n.end; r.sleepMinutes = n.asleep.rounded()
                r.deepMinutes = n.deep; r.remMinutes = n.rem; r.awakeMinutes = n.awake
            }
            counts["睡眠"] = nights.count

            // Workouts
            counts["运动"] = try await syncWorkouts(from: start, recoveries: recoveries, ctx: ctx)

            // ECG recordings
            try await syncECG(from: start, ctx: ctx)

            // Blood pressure, glucose, weight → vitals
            counts["指标"] = try await syncVitals(from: start, ctx: ctx)

            // Device notifications → events needing attention
            try await syncDeviceEvents(from: start, ctx: ctx)

            if let p = DataHub.profile(in: ctx) { p.lastSync = .app; p.useHealthKit = true }
            await checkInventory()
            try? ctx.save()
            DataHub.updateBaselineIfNeeded(in: ctx)
            DataHub.refreshAlerts(in: ctx)
            try? ctx.save()
            let summary = counts.filter { $0.value > 0 }.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · ")
            lastMessage = summary.isEmpty ? "同步完成，暂未读取到数据（请确认已在健康 App 中授权）。" : "同步完成：\(summary)"
        } catch {
            lastMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: Query helpers

    private func value(_ s: HKQuantitySample, _ unit: HKUnit) -> Double? {
        s.quantity.is(compatibleWith: unit) ? s.quantity.doubleValue(for: unit) : nil
    }

    private func samples(_ id: HKQuantityTypeIdentifier, from start: Date) async throws -> [HKQuantitySample] {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        return try await desc.result(for: store)
    }

    private func dailyMean(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, overnight: Bool = false) async throws -> [Date: Double] {
        let list = try await samples(id, from: start).filter { !overnight || $0.startDate.hour < 9 }
        var out: [Date: Double] = [:]
        for (day, group) in Dictionary(grouping: list, by: { $0.startDate.startOfDay }) {
            if let m = Stats.mean(group.compactMap { value($0, unit) }) { out[day] = m }
        }
        return out
    }

    private func dailySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date) async throws -> [Date: Double] {
        let pred = HKSamplePredicate.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: nil))
        let query = HKStatisticsCollectionQueryDescriptor(predicate: pred, options: .cumulativeSum,
                                                          anchorDate: start, intervalComponents: DateComponents(day: 1))
        let collection = try await query.result(for: store)
        var out: [Date: Double] = [:]
        collection.enumerateStatistics(from: start, to: .app) { stats, _ in
            if let q = stats.sumQuantity(), q.is(compatibleWith: unit) {
                out[stats.startDate.startOfDay] = q.doubleValue(for: unit)
            }
        }
        return out
    }

    /// Whether Health holds any sample of this kind since `start`.
    private func hasSamples(_ id: HKQuantityTypeIdentifier, since start: Date) async throws -> Bool {
        let desc = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
                                           sortDescriptors: [], limit: 1)
        let found = try await desc.result(for: store)
        return !found.isEmpty
    }

    /// The mean of the lowest tenth of heart-rate readings between midnight and 9 am, per day (only days with
    /// at least 20 readings, and none that already have a resting heart rate).
    private func overnightRestingHR(from start: Date, skip: Set<Date>) async throws -> [Date: Double] {
        let night = try await samples(.heartRate, from: start).filter { $0.startDate.hour < 9 }
        var out: [Date: Double] = [:]
        for (day, list) in Dictionary(grouping: night, by: { $0.startDate.startOfDay }) where !skip.contains(day) {
            let v = list.compactMap { value($0, Self.bpm) }.sorted()
            guard v.count >= 20 else { continue }
            let low = v.prefix(max(3, v.count / 10))
            out[day] = (low.reduce(0, +) / Double(low.count)).rounded()
        }
        return out
    }

    // MARK: Data check

    /// The kinds of data Pulse reads, as the user knows them.
    private var inventoryTypes: [(id: String, label: String, type: HKSampleType)] {
        [("restingHeartRate", "静息心率", HKQuantityType(.restingHeartRate)),
         ("heartRate", "心率", HKQuantityType(.heartRate)),
         ("hrv", "心率变异性", HKQuantityType(.heartRateVariabilitySDNN)),
         ("sleep", "睡眠", HKCategoryType(.sleepAnalysis)),
         ("steps", "步数", HKQuantityType(.stepCount)),
         ("activeEnergy", "活动能量", HKQuantityType(.activeEnergyBurned)),
         ("exercise", "锻炼分钟", HKQuantityType(.appleExerciseTime)),
         ("workouts", "体能训练", HKObjectType.workoutType()),
         ("vo2Max", "最大摄氧量", HKQuantityType(.vo2Max)),
         ("spo2", "血氧", HKQuantityType(.oxygenSaturation)),
         ("respiratory", "呼吸频率", HKQuantityType(.respiratoryRate)),
         ("bloodPressure", "血压", HKQuantityType(.bloodPressureSystolic)),
         ("glucose", "血糖", HKQuantityType(.bloodGlucose)),
         ("weight", "体重", HKQuantityType(.bodyMass)),
         ("bodyFat", "体脂率", HKQuantityType(.bodyFatPercentage)),
         ("walkingHR", "步行平均心率", HKQuantityType(.walkingHeartRateAverage)),
         ("hrRecovery", "心率恢复", HKQuantityType(.heartRateRecoveryOneMinute)),
         ("stand", "站立小时", HKCategoryType(.appleStandHour))]
    }

    /// Asks Apple Health, kind by kind, what it holds for the last 60 days: up to 200 samples, the latest date
    /// and the apps that wrote them. Saved to Documents/health-check.json too, for support.
    func checkInventory(days: Int = 60) async {
        guard isAvailable else { return }
        let start = Date.app.startOfDay.adding(days: -days)
        var out: [HealthInventoryItem] = []
        for t in inventoryTypes {
            let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
            let list: [HKSample] = await withCheckedContinuation { c in
                let query = HKSampleQuery(sampleType: t.type, predicate: pred, limit: 200,
                                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, r, _ in
                    c.resume(returning: r ?? [])
                }
                store.execute(query)
            }
            var note: String? = nil
            if t.id == "sleep" {
                let cats = list.compactMap { $0 as? HKCategorySample }
                let staged = cats.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue && $0.value != HKCategoryValueSleepAnalysis.awake.rawValue }.count
                if !cats.isEmpty && staged == 0 { note = "只有卧床时间，没有睡眠分期" }
            }
            out.append(HealthInventoryItem(id: t.id, label: t.label, count: list.count, latest: list.first?.startDate,
                                           sources: Array(Set(list.map { $0.sourceRevision.source.name })).sorted(), note: note))
        }
        inventory = out
        if let data = try? JSONEncoder().encode(out) { try? data.write(to: Self.inventoryURL, options: .atomic) }
    }

    static var inventoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("health-check.json")
    }

    /// Steps in each clock hour, per day.
    private func hourlySteps(from start: Date) async throws -> [Date: [Int]] {
        let pred = HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: HKQuery.predicateForSamples(withStart: start, end: nil))
        let query = HKStatisticsCollectionQueryDescriptor(predicate: pred, options: .cumulativeSum,
                                                          anchorDate: start, intervalComponents: DateComponents(hour: 1))
        let collection = try await query.result(for: store)
        var out: [Date: [Int]] = [:]
        collection.enumerateStatistics(from: start, to: .app) { stats, _ in
            guard let q = stats.sumQuantity() else { return }
            let day = stats.startDate.startOfDay
            var list = out[day] ?? Array(repeating: 0, count: 24)
            list[min(23, max(0, stats.startDate.hour))] += Int(q.doubleValue(for: .count()))
            out[day] = list
        }
        return out
    }

    /// Hours marked 「站立」 by the watch, per day.
    private func standHours(from start: Date) async throws -> [Date: Int] {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.appleStandHour), predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        let stood = try await desc.result(for: store).filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }
        return Dictionary(grouping: stood, by: { $0.startDate.startOfDay }).mapValues(\.count)
    }

    /// Mean heart rate in each minute between two times (a minute without a sample keeps the one before).
    private func minuteHR(from s: Date, to e: Date) async throws -> [Int] {
        let n = min(360, max(1, Int((e.timeIntervalSince(s) / 60).rounded(.up))))
        let pred = HKQuery.predicateForSamples(withStart: s, end: e)
        let desc = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        var sums = [Double](repeating: 0, count: n), counts = [Int](repeating: 0, count: n)
        for x in try await desc.result(for: store) {
            guard let v = value(x, Self.bpm) else { continue }
            let i = min(n - 1, max(0, Int(x.startDate.timeIntervalSince(s) / 60)))
            sums[i] += v; counts[i] += 1
        }
        guard let first = counts.firstIndex(where: { $0 > 0 }) else { return [] }
        var out: [Int] = []
        var last = Int((sums[first] / Double(counts[first])).rounded())
        for i in 0..<n {
            if counts[i] > 0 { last = Int((sums[i] / Double(counts[i])).rounded()) }
            out.append(last)
        }
        return out
    }

    private struct Night { var day: Date; var start: Date; var end: Date; var asleep: Double; var deep: Double?; var rem: Double?; var awake: Double? }

    private func sleepNights(from start: Date) async throws -> [Night] {
        let pred = HKQuery.predicateForSamples(withStart: start.adding(days: -1), end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        let all = try await desc.result(for: store)
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
        // A night belongs to the morning it ends on (samples ending after 18:00 count toward the next day).
        let byNight = Dictionary(grouping: all, by: { $0.endDate.addingTimeInterval(6 * 3600).startOfDay })
        var nights: [Night] = []
        for (day, samples) in byNight {
            // Prefer the source with the richest data to avoid double counting phone + watch.
            let bySource = Dictionary(grouping: samples, by: { $0.sourceRevision.source.bundleIdentifier })
            // Sleep stages first; a source that writes only 「卧床」 time still counts, as the time asleep.
            func score(_ list: [HKCategorySample]) -> (Double, Double) {
                (minutes(list.filter { asleepValues.contains($0.value) }), minutes(list.filter { $0.value == inBed }))
            }
            guard let best = bySource.values.max(by: { score($0) < score($1) }) else { continue }
            let staged = best.filter { asleepValues.contains($0.value) }
            let asleep = staged.isEmpty ? best.filter { $0.value == inBed } : staged
            guard !asleep.isEmpty, let s = asleep.map(\.startDate).min(), let e = asleep.map(\.endDate).max() else { continue }
            let deep = best.filter { $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue }
            let rem = best.filter { $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
            let awake = best.filter { $0.value == HKCategoryValueSleepAnalysis.awake.rawValue }
            nights.append(Night(day: day, start: s, end: e, asleep: minutes(asleep),
                                deep: deep.isEmpty ? nil : minutes(deep), rem: rem.isEmpty ? nil : minutes(rem),
                                awake: awake.isEmpty ? nil : minutes(awake)))
        }
        return nights
    }

    private func minutes(_ samples: [HKCategorySample]) -> Double {
        samples.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 }
    }

    private func syncWorkouts(from start: Date, recoveries: [HKQuantitySample], ctx: ModelContext) async throws -> Int {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.workout(pred)], sortDescriptors: [SortDescriptor(\.startDate)])
        let workouts = try await desc.result(for: store)
        var byID: [String: ActivitySession] = [:]
        for s in (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? [] { if let id = s.externalID { byID[id] = s } }
        // Minute-by-minute heart rate and recovery for the last 4 weeks: how the heart behaves in each sport.
        let detailFrom = Date.app.startOfDay.adding(days: -28)
        var added = 0
        for w in workouts {
            let s: ActivitySession
            if let old = byID[w.uuid.uuidString] {
                s = old
            } else {
                s = ActivitySession(start: w.startDate, type: map(w.workoutActivityType), minutes: (w.duration / 60).rounded(), source: .healthKit)
                s.externalID = w.uuid.uuidString
                s.avgHR = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: Self.bpm).rounded()
                s.maxHR = w.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: Self.bpm).rounded()
                let distType: HKQuantityTypeIdentifier = w.workoutActivityType == .cycling ? .distanceCycling : .distanceWalkingRunning
                s.distanceKm = w.statistics(for: HKQuantityType(distType))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)).rounded(to: 0.01)
                ctx.insert(s)
                added += 1
            }
            guard w.startDate >= detailFrom else { continue }
            if s.hrSeries.isEmpty { s.hrSeries = try await minuteHR(from: w.startDate, to: w.endDate) }
            if s.hrRecovery == nil,
               let r = recoveries.first(where: { $0.startDate >= w.endDate.addingTimeInterval(-120) && $0.startDate <= w.endDate.addingTimeInterval(900) }) {
                s.hrRecovery = value(r, Self.bpm)?.rounded()
            }
        }
        return added
    }

    private func syncECG(from start: Date, ctx: ModelContext) async throws {
        let desc = HKSampleQueryDescriptor(predicates: [.electrocardiogram(HKQuery.predicateForSamples(withStart: start, end: nil))],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        for e in try await desc.result(for: store) {
            let result: ECGResult?
            switch e.classification {
            case .sinusRhythm: result = .sinus
            case .atrialFibrillation: result = .afib
            case .inconclusiveHighHeartRate: result = .highHR
            case .inconclusiveLowHeartRate: result = .lowHR
            case .inconclusivePoorReading, .inconclusiveOther: result = .inconclusive
            default: result = nil
            }
            guard let result else { continue }
            DataHub.record(for: e.startDate, in: ctx).ecgResultRaw = result.rawValue
            if result == .afib {
                DataHub.addEvent(AlertCandidate(dedupeKey: "hk-\(e.uuid.uuidString)", kind: .irregularRhythm, severity: .consult,
                                                title: "心电图提示房颤",
                                                detail: "来自健康 App · \(e.startDate.formatted(.dateTime.month().day().hour().minute()))",
                                                guidance: "手表心电图提示房颤，这不是诊断。请保存这次记录，尽快咨询医生。确认之前不做高强度训练；若伴随胸痛、气短、晕厥，请立即拨打 120。",
                                                relatedDate: e.startDate), in: ctx)
            }
        }
    }

    private func map(_ t: HKWorkoutActivityType) -> WorkoutType {
        switch t {
        case .running: .run
        case .walking, .hiking: .walk
        case .cycling: .cycle
        case .swimming: .swim
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining: .strength
        case .highIntensityIntervalTraining: .hiit
        case .yoga, .flexibility, .pilates, .mindAndBody: .yoga
        case .tennis: .tennis
        case .badminton: .badminton
        case .tableTennis: .tableTennis
        case .basketball: .basketball
        case .soccer: .soccer
        case .volleyball, .squash, .racquetball, .pickleball, .handball, .hockey, .rugby, .baseball, .softball, .cricket: .ball
        default: .other
        }
    }

    private func syncVitals(from start: Date, ctx: ModelContext) async throws -> Int {
        var byID: [String: VitalReading] = [:]
        for v in (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? [] { if let id = v.externalID { byID[id] = v } }
        var added = 0
        /// A reading already saved only learns where it came from; a new one is inserted.
        func save(_ s: HKQuantitySample, _ make: () -> VitalReading?) {
            if let old = byID[s.uuid.uuidString] {
                if old.sourceName.isEmpty { label(old, s) }
                return
            }
            guard let v = make() else { return }
            v.externalID = s.uuid.uuidString
            label(v, s)
            ctx.insert(v); added += 1
        }
        let mmHg = HKUnit.millimeterOfMercury()
        let sys = try await samples(.bloodPressureSystolic, from: start)
        let dia = try await samples(.bloodPressureDiastolic, from: start)
        for s in sys {
            save(s) {
                guard let sv = value(s, mmHg) else { return nil }
                let d = dia.first { abs($0.startDate.timeIntervalSince(s.startDate)) < 120 }.flatMap { value($0, mmHg) }
                return VitalReading(time: s.startDate, kind: .bloodPressure, value: sv.rounded(), value2: d?.rounded(),
                                    context: s.startDate.hour < 10 ? .morning : .random, source: .healthKit)
            }
        }
        let glucose = try await samples(.bloodGlucose, from: start)
        let perDay = Double(glucose.count) / Double(max(1, Date.app.daysSince(start)))
        for s in glucose {
            save(s) {
                guard let g = value(s, Self.mmolL) else { return nil }
                return VitalReading(time: s.startDate, kind: .glucose, value: g.rounded(to: 0.1), context: .random,
                                    source: perDay >= 24 ? .cgm : .healthKit)
            }
        }
        let weights = try await samples(.bodyMass, from: start)
        for s in weights {
            save(s) {
                guard let kg = value(s, .gramUnit(with: .kilo)) else { return nil }
                return VitalReading(time: s.startDate, kind: .weight, value: kg.rounded(to: 0.1), context: .morning, source: .healthKit)
            }
        }
        return added
    }

    /// The app that wrote the reading and the device that measured it, for 「来自 OMRON connect」 and telling wrist monitors apart.
    private func label(_ v: VitalReading, _ s: HKSample) {
        v.sourceName = s.sourceRevision.source.name
        v.deviceName = [s.device?.name, s.device?.model].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private func syncDeviceEvents(from start: Date, ctx: ModelContext) async throws {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let kinds: [(HKCategoryTypeIdentifier, String, Severity, String)] = [
            (.irregularHeartRhythmEvent, "设备提示不规则心律", .consult,
             "手表的不规则心律通知可能提示房颤等情况，但这不是诊断。请保存这条记录，并尽快咨询医生（可能需要心电图检查）。若伴随胸痛、气短、晕厥，请立即拨打 120。"),
            (.highHeartRateEvent, "设备提示静止时心率过高", .verify,
             "确认当时是否处于静止状态、是否有发热、饮用咖啡或情绪紧张。反复出现，或伴随心悸、头晕、气短，请咨询医生。"),
            (.lowHeartRateEvent, "设备提示心率过低", .verify,
             "规律训练者可能出现较低心率。若伴随头晕、乏力或晕厥，或正在服用降心率药物，请咨询医生。"),
        ]
        for (id, title, severity, guidance) in kinds {
            let desc = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(id), predicate: pred)],
                                               sortDescriptors: [SortDescriptor(\.startDate)])
            for s in try await desc.result(for: store) {
                DataHub.addEvent(AlertCandidate(dedupeKey: "hk-\(s.uuid.uuidString)",
                                                kind: id == .irregularHeartRhythmEvent ? .irregularRhythm : .deviceHRAlert,
                                                severity: severity, title: title,
                                                detail: "来自健康 App · \(s.startDate.formatted(.dateTime.month().day().hour().minute()))",
                                                guidance: guidance, relatedDate: s.startDate), in: ctx)
            }
        }
    }
}


/// One kind of Apple Health data: how much there is (up to 200 in the last 60 days), the latest, and the apps that wrote it.
struct HealthInventoryItem: Identifiable, Codable, Equatable {
    var id: String
    var label: String
    var count: Int
    var latest: Date?
    var sources: [String]
    var note: String?
}
