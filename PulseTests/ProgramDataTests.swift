import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

/// Step 1 of the 三阶段健康计划: the data the baseline report needs — sports told apart, the sports a
/// user likes, and the sample users' steps by the hour, heart rate in sessions and body fat.
@Suite("三阶段计划: baseline data")
@MainActor
struct ProgramDataTests {
    private func load(_ persona: DemoPersona) throws -> (ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: evening)
        return (ctx, container)
    }

    @Test func ballGamesAreToldApart() {
        func type(_ q: String) -> WorkoutType? { ChatRecord.workout(AgentQuestion(q), now: evening)?.type }
        #expect(type("打了一个小时网球") == .tennis)
        #expect(type("晚上打羽毛球40分钟") == .badminton)
        #expect(type("打乒乓球半小时") == .tableTennis)
        #expect(type("打篮球一个小时") == .basketball)
        #expect(type("踢球90分钟") == .soccer)
        #expect(type("下午打球一小时") == .ball)
        #expect(WorkoutType.tennis.isBallGame && WorkoutType.ball.isBallGame && !WorkoutType.run.isBallGame)
        #expect(WorkoutType(rawValue: "ball") == .ball, "sessions saved before the split keep their type")
    }

    @Test func sportPreferencesRoundTrip() {
        let s = SportPreference(type: .badminton, level: .competitive)
        #expect(SportPreference(raw: s.raw) == s)
        #expect(SportPreference(raw: "tennis") == SportPreference(type: .tennis, level: .regular))
        #expect(SportPreference(raw: "curling:regular") == nil)
        let p = UserProfile()
        p.favoriteSports = [SportPreference(type: .tennis), SportPreference(type: .run, level: .beginner)]
        #expect(p.favoriteSportsRaw == ["tennis:regular", "run:beginner"])
        #expect(p.snapshot(medications: []).favoriteSports.map(\.type) == [.tennis, .run])
    }

    @Test func hourlyStepsAddUpToTheDay() throws {
        let (ctx, c) = try load(.xiaolin)
        _ = c
        let records = try ctx.fetch(FetchDescriptor<DailyRecord>())
        let recent = records.filter { $0.day >= evening.startOfDay.adding(days: -27) && ($0.steps ?? 0) > 0 }
        #expect(recent.count >= 20)
        for r in recent {
            #expect(r.stepsByHour.count == 24)
            #expect(r.stepsByHour.reduce(0, +) == r.steps, "\(r.day): hours add up to the day")
            #expect(r.stepsByHour.prefix(5).allSatisfy { $0 == 0 }, "nothing while asleep")
            #expect((r.standHours ?? 0) > 0)
        }
        let older = records.filter { $0.day < evening.startOfDay.adding(days: -28) }
        #expect(older.allSatisfy { $0.stepsByHour.isEmpty })
    }

    @Test func sessionsCarryHeartRateMinuteByMinute() throws {
        let (ctx, c) = try load(.xiaolin)
        _ = c
        let sessions = try ctx.fetch(FetchDescriptor<ActivitySession>())
            .filter { $0.start >= evening.startOfDay.adding(days: -28) && $0.start <= evening && $0.avgHR != nil && $0.minutes >= 5 }
        #expect(!sessions.isEmpty)
        for s in sessions {
            #expect(s.hrSeries.count == Int(s.minutes))
            let mean = Double(s.hrSeries.reduce(0, +)) / Double(s.hrSeries.count)
            #expect(abs(mean - s.avgHR!) <= 1, "the series keeps the session's average")
        }
        #expect(sessions.contains { $0.hrRecovery != nil })
        let p = DataHub.profile(in: ctx)!
        #expect(p.favoriteSports.map(\.type).contains(.run), "晓林 runs, so running is a sport he likes")
    }

    @Test func weighInsCarryBodyFat() throws {
        let (ctx, c) = try load(.zhaoliqiang)
        _ = c
        let weights = try ctx.fetch(FetchDescriptor<VitalReading>()).filter { $0.kind == .weight }
        #expect(!weights.isEmpty)
        let days = Set(weights.map { $0.time.startOfDay })
        let records = try ctx.fetch(FetchDescriptor<DailyRecord>()).filter { days.contains($0.day) }
        #expect(!records.isEmpty && records.allSatisfy { $0.bodyFatPct != nil && $0.leanMassKg != nil })
        #expect(records.allSatisfy { (10...45).contains($0.bodyFatPct!) })
    }

    @Test func enrichmentLeavesTheGeneratedHistoryAlone() throws {
        // The same sample user with and without the extra data: every original value is the same.
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        PersonaGenerator.populate(ctx, spec: DemoPersona.chenjie.spec!, now: evening)
        let before = try ctx.fetch(FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.day)])).map { "\($0.day)|\($0.restingHR ?? 0)|\($0.steps ?? 0)|\($0.sleepMinutes ?? 0)" }
        let sessionsBefore = try ctx.fetch(FetchDescriptor<ActivitySession>(sortBy: [SortDescriptor(\.start)])).map { "\($0.start)|\($0.avgHR ?? 0)|\($0.minutes)" }
        DemoEnrichment.enrich(ctx, persona: DemoPersona.chenjie.rawValue, now: evening)
        let after = try ctx.fetch(FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.day)])).map { "\($0.day)|\($0.restingHR ?? 0)|\($0.steps ?? 0)|\($0.sleepMinutes ?? 0)" }
        let sessionsAfter = try ctx.fetch(FetchDescriptor<ActivitySession>(sortBy: [SortDescriptor(\.start)])).map { "\($0.start)|\($0.avgHR ?? 0)|\($0.minutes)" }
        #expect(before == after)
        #expect(sessionsBefore == sessionsAfter)
    }

    @Test func everySampleUserWearsACGM() throws {
        var over78: [DemoPersona: Double] = [:]
        for persona in DemoPersona.allCases {
            let (ctx, c) = try load(persona)
            _ = c
            let p = DataHub.profile(in: ctx)!
            let cgm = try ctx.fetch(FetchDescriptor<VitalReading>()).filter { $0.kind == .glucose && $0.context == .random }
            let recent = cgm.filter { $0.time >= evening.startOfDay.adding(days: -DemoEnrichment.cgmDays) }
            let days = Set(recent.map { $0.time.startOfDay }).count
            #expect(days >= min(DemoEnrichment.cgmDays, persona.days) - 1, "\(persona.name): a sensor reading every day")
            #expect(recent.count >= days * 85, "\(persona.name): every 15 minutes")
            if !p.conditions.contains(where: \.isDiabetes) {
                let last2w = recent.filter { $0.time >= evening.adding(days: -14) }
                #expect(last2w.allSatisfy { (4.0...11.5).contains($0.value) }, "\(persona.name): no alerts from sample data")
                over78[persona] = Double(recent.filter { $0.value > 7.8 }.count) / Double(max(1, recent.count))
            }
        }
        #expect((over78[.chenjie] ?? 0) > (over78[.liuyang] ?? 1), "heavier and sedentary: higher rises after meals")
    }

    @Test func ballGameHeartRateRisesAndFalls() {
        var rng = SeededRandom(seed: 1)
        let tennis = DemoEnrichment.series(minutes: 60, avg: 140, rest: 60, type: .tennis, hard: false, rng: &rng)
        let steady = DemoEnrichment.series(minutes: 60, avg: 140, rest: 60, type: .cycle, hard: false, rng: &rng)
        func spread(_ s: [Int]) -> Int { (s.dropFirst(8).max() ?? 0) - (s.dropFirst(8).min() ?? 0) }
        #expect(spread(tennis) > spread(steady))
        #expect(tennis.first! < 140, "warms up first")
    }
}
