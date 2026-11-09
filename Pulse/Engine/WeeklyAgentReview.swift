import Foundation

/// A weekly interpretation uses the selected week's evidence, not today's later observations.
/// The model explains this evidence; proposed actions and numerical targets stay with the engines.
enum WeeklyAgentReview {
    static func scoped(_ c: AgentContext, weekStart: Date, recording: Bool) -> AgentContext {
        let end = min(c.now, weekStart.adding(days: 7).addingTimeInterval(-1))
        var profile = c.profile
        if recording { profile.goals = []; profile.program = nil }
        var result = AgentContext.make(
            profile: profile, name: c.name,
            days: c.days.filter { $0.day <= end.startOfDay },
            plan: recording ? [] : c.plan,
            workouts: c.workouts.filter { $0.start <= end },
            vitals: c.vitals.filter { $0.time <= end },
            events: c.openEvents.filter { $0.date <= end }, stopBang: [], baselineSetAt: nil,
            raceName: c.raceName, targetRHR: recording ? nil : c.targetRHR,
            weather: weekStart == c.weekStart ? c.weather : [], weatherSource: c.weatherSource,
            labs: c.labs.filter { $0.date <= end }, now: end)
        result.stopBangScore = c.stopBangScore
        result.answerMode = c.answerMode
        result.healthDataConsented = c.healthDataConsented
        result.agentName = c.agentName
        return result
    }

    static func priorities(_ original: [ReviewPriority], target: TargetMetric?) -> [ReviewPriority] {
        guard let target else { return original }
        let area: PriorityArea = switch target {
        case .homeBP, .clinicBP: .bloodPressure
        case .restingHR: .rhr
        case .vo2max, .weeklyRunKm: .activity
        case .weight: .weight
        case .cgmTIR, .postMealGlucose, .fastingGlucose: .glucose
        }
        return [ReviewPriority(area: area, reason: "本轮主靶点：" + target.title, mine: false)] + original.filter { $0.area != area }
    }

    /// The model writes a reason for the first five proposals only; the items after them are the next week's changes.
    static let writtenProposals = 5

    /// The reason shown under the proposal at `index`: the written one when there is one, otherwise its own.
    static func rationale(_ items: [String], proposal p: CoachProposal, index: Int) -> String {
        index < writtenProposals && items.indices.contains(index) ? items[index] : p.rationale
    }

    static func proposals(_ values: [CoachProposal], recording: Bool) -> [CoachProposal] {
        guard recording else { return values }
        return values.filter {
            switch $0.action {
            case .dropWeekday, .setStepsTarget: false
            default: true
            }
        }
    }

