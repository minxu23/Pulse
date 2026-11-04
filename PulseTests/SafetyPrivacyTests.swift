import Foundation
import SwiftData
import Testing
@testable import Pulse

/// A service that answers only for `host`, so a cloud answer can be played back without a network.
private final class StubCloud: URLProtocol {
    static let host = "stub.pulse.test"
    /// Keyed by model name, because tests run side by side.
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    private static let lock = NSLock()

    static func answer(_ body: String, for model: String) {
        lock.lock(); defer { lock.unlock() }
        bodies[model] = body
    }

    private static func body(for model: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return bodies[model] ?? ""
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let sent = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        let model = (try? JSONSerialization.jsonObject(with: sent) as? [String: Any])?["model"] as? String ?? ""
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                           cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(Self.body(for: model).utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite("Alerts, reminders, exports and erasing")
@MainActor
struct SafetyPrivacyTests {
    private let noon = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!

    private func store() throws -> ModelContainer {
        try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func events(_ ctx: ModelContext) -> [HealthEvent] { (try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? [] }

    private func alert(_ key: String, _ severity: Severity) -> AlertCandidate {
        AlertCandidate(dedupeKey: key, kind: .other, severity: severity, title: key, detail: severity.rawValue, guidance: "", relatedDate: noon)
    }

    // MARK: Background check

    @Test func theBackgroundCheckSeesWhatTheHealthSyncFound() async throws {
        let container = try store()
        let ctx = container.mainContext
        DataHub.addEvent(alert("old", .consult), in: ctx)

        // The Health sync stores events itself, before the alert rules run.
        let new = await BackgroundCheck.newEvents(in: ctx) { DataHub.addEvent(alert("irregular", .consult), in: ctx) }
        #expect(new.map(\.dedupeKey) == ["irregular"])

        let raised = await BackgroundCheck.newEvents(in: ctx) { DataHub.addEvent(alert("old", .urgent), in: ctx) }
        #expect(raised.map(\.dedupeKey) == ["old"], "a more serious event is news")
        #expect(CareReminders.notices(raised.map { .init(id: $0.id.uuidString, title: $0.title, detail: "", severity: $0.severity) }).count == 1)

        let same = await BackgroundCheck.newEvents(in: ctx) { DataHub.addEvent(alert("old", .consult), in: ctx) }
        #expect(same.isEmpty)
    }

    // MARK: Readings

    @Test func measuringAgainShowsTheAdviceAgain() throws {
        let container = try store()
        let ctx = container.mainContext
        let p = ProfileSnapshot()
        let first = VitalPoint(time: noon, kind: .bloodPressure, value: 190, value2: 125, context: .random)
        let again = VitalPoint(time: noon.adding(minutes: 6), kind: .bloodPressure, value: 188, value2: 122, context: .random)
        #expect(DataHub.alert(forReading: first, weights: [], profile: p, in: ctx, now: noon)?.severity == .urgent)
        #expect(DataHub.alert(forReading: again, weights: [], profile: p, in: ctx, now: noon)?.severity == .urgent,
                "a repeat at a crisis level is not a plain 「已保存」")
        #expect(events(ctx).count == 1, "and it is still one event")

        let fine = VitalPoint(time: noon.adding(minutes: 12), kind: .bloodPressure, value: 122, value2: 78, context: .random)
        #expect(DataHub.alert(forReading: fine, weights: [], profile: p, in: ctx, now: noon) == nil)
    }

    @Test func aMoreSeriousReadingTakesOverTheEvent() throws {
        let container = try store()
        let ctx = container.mainContext
        let p = ProfileSnapshot()
        func spo2(_ v: Double, _ minutes: Int) -> AlertCandidate {
            AlertEngine.evaluateVital(VitalPoint(time: noon.adding(minutes: minutes), kind: .spo2, value: v, context: .random), profile: p)!
        }
        let mild = spo2(91, 0), serious = spo2(85, 120)
        #expect(mild.dedupeKey == serious.dedupeKey, "the case this guards: one key for both")

        let stored = try #require(DataHub.addEvent(mild, in: ctx))
        stored.status = .dismissed
        #expect(DataHub.addEvent(serious, in: ctx) != nil)
        let e = try #require(events(ctx).first)
        #expect(events(ctx).count == 1)
        #expect(e.severity == .urgent && e.detail.contains("85") && e.status == .open && e.resolvedAt == nil)
        #expect(e.followUpDue == serious.relatedDate.adding(days: 0))

        #expect(DataHub.addEvent(spo2(90, 240), in: ctx) == nil, "a milder one changes nothing")
        #expect(e.severity == .urgent && e.detail.contains("85"))
    }

    // MARK: Reminders

    @Test func changingTheScheduleTakesAwayOnlyWhatIsNoLongerDue() {
        let tasks = [CareReminders.Task(id: "keep", title: "复查血钾", note: "", due: noon.adding(days: 20), done: false),
                     CareReminders.Task(id: "daily", title: "吃药", note: "", due: noon.startOfDay.adding(minutes: 21 * 60), done: false, repeats: .daily)]
        let planned = CareReminders.plan(tasks, now: noon)
        #expect(!planned.isEmpty)
        #expect(CareReminders.stale(pending: planned.map(\.id), planned: CareReminders.plan(tasks, now: noon)).isEmpty,
                "the same reminder keeps its id, so adding it replaces it")

        let gone = CareReminders.prefix + "ticked-off.day"
        let pending = planned.map(\.id) + [gone, "pulse.event.x", "someone-else"]
        #expect(CareReminders.stale(pending: pending, planned: planned) == [gone])
        #expect(CareReminders.stale(pending: pending, planned: []).count == planned.count + 1, "turned off: all of Pulse's own, nothing else")
    }

    // MARK: A model's forms and plans

    private func number(_ json: String) -> (lo: Int, hi: Int, step: Int, value: Int)? {
        let form = #"[{"type":"form","title":"补充一下","fields":[{"id":"n","label":"目标","kind":"number",\#(json)}]}]"#
        guard case .form(let f)? = AgentUI.blocks(fromJSON: form, context: "").first,
              case .number(let lo, let hi, let step, _, let value)? = f.fields.first?.kind else { return nil }
        return (lo, hi, step, value)
    }

    @Test func aFormNumberIsAlwaysARange() throws {
        let water = try #require(number(#""min":1000,"max":3000,"step":100,"value":1500,"unit":"ml""#))
        #expect(water == (1000, 3000, 100, 1500), "a range above 600 is kept as the model gave it")
        let steps = try #require(number(#""min":0,"max":9999"#))
        #expect(steps.hi == 600, "120 taps at most")

        for json in [#""min":5000"#, #""min":700,"max":900"#, #""min":3000,"max":1000"#, #""min":-5,"max":-1"#, #""min":1e30"#, #""min":0,"max":1e30"#,
                     #""min":9007199254740992,"step":9007199254740992"#, #""min":"很多","max":"更多""#, #""min":10,"max":10,"step":0,"value":1e30"#] {
            let n = try #require(number(json), "\(json)")
            #expect(n.lo < n.hi && n.step >= 1 && (n.lo...n.hi).contains(n.value), "\(json)")
        }
    }

    @Test func aPlanEditWithAnImpossibleNumberIsNoCrash() {
        #expect(PlanChat.ops(fromJSON: #"{"edits":[{"op":"minutes","day":"周五","minutes":1e30}]}"#).ops.isEmpty)
        #expect(PlanChat.ops(fromJSON: #"{"edits":[{"op":"minutes","day":"周五","minutes":9223372036854775807}]}"#).ops == [.minutes(day: 6, minutes: 1440)])
    }

    // MARK: Cloud answers

    @Test func anAnswerWithoutWordsIsAFailure() async throws {
        #expect(URLProtocol.registerClass(StubCloud.self))
        defer { URLProtocol.unregisterClass(StubCloud.self) }
        func client(_ model: String) -> CloudModelClient {
            CloudModelClient(provider: .openRouter, baseURL: "https://\(StubCloud.host)/v1", model: model, apiKey: "test")
        }

        StubCloud.answer("data: [DONE]\n\n", for: "empty")
        await #expect(throws: CloudModelError.empty) { _ = try await client("empty").stream(system: "s", prompt: "p") { _ in } }

        StubCloud.answer("data: {\"choices\":[{\"delta\":{\"content\":\"  \\n\"}}]}\n\ndata: [DONE]\n\n", for: "blank")
        await #expect(throws: CloudModelError.empty) { _ = try await client("blank").stream(system: "s", prompt: "p") { _ in } }

        StubCloud.answer("data: {\"choices\":[{\"delta\":{\"content\":\"先休息\"}}]}\n\ndata: [DONE]\n\n", for: "words")
        let text = try await client("words").stream(system: "s", prompt: "p") { _ in }
        #expect(text == "先休息")
    }

    // MARK: Export

    private func day() -> DailyRecord {
        let r = DailyRecord(day: noon)
        r.restingHR = 61
        r.hrv = 44
        r.sleepMinutes = 450
        r.steps = 8123
        r.alcoholUnits = 2
        r.waterMl = 1500
        return r
    }

    @Test func theTableHoldsOnlyWhatWasChosen() throws {
        let sleep = DataExporter.csvLines([day()], categories: [.sleep])
        #expect(sleep[0] == "日期,睡眠小时,入睡时间")
        #expect(sleep[1].hasSuffix(",7.5,"))
        #expect(!sleep.joined().contains("61") && !sleep.joined().contains("8123") && !sleep.joined().contains("1500"))

        let everything = DataExporter.csvLines([day()], categories: Set(ExportCategory.allCases))
        #expect(everything[0] == "日期,静息心率,来源,HRV,睡眠小时,入睡时间,步数,运动分钟,精力,酸痛,压力,饮酒单位,咖啡杯数,饮水ml,标签")
        #expect(everything[1].split(separator: ",", omittingEmptySubsequences: false).count == 15)

        // Readings and medicines are not daily numbers: nothing to put in the table.
        #expect(DataExporter.csvCategories.isDisjoint(with: [.vitals, .medications, .profile, .events]))
        #expect(DataExporter.csvLines([day()], categories: [.vitals]) .first == "日期")
    }

    @Test func theFileFollowsTheChoiceToo() throws {
        let container = try store()
        let ctx = container.mainContext
        ctx.insert(day())
        let url = try DataExporter.csv(ctx, categories: [.activity])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("日期,步数,运动分钟") && text.contains("8123") && !text.contains("7.5"))
    }

    // MARK: Erasing

    @Test func erasingTakesBackTheConsentAndTheKeys() throws {
        let suite = "PulseTests.erase"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            for p in CloudProvider.allCases { KeychainStore.delete(account: "cloud.apiKey.\(p.rawValue)", service: suite) }
        }
        // Its own store and Keychain service: the real settings and key stay as they are.
        let s = CloudModelSettings(defaults: defaults, keychain: suite)
        #expect(s.saveKey("test-value-not-a-real-key-0000"))
        s.provider = .anthropic
        s.baseURL = CloudProvider.anthropic.defaultBaseURL
        s.model = CloudProvider.anthropic.defaultModel
        #expect(s.saveKey("test-value-not-a-real-key-1111"))
        s.lastTestOK = true
        s.consented = true
        s.mode = .cloud
        #expect(s.effectiveMode == .cloud)

        s.eraseAll()
        #expect(!s.consented && s.mode == .onDevice && !s.lastTestOK && s.provider == .openRouter)
        #expect(s.keySource != .keychain)
        for p in CloudProvider.allCases { #expect(KeychainStore.read(account: "cloud.apiKey.\(p.rawValue)", service: suite) == nil) }

        // And it stays so at the next launch.
        let next = CloudModelSettings(defaults: defaults, keychain: suite)
        #expect(!next.consented && next.mode == .onDevice && next.effectiveMode == .onDevice && next.keySource != .keychain)
    }

    @Test func erasingClearsThePreferencesButNotTheLanguage() throws {
        let suite = "PulseTests.preferences"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CareReminders.enabledKey)
        defaults.set(true, forKey: "cloud.consented")
        defaults.set("小安", forKey: AgentName.key)
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        DataHub.clearPreferences(defaults, domain: suite)
        #expect(defaults.persistentDomain(forName: suite)?.keys.sorted() == ["AppleLanguages"])
    }

    @Test func erasingRemovesExportedFilesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PulseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exported = folder.appendingPathComponent("Pulse-daily-2026-10-21.csv"), other = folder.appendingPathComponent("cache.db")
        try Data("x".utf8).write(to: exported)
        try Data("x".utf8).write(to: other)
        DataExporter.removeExports(in: folder)
        #expect(!FileManager.default.fileExists(atPath: exported.path) && FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Advice

    @Test func readinessKeepsToTheIntensityLimit() {
        var d = DayData(day: noon)
        d.sleepMinutes = 480
        d.energy = 5
        d.stress = 1
        d.soreness = 0
        var p = ProfileSnapshot()
        p.conditions = [.ckd]

        let capped = ReadinessEngine.evaluate(today: d, history: [], profile: p)
        #expect(capped.level == .high)
        #expect(capped.recommendation.contains("需先与医生确认") && !capped.recommendation.contains("包括计划中的较高强度训练"))

        p.clinicianCleared = true
        #expect(ReadinessEngine.evaluate(today: d, history: [], profile: p).recommendation == ReadinessLevel.high.recommendation)
    }

    @Test func creatinineIsReadWithoutASexOrAnEstimate() {
        var p = ProfileSnapshot()
        p.age = 50
        p.sex = .unspecified
        let high = LabAnalyzer.status(.creatinine, 900, profile: p)
        #expect(high.level == .urgent, "high whichever the sex")
        #expect(high.text.contains("填写性别后更准"))
        #expect(LabAnalyzer.status(.creatinine, 70, profile: p).level == .normal)

        p.sex = .male
        #expect(LabAnalyzer.status(.creatinine, 900, profile: p).text.contains("G5"))

        p.age = 15
        #expect(LabAnalyzer.status(.creatinine, 900, profile: p).level == .watch, "no estimate: not shown as normal")
    }
}
