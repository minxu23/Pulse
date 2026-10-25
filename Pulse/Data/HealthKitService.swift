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

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let ms = HKUnit.secondUnit(with: .milli)
    private static let mmolL = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let vo2 = HKUnit(from: "ml/kg*min")

    private var quantityIDs: [HKQuantityTypeIdentifier] {
        [.restingHeartRate, .heartRateVariabilitySDNN, .heartRate, .stepCount, .activeEnergyBurned,
         .appleExerciseTime, .vo2Max, .oxygenSaturation, .respiratoryRate, .bloodPressureSystolic,
         .bloodPressureDiastolic, .bloodGlucose, .bodyMass, .distanceWalkingRunning, .distanceCycling,
         .appleSleepingBreathingDisturbances]
    }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>(quantityIDs.map { HKQuantityType($0) })
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKCategoryType(.irregularHeartRhythmEvent))
        set.insert(HKCategoryType(.highHeartRateEvent))
        set.insert(HKCategoryType(.lowHeartRateEvent))
        set.insert(HKObjectType.workoutType())
        return set
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw NSError(domain: "Pulse", code: 1, userInfo: [NSLocalizedDescriptionKey: "此设备不支持健康数据"]) }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: Sync

    func sync(into ctx: ModelContext, days: Int = 60) async {
        guard isAvailable, !isSyncing else { return }
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
            counts["运动"] = try await syncWorkouts(from: start, ctx: ctx)

            // Blood pressure, glucose, weight → vitals
            counts["指标"] = try await syncVitals(from: start, ctx: ctx)

            // Device notifications → events needing attention
            try await syncDeviceEvents(from: start, ctx: ctx)

            if let p = DataHub.profile(in: ctx) { p.lastSync = .app; p.useHealthKit = true }
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

    private struct Night { var day: Date; var start: Date; var end: Date; var asleep: Double; var deep: Double?; var rem: Double?; var awake: Double? }

    private func sleepNights(from start: Date) async throws -> [Night] {
        let pred = HKQuery.predicateForSamples(withStart: start.adding(days: -1), end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        let all = try await desc.result(for: store)
        let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                      HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        // A night belongs to the morning it ends on (samples ending after 18:00 count toward the next day).
        let byNight = Dictionary(grouping: all, by: { $0.endDate.addingTimeInterval(6 * 3600).startOfDay })
        var nights: [Night] = []
        for (day, samples) in byNight {
            // Prefer the source with the richest data to avoid double counting phone + watch.
            let bySource = Dictionary(grouping: samples, by: { $0.sourceRevision.source.bundleIdentifier })
            guard let best = bySource.values.max(by: { a, b in
                minutes(a.filter { asleepValues.contains($0.value) }) < minutes(b.filter { asleepValues.contains($0.value) })
            }) else { continue }
            let asleep = best.filter { asleepValues.contains($0.value) }
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

    private func syncWorkouts(from start: Date, ctx: ModelContext) async throws -> Int {
        let pred = HKQuery.predicateForSamples(withStart: start, end: nil)
        let desc = HKSampleQueryDescriptor(predicates: [.workout(pred)], sortDescriptors: [SortDescriptor(\.startDate)])
        let workouts = try await desc.result(for: store)
        let existing = Set(((try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []).compactMap(\.externalID))
        var added = 0
        for w in workouts where !existing.contains(w.uuid.uuidString) {
            let s = ActivitySession(start: w.startDate, type: map(w.workoutActivityType), minutes: (w.duration / 60).rounded(), source: .healthKit)
            s.externalID = w.uuid.uuidString
            s.avgHR = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: Self.bpm).rounded()
            s.maxHR = w.statistics(for: HKQuantityType(.heartRate))?.maximumQuantity()?.doubleValue(for: Self.bpm).rounded()
            let distType: HKQuantityTypeIdentifier = w.workoutActivityType == .cycling ? .distanceCycling : .distanceWalkingRunning
            s.distanceKm = w.statistics(for: HKQuantityType(distType))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)).rounded(to: 0.01)
            ctx.insert(s)
            added += 1
        }
        return added
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
        case .basketball, .soccer, .badminton, .tennis, .tableTennis, .volleyball: .ball
        default: .other
        }
    }

    private func syncVitals(from start: Date, ctx: ModelContext) async throws -> Int {
        let existing = Set(((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).compactMap(\.externalID))
        var added = 0
        let mmHg = HKUnit.millimeterOfMercury()
        let sys = try await samples(.bloodPressureSystolic, from: start)
        let dia = try await samples(.bloodPressureDiastolic, from: start)
        for s in sys where !existing.contains(s.uuid.uuidString) {
            guard let sv = value(s, mmHg) else { continue }
            let d = dia.first { abs($0.startDate.timeIntervalSince(s.startDate)) < 120 }.flatMap { value($0, mmHg) }
            let v = VitalReading(time: s.startDate, kind: .bloodPressure, value: sv.rounded(), value2: d?.rounded(),
                                 context: s.startDate.hour < 10 ? .morning : .random, source: .healthKit)
            v.externalID = s.uuid.uuidString
            ctx.insert(v); added += 1
        }
        let glucose = try await samples(.bloodGlucose, from: start)
        let perDay = Double(glucose.count) / Double(max(1, Date.app.daysSince(start)))
        for s in glucose where !existing.contains(s.uuid.uuidString) {
            guard let g = value(s, Self.mmolL) else { continue }
            let v = VitalReading(time: s.startDate, kind: .glucose, value: g.rounded(to: 0.1), context: .random,
                                 source: perDay >= 24 ? .cgm : .healthKit)
            v.externalID = s.uuid.uuidString
            ctx.insert(v); added += 1
        }
        let weights = try await samples(.bodyMass, from: start)
        for s in weights where !existing.contains(s.uuid.uuidString) {
            guard let kg = value(s, .gramUnit(with: .kilo)) else { continue }
            let v = VitalReading(time: s.startDate, kind: .weight, value: kg.rounded(to: 0.1), context: .morning, source: .healthKit)
            v.externalID = s.uuid.uuidString
            ctx.insert(v); added += 1
        }
        return added
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
