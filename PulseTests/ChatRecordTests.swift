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
        // Repeats: the next time by the rule, from now on.
        let daily = r("每天晚上9点提醒我吃药")
        #expect(daily.repeats == .daily && daily.reminder?.title == "吃药" && daily.reminder?.due == evening.startOfDay.adding(minutes: 21 * 60),
                "tonight at 9 is still ahead")
        let nightly = r("每晚7点提醒我量血压")
        #expect(nightly.repeats == .daily && nightly.reminder?.title == "量血压" && nightly.reminder?.due == evening.startOfDay.adding(days: 1).adding(minutes: 19 * 60),
                "「每晚 7 点」 is 19:00, past for today")
        let weekly = r("每周一和周四提醒我称体重")
        #expect(weekly.repeats == .weekly([2, 5]) && weekly.reminder?.title == "称体重" && weekly.reminder?.due == evening.startOfDay.adding(days: 1), "Thursday is next")
        let monthly = r("每个月5号提醒我复查血钾")
        #expect(monthly.repeats == .monthly(5) && monthly.reminder?.title == "复查血钾"
                && monthly.reminder?.due == Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 5))!)
        #expect(r("每周提醒我称体重").repeats == .weekly([4]), "the weekday it was asked on")
        let dressing = r("每隔两天提醒我换药")
        #expect(dressing.repeats == .everyDays(3) && dressing.reminder?.title == "换药", "「每隔两天」 is every third day")
        #expect(r("隔天提醒我量体重").repeats == .everyDays(2) && r("每两天提醒我量体重").repeats == .everyDays(2))
        #expect(r("每次透析后提醒我称体重").repeatAsked && r("每次透析后提醒我称体重").repeats == nil)
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

    @Test func mealsAndWorkoutsFromASentence() throws {
        guard case .meal(let lunch)? = items("午饭吃了两碗米饭、一个鸡蛋和一根香蕉")?.first else { Issue.record("no meal"); return }
        #expect(lunch.kind == .lunch && lunch.foods == ["米饭", "米饭", "鸡蛋", "香蕉"] && lunch.at == evening.startOfDay.adding(minutes: 12 * 60))
        #expect(ChatRecord.foods(in: "吃了一碗牛肉面和咸菜，喝了骨头汤") == ["面条", "咸菜、腌制品", "浓汤、肉汤", "骨头汤、浓肉汤"])
        #expect(ChatRecord.foods(in: "早上吃了面包和蛋糕").isEmpty, "foods not on the lists")
        // Carbohydrate, foods off the lists included: 2 × 25 + 12.
        #expect(ChatRecord.carbs(in: "早饭吃了两片面包和一杯牛奶") == 62 && ChatRecord.named(in: "早饭吃了两片面包和一杯牛奶") == "面包 ×2、牛奶")
        #expect(ChatRecord.carbs(in: "吃了十个饺子") == 60 && ChatRecord.carbs(in: "吃了一个鸡蛋") == nil)
        #expect(lunch.carbsG == 105 && lunch.named == "米饭 ×2、鸡蛋、香蕉")
        #expect(items("我吃了布洛芬") == nil, "a medicine is not a meal")
        guard case .meal(let dinner)? = items("刚吃完晚饭")?.first else { Issue.record("no dinner"); return }
        #expect(dinner.kind == .dinner && dinner.foods.isEmpty && dinner.at == evening)

        guard case .workout(let walk)? = items("刚快走了40分钟")?.first else { Issue.record("no walk"); return }
        #expect(walk.type == .walk && walk.minutes == 40 && walk.start == evening.adding(minutes: -40) && !walk.estimated)
        guard case .workout(let run)? = items("早上跑了5公里")?.first else { Issue.record("no run"); return }
        #expect(run.type == .run && run.km == 5 && run.minutes == 30 && run.estimated && run.start == evening.startOfDay.adding(minutes: 8 * 60))
        guard case .workout(let ride)? = items("骑车一个半小时，记一下")?.first else { Issue.record("no ride"); return }
        #expect(ride.type == .cycle && ride.minutes == 90)
        guard case .workout(let hiit)? = items("间歇跑了20分钟，很累")?.first else { Issue.record("no intervals"); return }
        #expect(hiit.type == .hiit && hiit.effort == 9)
        #expect(items("今天走了8000步") == nil, "steps come from Apple Health")
        // Changed on the card: it still ends when it did.
        let longer = ChatRecord.changed(run, type: .walk, minutes: 45)
        #expect(longer.type == .walk && longer.minutes == 45 && !longer.estimated && longer.start == run.start.adding(minutes: -15))
        #expect(items("散步能降血压吗") == nil, "a question")

        // What the answer says: the meal's protein for a kidney diet; the workout's week.
        var p = ProfileSnapshot()
        p.conditions = [.ckd]; p.proteinTargetG = 55
        let c = AgentContext.make(profile: p, name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: evening)
        let said = HealthAgent.reply(to: "午饭吃了两碗米饭、一个鸡蛋", context: c)
        #expect(said.text.hasPrefix("好的，午餐：米饭 ×2、鸡蛋。") && said.text.contains("这顿蛋白质约 14 g") && said.blocks.first?.record != nil, "\(said.text)")
        var dm = ProfileSnapshot()
        dm.conditions = [.diabetesT2]
        let cd = AgentContext.make(profile: dm, name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                   baselineSetAt: nil, raceName: "", now: evening)
        let bread = HealthAgent.reply(to: "早饭吃了两片面包和一杯牛奶", context: cd)
        #expect(bread.text.hasPrefix("好的，早餐：面包 ×2、牛奶。") && bread.text.contains("这顿碳水约 60 g"), "\(bread.text)")
        let walked = HealthAgent.reply(to: "刚快走了40分钟", context: c)
        #expect(walked.text.hasPrefix("好的，步行 40 分钟。") && walked.intent == .exercise && walked.blocks.first?.record != nil, "\(walked.text)")
        #expect(AgentFollowUps.suggest(after: walked, question: "刚快走了40分钟", context: c, asked: []) == ["这周的训练完成得怎么样？", "明天能运动吗？"])
        #expect(HealthAgent.reply(to: "明天能运动吗", context: c).intent == .trainingCheck)
        let concern = HealthAgent.reply(to: "中午吃了咸菜，今天血压有点高", context: c)
        #expect(!concern.text.hasPrefix("好的") && concern.blocks.contains { $0.record != nil }, "\(concern.text.prefix(60))")

        // Recorded: the meal into the kidney diet, the workout into today's plan; both undone.
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .wangjianguo, now: evening)
        DataHub.ensureWeekPlan(in: ctx, now: evening)
        DataHub.profile(in: ctx)?.nutrientTracking = true
        func count<T: PersistentModel>(_: T.Type) -> Int { (try? ctx.fetchCount(FetchDescriptor<T>())) ?? 0 }
        let day = DataHub.record(for: evening, in: ctx)
        let rice = day.proteinFoods.filter { $0 == "米饭" }.count, bananas = day.potassiumFoods.filter { $0 == "香蕉" }.count, meals = count(MealLog.self)
        let ate = DataHub.applyRecord(RecordProposal(id: UUID(), items: [.meal(lunch)], time: evening), in: ctx)
        #expect(day.proteinFoods.filter { $0 == "米饭" }.count == rice + 2 && day.potassiumFoods.filter { $0 == "香蕉" }.count == bananas + 1)
        #expect(count(MealLog.self) == meals + 1 && day.nutrientsLogged)
        DataHub.undoRecord(ate, in: ctx)
        #expect(day.proteinFoods.filter { $0 == "米饭" }.count == rice && day.potassiumFoods.filter { $0 == "香蕉" }.count == bananas && count(MealLog.self) == meals)

        let today = evening.startOfDay
        let planned = try #require(((try? ctx.fetch(FetchDescriptor<PlanItem>(predicate: #Predicate { $0.day == today }))) ?? [])
            .first { $0.kind.isTraining && [.planned, .partial].contains($0.status) })
        let type: WorkoutType = planned.kind == .strength ? .strength : (planned.kind == .mobility ? .yoga : .walk)
        let w = RecordProposal.Workout(type: type, minutes: planned.minutes, km: nil, effort: 4, estimated: false, start: evening.adding(minutes: -planned.minutes))
        let sessions = count(ActivitySession.self), status = planned.status
        let did = DataHub.applyRecord(RecordProposal(id: UUID(), items: [.workout(w)], time: evening), in: ctx)
        #expect(count(ActivitySession.self) == sessions + 1 && planned.status == .done)
        DataHub.undoRecord(did, in: ctx)
        #expect(count(ActivitySession.self) == sessions && planned.status == status)
    }

    @Test func repeatingTasksMoveOn() throws {
        #expect(CareRepeat(raw: CareRepeat.weekly([5, 2]).raw) == .weekly([2, 5]) && CareRepeat(raw: "") == nil && CareRepeat(raw: "monthly:31") == .monthly(31))
        #expect(CareRepeat.weekly([2, 4, 6]).label == "每周一、三、五" && CareRepeat.monthly(5).label == "每月 5 号")
        let nov1 = Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        #expect(CareRepeat.monthly(31).first(onOrAfter: nov1, minutes: nil) == Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 30))!,
                "the 31st in a 30-day month is its last day")

        // Done early (20:00 for 21:00): the next one is tomorrow's; ticking again takes it back.
        let pill = CareTask(title: "吃药", area: .general, due: evening.startOfDay.adding(minutes: 21 * 60), repeats: .daily)
        pill.complete(now: evening)
        #expect(pill.due == evening.startOfDay.adding(days: 1).adding(minutes: 21 * 60) && !pill.done && pill.isDone(now: evening))
        #expect(!pill.isDone(now: evening.adding(days: 1)), "open again the next day")
        pill.reopen()
        #expect(pill.due == evening.startOfDay.adding(minutes: 21 * 60) && !pill.isDone(now: evening))
        // Missed last night: ticked in the morning, tonight's still rings.
        let missed = CareTask(title: "吃药", area: .general, due: evening.startOfDay.adding(days: -1).adding(minutes: 21 * 60), repeats: .daily)
        missed.complete(now: evening.startOfDay.adding(minutes: 8 * 60))
        #expect(missed.due == evening.startOfDay.adding(minutes: 21 * 60))
        // Every other day keeps its step, from the time it was due.
        let other = CareTask(title: "换药", area: .general, due: evening.startOfDay.adding(minutes: 9 * 60), repeats: .everyDays(2))
        other.complete(now: evening)
        #expect(other.due == evening.startOfDay.adding(days: 2).adding(minutes: 9 * 60))
        other.reopen()
        #expect(other.due == evening.startOfDay.adding(minutes: 9 * 60))
        let skips = CareReminders.plan([.init(id: "e", title: "换药", note: "", due: evening.startOfDay.adding(days: -3).adding(minutes: 21 * 60), done: false,
                                              repeats: .everyDays(2))], now: evening)
        #expect(skips.first?.fire == evening.startOfDay.adding(days: 1).adding(minutes: 21 * 60) && skips.dropFirst().first?.fire == evening.startOfDay.adding(days: 3).adding(minutes: 21 * 60),
                "missed: the next time in step, not today")
        let once = CareTask(title: "复查", area: .kidney, due: evening.startOfDay)
        once.complete(now: evening)
        #expect(once.done && once.isDone(now: evening))

        // Notifications: a daily one's next 7 times; a weekly one without a time at 9 on its days.
        let planned = CareReminders.plan([.init(id: "a", title: "吃药", note: "", due: evening.startOfDay.adding(minutes: 21 * 60), done: false, repeats: .daily)], now: evening)
        #expect(planned.count == 7 && Set(planned.map(\.id)).count == 7)
        #expect(planned.first?.fire == evening.startOfDay.adding(minutes: 21 * 60) && planned.last?.fire == evening.startOfDay.adding(days: 6).adding(minutes: 21 * 60))
        let weekly = CareReminders.plan([.init(id: "b", title: "称体重", note: "", due: evening.startOfDay.adding(days: 1), done: false, repeats: .weekly([2, 5]))], now: evening)
        #expect(weekly.count == 7 && weekly.first?.fire == evening.startOfDay.adding(days: 1).adding(minutes: 9 * 60) && weekly.first?.title == "今天：称体重")
        // Long missed: from the next time on, not a flood of old ones.
        let old = CareReminders.plan([.init(id: "c", title: "吃药", note: "", due: evening.startOfDay.adding(days: -40).adding(minutes: 21 * 60), done: false, repeats: .daily)], now: evening)
        #expect(old.first?.fire == evening.startOfDay.adding(minutes: 21 * 60) && old.count == 7)

        // From the chat: the task keeps the repeat, at the time on the card.
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let p = ChatRecord.reminder(AgentQuestion("每天晚上9点提醒我吃药"), now: evening)
        DataHub.applyRecord(p, reminderDue: evening.startOfDay.adding(minutes: 21 * 60 + 30), in: ctx)
        let task = try #require(((try? ctx.fetch(FetchDescriptor<CareTask>())) ?? []).first { $0.title == "吃药" })
        #expect(task.repeats == .daily && task.due?.minutesOfDay == 21 * 60 + 30 && (task.due ?? .distantPast) >= Date.app.adding(minutes: -1))
    }

    @Test func answersCarryTheCard() throws {
        let c = AgentContext.make(profile: ProfileSnapshot(), name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: evening)
        #expect(HealthAgent.reply(to: "帮我记一下血压 138/88", context: c).blocks.contains { $0.record != nil })
        #expect(!HealthAgent.reply(to: "血压155要紧吗", context: c).blocks.contains { $0.record != nil })
        let w = HealthAgent.reply(to: "我刚喝了一杯水", context: c)
        #expect(w.text.hasPrefix("好的，这杯是 250 ml") && w.blocks.first?.record?.items == [.water(ml: 250)])
        let meal = HealthAgent.reply(to: "帮我记一下今天吃了两碗饭", context: c)
        #expect(meal.blocks.first?.record?.items.first.map { if case .meal(let m) = $0 { m.foods == ["米饭", "米饭"] } else { false } } == true)
        #expect(HealthAgent.reply(to: "帮我记一下今天吃了点东西", context: c).text.contains("没认出吃了什么"))
        let rem = HealthAgent.reply(to: "每天晚上9点提醒我吃药", context: c)
        #expect(rem.text.hasPrefix("可以帮你加一条重复提醒：「吃药」，每天 21:00") && rem.blocks.first?.record?.repeats == .daily, "\(rem.text)")
        #expect(HealthAgent.reply(to: "每次透析后提醒我称体重", context: c).text.contains("这种重复方式还不支持"))
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