    static func facts(context c: AgentContext, brief: WeeklyBrief, week: WeekSnapshot, weekLabel: String,
                      current: Bool, recording: Bool, sample: Bool, target: ProgramWeekReport?,
                      goal: TargetGoal?, proposals: [CoachProposal], plan: NextWeekPlan?,
                      priorities: [ReviewPriority], notes: ReviewNotes?) -> ReviewFacts {
        var summary: String
        if let target, !recording {
            summary = targetSummary(target, goal: goal)
            if !target.excused, week.total > 0, (week.completion ?? 1) < 0.75 {
                summary += "训练还没有形成规律，下周先把安排调到更容易做到的量。"
            } else if target.excused {
                summary += "这周有生病或出差记录，先恢复日常节奏，不按普通训练周评价。"
            }
        } else {
            var story = brief.story
            if recording || !current { story?.next = nil }
            summary = story?.text ?? brief.detail
        }
        let hasRecords = c.days.contains { $0.day >= week.weekStart && ($0.rhr != nil || $0.sleepMinutes != nil || $0.steps != nil || $0.checkedIn || $0.exerciseMinutes != nil || $0.sessionMinutes > 0 || $0.nutrientsLogged) }
            || c.vitals.contains { $0.time >= week.weekStart }
            || c.workouts.contains { $0.start >= week.weekStart }
        if !hasRecords { summary = "这一周还没有足够记录，暂时无法判断身体变化。先连接健康或补充记录，等有了可比较的数据再解读。" }

        let trainingPlan = recording ? nil : plan
        let offered = Array(Self.proposals(proposals, recording: recording).prefix(writtenProposals))
        let changes = Array((trainingPlan?.changes ?? []).prefix(8 - offered.count))
        let references = offered.map { "建议「\($0.title)」：\($0.rationale)" }
            + changes.map { "下周调整「\($0.title)」：\($0.detail)" }
        let items = offered.map(\.rationale) + changes.map(\.detail)
        let profile = c.profile
        let conditions = profile.conditions.map(\.label).sorted().joined(separator: "、")
        let medications = Set(c.medications.map { $0.category.label }).sorted().joined(separator: "、")
        var lines = [
            "【周期】\(weekLabel)\(current ? "（尚在进行中，仅评价已有记录）" : "（已结束）")",
            "【资料类型】\(sample ? "测试模式的模拟资料" : "个人记录")；档案信息按当前填写内容，不能反推疾病或用药在历史周已存在。",
            "【使用方向】\(recording ? "只记录身体状况，不评价训练达标、不新增训练目标" : "按已选方案改善")",
            "【个人背景】\(profile.ageText)；\(profile.sex.label)；已记录健康状况：\(conditions.isEmpty ? "未记录，不代表已确认没有" : conditions)；已记录用药类别：\(medications.isEmpty ? "未记录" : medications)",
            "【优先事项】" + priorities.prefix(3).map(\.area.label).joined(separator: "、"),
            "【写作要点】主线：\(summary)",
            "【本周观察】" + brief.watch.map { $0.title + "：" + $0.detail }.joined(separator: "；")
        ]
        if let target, !recording {
            let measure = target.target
            lines.append("【主靶点】\(measure.label)：\(measure.valueText) \(measure.unitShort)；读数 \(measure.count) 条；基线 \(goal?.baseline.map { TargetTracker.text(measure.target, $0) } ?? "不足")；目标 \(goal?.goal.map { TargetTracker.text(measure.target, $0) } ?? "待确认")；\(target.beyondNoise ? "变化超出常见测量波动，仍需持续观察" : "尚不足以排除测量波动")。行为完成不等于健康结果改善。")
        }
        if let association = c.associations.first(where: { $0.sufficient && $0.unfavorable && $0.strength >= .moderate }) {
            lines.append("【个人关联】\(association.factor)与\(association.metric)：有该行为 \(association.nWith) 天均值 \(association.withMean.oneDecimal)，没有该行为 \(association.nWithout) 天均值 \(association.withoutMean.oneDecimal) \(association.unit)。仅为观察到的关联，不能据此确定变化原因。")
        }
        if let notes {
            lines.append("【本人本周反馈】保持：\(notes.keep)；困难或想改变：\(notes.change)；下周关注：\(notes.focus)。这是本人描述，不是已确认的病因。")
        }
        if let plan = trainingPlan {
            let trainings = plan.sessions.filter { $0.kind.isTraining }
            lines.append("【下周已拟安排】训练 \(Set(trainings.map(\.weekday)).count) 天，共 \(trainings.map(\.minutes).reduce(0, +)) 分钟；只有用户确认才采纳，模型不能另改目标或加练。")
        }
        lines.append(references.isEmpty ? "【条目】无（items 为空）" : "【条目】\n" + references.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        return ReviewFacts(kind: "week-agent-v1-" + (sample ? "sample" : "own"), text: lines.joined(separator: "\n"),
                           fallback: ReviewCopy(headline: brief.headline, summary: summary, items: items), references: references, knownNames: [c.name],
                           explainsWeek: true)
    }

    static func targetSummary(_ report: ProgramWeekReport, goal t: TargetGoal?) -> String {
        let r = report.target
        let baseline = t?.baseline, goal = t?.goal
        guard let value = r.value else { return "\(r.target.title)的读数还不够，这周先不判断改善效果。" }
        var line = "\(r.label)为 \(r.valueText) \(r.unitShort)。"
        if let goal, TargetTracker.reached(r.target, value: value, goal: goal) {
            line += "本次统计已达到本轮目标，继续观察能否维持，单次达标不代表整轮已经完成。"
        } else if let baseline {
            let difference = value - baseline
            if !report.beyondNoise {
                line += "和基线的差别仍在常见波动范围内，还不能判断有稳定改善。"
            } else {
                let favorable = r.target.higherIsBetter ? difference > 0 : difference < 0
                line += favorable ? "比基线向目标方向变化，接下来继续观察能否保持。" : "比基线离目标更远一些，需要结合测量、习惯和身体状况再看。"
            }
        } else { line += "还缺可比较的基线，暂时不评价是否改善。" }
        return line
    }
}
