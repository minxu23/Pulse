import Foundation
import SwiftData
import Testing
@testable import Pulse

/// 2026-10-21 is a Wednesday; 20:00.
private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("Recording and reminders from the chat")
@MainActor
struct ChatRecordTests {
    private func items(_ q: String) -> [RecordProposal.Item]? {
        let a = AgentQuestion(q)
        return ChatRecord.wanted(a) ? ChatRecord.proposal(a, now: evening)?.items : nil
    }

    @Test func statementsBecomeWhatToRecord() {
        #expect(items("帮我记一下血压 138/88") == [.bloodPressure(sys: 138, dia: 88, context: .random)])
        #expect(items("今天早上血压 138/88") == [.bloodPressure(sys: 138, dia: 88, context: .morning)], "a stated reading")
        #expect(items("血压 155/95 要紧吗") == nil, "a question about a reading is not a record")
        #expect(items("我刚喝了一杯水") == [.water(ml: 250)])
        #expect(items("刚喝了两杯水") == [.water(ml: 500)])
        #expect(items("喝了 400ml 水，记一下") == [.water(ml: 400)])
        #expect(items("脚有点肿，帮我记下来") == [.swelling(.mild, places: ["脚踝"])])
        #expect(items("今天尿少，记一下") == [.urine(.less)])
        #expect(items("记一下体重 72.5 公斤") == [.weight(kg: 72.5)])
        guard case .lab(.creatinine, let v)? = items("肌酐 1.44 mg/dL 帮我记一下")?.first else { Issue.record("no lab"); return }
        #expect(abs(v - 127.3) < 0.1, "saved in μmol/L")
        #expect(items("帮我记一下今天吃了什么") == nil)
    }

    @Test func remindersHaveWhatAndWhen() {
        func r(_ q: String) -> RecordProposal { ChatRecord.reminder(AgentQuestion(q), now: evening) }
        let bp = r("提醒我明天早上量血压")
        #expect(bp.reminder?.title == "量血压" && bp.reminder?.due == evening.startOfDay.adding(days: 1).adding(minutes: 8 * 60) && bp.reminder?.timed == true)
        #expect(bp.reminder?.area == .cardio)
        let visit = r("下周三提醒我去医院复查")
        #expect(visit.reminder?.title == "去医院复查" && visit.reminder?.due == evening.startOfDay.adding(days: 7) && visit.reminder?.timed == false)
        let pill = r("提醒我晚上九点吃药")
        #expect(pill.reminder?.title == "吃药" && pill.reminder?.due == evening.startOfDay.adding(minutes: 21 * 60))
        #expect(r("11月5号提醒我抽血").reminder.map { ($0.title, $0.due) } ?? ("", .distantPast) == ("抽血", Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 5))!))
        let water = r("提醒我多喝一点水")
        #expect(water.reminder?.title == "多喝一点水" && water.reminder?.timed == false, "「一点」 is an amount, not 1 o'clock")
        #expect(r("提醒我量血压").reminder?.due == evening.startOfDay.adding(days: 1), "no day: tomorrow")
        #expect(r("每天晚上提醒我吃药").repeatAsked)
        #expect(r("3天后提醒我复查血钾").reminder.map { ($0.title, $0.due) } ?? ("", .distantPast) == ("复查血钾", evening.startOfDay.adding(days: 3)))
    }

    @Test func recordedOnlyOnTheCardAndUndone() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .wangjianguo, now: evening)
        func count<T: PersistentModel>(_: T.Type) -> Int { (try? ctx.fetchCount(FetchDescriptor<T>())) ?? 0 }
        let vitals = count(VitalReading.self), tasks = count(CareTask.self), labs = count(LabResult.self)
        let day = DataHub.record(for: evening, in: ctx)
        let water = day.waterMl, edema = day.edema
        let p = RecordProposal(id: UUID(), items: [.bloodPressure(sys: 138, dia: 88, context: .morning), .water(ml: 250),
                                                   .swelling(.marked, places: ["脚踝"]), .lab(.creatinine, value: 127),
                                                   .reminder(title: "量血压", area: .cardio, due: evening.adding(days: 1), timed: false)],
                               time: evening)
        let due = evening.startOfDay.adding(days: 2).adding(minutes: 8 * 60)
        let undo = DataHub.applyRecord(p, reminderDue: due, in: ctx)
        #expect(count(VitalReading.self) == vitals + 1 && count(CareTask.self) == tasks + 1)
        #expect(count(LabResult.self) == labs + 2, "creatinine and the eGFR estimated from it")
        #expect(DataHub.record(for: evening, in: ctx).waterMl == water + 250 && DataHub.record(for: evening, in: ctx).edema == Edema.marked.rawValue)
        #expect(((try? ctx.fetch(FetchDescriptor<CareTask>())) ?? []).contains { $0.title == "量血压" && $0.due == due }, "the date chosen on the card")
        DataHub.undoRecord(undo, in: ctx)
        #expect(count(VitalReading.self) == vitals && count(CareTask.self) == tasks && count(LabResult.self) == labs)
        #expect(DataHub.record(for: evening, in: ctx).waterMl == water && DataHub.record(for: evening, in: ctx).edema == edema)
    }

    @Test func answersCarryTheCard() throws {
        let c = AgentContext.make(profile: ProfileSnapshot(), name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: evening)
        #expect(HealthAgent.reply(to: "帮我记一下血压 138/88", context: c).blocks.contains { $0.record != nil })
        #expect(!HealthAgent.reply(to: "血压155要紧吗", context: c).blocks.contains { $0.record != nil })
        let w = HealthAgent.reply(to: "我刚喝了一杯水", context: c)
        #expect(w.text.hasPrefix("好的，这杯是 250 ml") && w.blocks.first?.record?.items == [.water(ml: 250)])
        let meal = HealthAgent.reply(to: "帮我记一下今天吃了两碗饭", context: c)
        #expect(meal.text.contains("记录饮食") && meal.blocks.allSatisfy { $0.record == nil })
        let rem = HealthAgent.reply(to: "每天晚上9点提醒我吃药", context: c)
        #expect(rem.text.contains("重复的提醒现在还不支持") && rem.blocks.first?.record?.reminder?.title == "吃药")
        // A model may not say it recorded what only the card records; the line about the card comes back.
        let swell = HealthAgent.reply(to: "脚有点肿，记下来", context: c)
        let written = HealthAgent.finalize("脚肿要留意。\n\n我这边先帮你记一条：水肿，轻微（脚踝）。", of: swell, strict: false)
        #expect(!written.contains("帮你记一条") && written.contains("要记下来的话，点下面的「记下」"), "\(written)")
        #expect(HealthAgent.withoutRecordClaims("可以帮你记下这次血压。你已经记录了 3 天。") == "可以帮你记下这次血压。你已经记录了 3 天。")
        #expect(HealthAgent.withoutRecordClaims("已帮你记下血压 138/88。注意休息。") == "注意休息。")
        // A cloud answer that brings its own chart keeps the card, first.
        let bp = HealthAgent.reply(to: "帮我记一下血压 138/88", context: c)
        let shown = AgentUI.cloudBlocks([.chart(.bp, days: 14, caption: nil)], rule: bp)
        #expect(shown.first?.record != nil && shown.count == 2)
        #expect(AgentUI.cloudBlocks([], rule: HealthAgent.reply(to: "肌酐 1.44 mg/dL 帮我记一下", context: c)).first?.record != nil)
    }

    @Test func aTimedReminderRingsAtItsTime() {
        let at = evening.startOfDay.adding(days: 1).adding(minutes: 21 * 60)
        let plan = CareReminders.plan([CareReminders.Task(id: "p", title: "吃药", note: "在对话里添加", due: at, done: false)], now: evening)
        #expect(plan.map(\.fire) == [at] && plan[0].title == "吃药" && plan[0].body.contains("打个勾"))
    }

    @Test func theConversationIsKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let q = AgentMessage(role: .user, text: "今天适合跑步吗？")
        var a = AgentMessage(role: .agent, text: "可以，保持轻松。", reply: AgentReply(text: "可以，保持轻松。", sources: ["准备度"], followUps: ["那明天呢？"],
                                                                                destination: .plan, intent: .trainingCheck), engine: .onDevice)
        a.privacy = "在本机回答"
        let streaming = AgentMessage(role: .agent, text: "写到一半", streaming: true)
        AgentTranscript.save([q, a, streaming], to: url)
        let back = AgentTranscript.load(from: url)
        #expect(back.map(\.id) == [q.id, a.id], "an answer still being written is not kept")
        #expect(back[1].text == a.text && back[1].engine == .onDevice && back[1].reply?.followUps == ["那明天呢？"] && back[1].reply?.intent == .trainingCheck)
        #expect(back[1].privacy == "在本机回答" && back[0].date == q.date)
        AgentTranscript.save([], to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path), "清空对话 removes the file")
        #expect(AgentTranscript.url == nil, "never written from tests")
    }
}
