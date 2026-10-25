import Foundation

// Guidance on using wearables for training: the watch (optical heart rate, sleep), a chest strap
// for intervals, and a CGM. The local part is deterministic: which devices the records show, how
// complete their data is, and conservative general advice for the user's training. A cloud model,
// when enabled, turns these facts into a personal guide. Device-specific steps defer to the
// manufacturer's instructions; nothing here changes medication or insulin.

struct DeviceFinding: Identifiable, Equatable {
    var id: String
    var icon: String
    var title: String
    var detail: String
    var ok: Bool
}

enum DeviceFocus: Equatable { case watch, cgm, both }

/// What the user's training asks of the devices.
struct TrainingNeeds: Equatable {
    var intervals = false
    var longRuns = false
    var strength = false
    var easyAerobic = true
    var glucoseExercise = false
    var hrCap: Int?
    var rateLoweringMeds = false
    var easyRange: (lo: Int, hi: Int)?

    static func == (a: TrainingNeeds, b: TrainingNeeds) -> Bool {
        a.intervals == b.intervals && a.longRuns == b.longRuns && a.strength == b.strength && a.glucoseExercise == b.glucoseExercise
            && a.hrCap == b.hrCap && a.rateLoweringMeds == b.rateLoweringMeds && a.easyRange?.lo == b.easyRange?.lo && a.easyRange?.hi == b.easyRange?.hi
    }
}

enum DeviceGuide {
    static let deviceNouns = ["手表", "表带", "胸带", "心率带", "CGM", "cgm", "传感器", "探头", "戒指", "设备", "手环", "Watch", "watch", "穿戴"]
    static let usageWords = ["戴", "贴", "准", "校准", "滞后", "延迟", "误差", "位置", "部位", "更换", "充电", "电量", "同步", "缺", "断",
                             "掉", "游泳", "洗澡", "出汗", "怎么用", "使用", "设置", "提醒", "读数", "选"]

    static func isRequest(_ q: String) -> Bool {
        if ["怎么戴", "戴哪", "贴哪", "心率不准", "数据缺失", "没有数据", "数据不全"].contains(where: { q.contains($0) }) { return true }
        return deviceNouns.contains { q.contains($0) } && usageWords.contains { q.contains($0) }
    }

    static func focus(_ q: String, context c: AgentContext) -> DeviceFocus {
        let cgm = ["CGM", "cgm", "传感器", "探头", "血糖"].contains { q.contains($0) }
        let watch = ["手表", "表带", "胸带", "心率带", "戒指", "手环", "心率", "Watch", "watch"].contains { q.contains($0) }
        if cgm && !watch { return .cgm }
        if watch && !cgm { return .watch }
        return usesCGM(c) ? .both : .watch
    }

    static func usesCGM(_ c: AgentContext) -> Bool { c.glucose.isContinuous || c.profile.modules.contains(.diabetesCare) }

    static func needs(_ c: AgentContext) -> TrainingNeeds {
        let p = c.profile
        let week = c.plan.filter { $0.day >= c.now.adding(days: -14) && $0.day < c.now.adding(days: 14) }
        var n = TrainingNeeds()
        n.intervals = week.contains { $0.kind == .quality || $0.intensity == .hard } || c.workouts.contains { $0.type == .hiit && $0.start > c.now.adding(days: -28) }
        n.longRuns = c.marathonActive || week.contains { $0.kind == .long && $0.minutes >= 60 }
        n.strength = week.contains { $0.kind == .strength }
        n.glucoseExercise = p.hasDiabetes || c.glucose.isContinuous
        n.hrCap = p.hrCap
        n.rateLoweringMeds = p.onRateLoweringMeds(at: c.now)
        if !n.rateLoweringMeds {
            let mx = p.estimatedMaxHR
            var hi = Int(0.70 * mx)
            if let cap = p.hrCap { hi = min(hi, cap) }
            n.easyRange = (min(Int(0.60 * mx), hi - 5), hi)
        }
        return n
    }

    // MARK: Data quality from the user's records

    static func findings(_ c: AgentContext, focus: DeviceFocus) -> [DeviceFinding] {
        var out: [DeviceFinding] = []
        let today = c.now.startOfDay
        if focus != .cgm {
            let last28 = c.days.filter { $0.day > today.adding(days: -28) && $0.day <= today }
            let nights = last28.filter { $0.sleepMinutes != nil }.count
            out.append(DeviceFinding(id: "nights", icon: "moon.stars.fill",
                                     title: "近 28 天 \(nights) 晚有睡眠数据",
                                     detail: nights >= 22 ? "夜间佩戴比较规律，静息心率和 HRV 的趋势可信。"
                                         : "夜间没戴表或电量不足的晚上，静息心率、HRV 和睡眠都会缺失，趋势判断会变慢。",
                                     ok: nights >= 22))
            if let gap = longestGap(c.days.filter { $0.day > today.adding(days: -60) }.filter { $0.rhr != nil }.map(\.day), until: today), gap.days >= 3 {
                out.append(DeviceFinding(id: "gap", icon: "calendar.badge.exclamationmark",
                                         title: "最长连续 \(gap.days) 天没有静息心率",
                                         detail: "从 \(gap.start.formatted(.dateTime.month().day())) 开始。中断后的头几天读数波动较大，Pulse 会等数据稳定后再判断趋势。",
                                         ok: false))
            }
            let recent = c.workouts.filter { $0.start > c.now.adding(days: -28) && $0.type != .strength && $0.type != .yoga }
            let noHR = recent.filter { $0.avgHR == nil }.count
            if !recent.isEmpty {
                out.append(DeviceFinding(id: "workoutHR", icon: "heart.fill",
                                         title: noHR == 0 ? "近 28 天 \(recent.count) 次有氧训练都有心率" : "\(noHR)/\(recent.count) 次有氧训练没有心率",
                                         detail: noHR == 0 ? "训练时佩戴正常。" : "开始训练时在手表上选择对应的体能训练类型，或检查训练时是否戴紧。",
                                         ok: noHR == 0))
            }
            if !c.profile.onRateLoweringMeds(at: c.now) {
                let limit = 0.85 * c.profile.estimatedMaxHR
                let suspicious = recent.filter { ($0.rpe ?? 10) <= 4 && ($0.avgHR ?? 0) >= limit }.count
                if suspicious > 0 {
                    out.append(DeviceFinding(id: "lock", icon: "waveform.path.ecg",
                                             title: "\(suspicious) 次轻松训练的平均心率偏高（≥\(Int(limit)) bpm）",
                                             detail: "感觉轻松但心率很高，可能是光学心率跟上了步频或佩戴松动，也可能强度确实偏高。下次用心率带对比一次。",
                                             ok: false))
                }
            }
        }
        if focus != .watch, usesCGM(c) {
            let g = c.glucose
            if g.readings > 0 {
                out.append(DeviceFinding(id: "coverage", icon: "sensor.fill",
                                         title: "近 14 天 CGM 数据覆盖 \(Int(g.coverage * 100))%",
                                         detail: g.coverage >= 0.7 ? "达到 70% 以上，达标时间等指标可信。" : "低于 70%，达标时间等指标参考性有限。检查传感器是否脱落、手机是否在接收范围内。",
                                         ok: g.coverage >= 0.7))
            } else {
                out.append(DeviceFinding(id: "coverage", icon: "sensor.fill", title: "近 14 天没有 CGM 数据",
                                         detail: "佩戴 CGM 后在「我的 › 数据来源」中允许读取血糖，Pulse 才能分析运动和饮食前后的变化。", ok: false))
            }
            if let gap = longestCGMGap(c), gap.hours >= 2 {
                out.append(DeviceFinding(id: "cgmGap", icon: "exclamationmark.triangle",
                                         title: "最长中断约 \(gap.hours) 小时",
                                         detail: "发生在 \(gap.start.formatted(.dateTime.month().day().hour().minute()))。可能是传感器预热、更换或信号中断。", ok: false))
            }
            let night = c.lows.filter(\.nocturnal)
            if !night.isEmpty {
                out.append(DeviceFinding(id: "nightLows", icon: "moon.zzz.fill",
                                         title: "\(night.count) 次低值发生在夜间",
                                         detail: "睡觉压住传感器时，读数可能一过性偏低；但也可能是真实的夜间低血糖，不能只凭推测忽略。出现症状或读数低时用指尖血复核，并告诉医生。",
                                         ok: false))
            }
        }
        return out
    }

    static func longestGap(_ days: [Date], until today: Date) -> (start: Date, days: Int)? {
        let sorted = Array(Set(days)).sorted()
        guard sorted.count >= 2 else { return nil }
        var best: (Date, Int)? = nil
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let missing = b.daysSince(a) - 1
            if missing > (best?.1 ?? 0) { best = (a.adding(days: 1), missing) }
        }
        if let last = sorted.last, today.daysSince(last) - 1 > (best?.1 ?? 0) { best = (last.adding(days: 1), today.daysSince(last) - 1) }
        return best.map { ($0.0, $0.1) }
    }

    static func longestCGMGap(_ c: AgentContext) -> (start: Date, hours: Int)? {
        let times = c.vitals.filter { $0.kind == .glucose && $0.time > c.now.adding(days: -14) }.map(\.time).sorted()
        guard times.count > 96 else { return nil }
        var best: (Date, TimeInterval)? = nil
        for (a, b) in zip(times, times.dropFirst()) where b.timeIntervalSince(a) > (best?.1 ?? 0) { best = (a, b.timeIntervalSince(a)) }
        return best.map { ($0.0, Int($0.1 / 3600)) }
    }

    // MARK: General guidance for the training

    static func checklist(_ c: AgentContext, focus: DeviceFocus) -> AgentChecklist {
        let n = needs(c)
        let p = c.profile
        var items: [AgentChecklistItem] = []
        if focus != .cgm {
            items.append(.init(id: "fit", title: "戴在腕骨上方一指处",
                               detail: "背面贴紧皮肤；训练时比平时紧一格，结束后再放松。"))
            items.append(.init(id: "night", title: "戴着入睡，电量 > 30%",
                               detail: "夜间数据决定静息心率、HRV 和睡眠。可以在洗澡或晨起时充电。"))
            if n.intervals {
                items.append(.init(id: "strap", title: "间歇训练配对心率带",
                                   detail: "光学心率在快速变速时会滞后；没有心率带时以配速和体感（只能说几个词）为准。"))
            }
            if let cap = n.hrCap {
                items.append(.init(id: "alert", title: "设置 \(cap) bpm 心率提醒",
                                   detail: "这是照护计划的上限。在体能训练的心率提醒中设置，超过时停下来放慢。"))
            } else if let r = n.easyRange {
                items.append(.init(id: "zone", title: "轻松训练设置心率区间 \(r.lo)–\(r.hi)",
                                   detail: "按年龄估算，个体差异大，感受优先：能完整说话就是轻松。"))
            }
            if n.rateLoweringMeds {
                items.append(.init(id: "meds", title: "以体感为准，不追心率",
                                   detail: "你使用的药物可能让心率偏低，心率区间参考性有限。"))
            }
            if n.strength {
                items.append(.init(id: "strength", title: "力量训练记为「传统力量训练」",
                                   detail: "这时心率参考价值有限，看动作质量和用力程度。"))
            }
            if n.longRuns {
                items.append(.init(id: "long", title: "长距离前充满电、开 GPS",
                                   detail: "长距离以轻松区间为上限，配速和心率都记录完整才能估算比赛能力。"))
            }
        }
        if focus != .watch && (usesCGM(c) || p.hasDiabetes) {
            items.append(.init(id: "site", title: "按说明书选部位，避开压迫处",
                               detail: "常见为上臂背侧或腹部；避开疤痕、注射部位，以及背包带、紧身衣和睡觉常压的一侧。"))
            items.append(.init(id: "adhesion", title: "运动前皮肤干燥、加固定贴",
                               detail: "不涂乳液；出汗多时加贴固定贴。游泳是否可用以产品说明为准。"))
            items.append(.init(id: "alerts", title: "打开低值和下降提醒",
                               detail: "训练时手机放在身边才能收到提醒；运动时提醒值设多少，和医生商定。"))
            items.append(.init(id: "carbs", title: "随身带 15–20 g 快速碳水",
                               detail: "如葡萄糖片或含糖饮料，长距离和间歇训练尤其需要。"))
            items.append(.init(id: "finger", title: "备好指尖血糖仪",
                               detail: "读数和感觉不一致、出现低血糖症状、新传感器第一天，用指尖血复核再处理。"))
        }
        return AgentChecklist(id: "device-\(focus == .cgm ? "cgm" : (focus == .watch ? "watch" : "all"))", title: "设备设置清单", items: Array(items.prefix(8)))
    }

    /// CGM around a workout; thresholds are the user's own care-plan settings.
    static func cgmExerciseSteps(_ c: AgentContext) -> AgentSteps {
        let p = c.profile
        let pre = p.glucosePreExerciseMin.oneDecimal, mx = p.glucoseExerciseMax.oneDecimal
        var after = "训练后几小时到当晚，血糖可能继续下降。睡前看一眼读数和趋势。"
        if p.hypoRiskMeds(at: c.now) { after += "你使用的药物有低血糖风险，夜间更要留意提醒。" }
        return AgentSteps(title: "运动时怎么看 CGM", steps: [
            AgentStep(icon: "1.circle", title: "出发前",
                      detail: "看读数和趋势箭头。低于照护计划的运动前下限 \(pre) mmol/L 或正在快速下降时，先补充碳水、等回升；高于 \(mx) mmol/L 时按照护计划处理，暂缓剧烈运动。"),
            AgentStep(icon: "2.circle", title: "训练中",
                      detail: "每 20–30 分钟看一次趋势。CGM 比指尖血晚约 5–15 分钟，运动中下降时实际血糖可能更低。出现心慌、出汗、手抖就停下，用指尖血确认。"),
            AgentStep(icon: "3.circle", title: "训练后", detail: after),
            AgentStep(icon: "4.circle", title: "复盘",
                      detail: "Pulse 会把训练前后的变化放在「血糖管理 › 运动反应」，药物和胰岛素请按医生制定的方案使用。"),
        ])
    }

    // MARK: Answer

    static func reply(_ q: String, context c: AgentContext) -> AgentReply {
        let focus = focus(q, context: c)
        let f = findings(c, focus: focus)
        let n = needs(c)
        var parts: [String] = []
        var need: [String] = []
        if n.intervals { need.append("间歇 / 强度课") }
        if n.longRuns { need.append(c.marathonActive ? "马拉松长距离" : "较长时间的有氧") }
        if n.strength { need.append("力量训练") }
        if n.glucoseExercise && focus != .watch { need.append("运动中的血糖管理") }
        parts.append("你的训练包括\(need.isEmpty ? "规律的轻松有氧" : "轻松有氧和" + need.joined(separator: "、"))。按你的记录，设备使用上有这些情况：")
        let issues = f.filter { !$0.ok }
        parts.append((issues.isEmpty ? f : issues).prefix(3).map { "• \($0.title)。\($0.detail)" }.joined(separator: "\n"))
        if focus != .cgm {
            var watch = n.intervals ? "轻松有氧用手表的光学心率就够了；间歇训练变速快，光学心率会滞后，配对胸前心率带更准。"
                : "轻松有氧用手表的光学心率就够了，关键是戴紧、戴着入睡。"
            if n.strength { watch += "力量训练时心率的参考价值有限，看动作质量和用力程度，不必追求心率数字。" }
            parts.append(watch)
        }
        if focus != .watch && usesCGM(c) {
            parts.append("CGM 测的是组织间液，运动和饭后血糖变化快时会比指尖血晚 5–15 分钟。看趋势箭头比看单个数字更重要，读数和感觉不一致时以指尖血为准。")
        }
        parts.append("具体型号的操作以产品说明书为准。")
        var blocks: [AgentUIBlock] = [.checklist(checklist(c, focus: focus))]
        if focus != .watch && usesCGM(c) { blocks.append(.steps(cgmExerciseSteps(c))) }
        blocks.append(.chart(focus == .cgm ? .glucose : .wear, days: focus == .cgm ? 1 : 28, caption: nil))
        return AgentReply(text: parts.joined(separator: "\n\n"), sources: ["设备数据完整度", focus == .watch ? "训练心率 近 28 天" : "CGM 近 14 天"],
                          followUps: focus == .watch ? ["间歇训练要买心率带吗？", "今天适合运动吗？"] : ["运动后多久看一次血糖？", "我的血糖控制得怎么样？"],
                          destination: focus == .cgm ? .glucose : nil, blocks: blocks)
    }

    /// Facts for the cloud model: devices, data quality and the training they should serve.
    static func grounding(_ q: String, context c: AgentContext) -> String {
        let focus = focus(q, context: c)
        let n = needs(c)
        var lines: [String] = []
        lines.append("设备：手表（光学心率、睡眠）\(usesCGM(c) ? "、CGM" : "")\(c.bp.count > 0 ? "、家用血压计" : "")。")
        var t: [String] = ["轻松有氧"]
        if n.intervals { t.append("间歇 / 强度课") }
        if n.longRuns { t.append(c.marathonActive ? "马拉松长距离（\(c.raceName)）" : "较长时间有氧") }
        if n.strength { t.append("力量训练") }
        lines.append("训练内容：\(t.joined(separator: "、"))。")
        if let cap = n.hrCap { lines.append("照护计划心率上限 \(cap) bpm。") }
        if let r = n.easyRange { lines.append("轻松区间（按年龄估算）\(r.lo)–\(r.hi) bpm。") }
        if n.rateLoweringMeds { lines.append("使用可能降低心率的药物，心率区间参考性有限。") }
        if usesCGM(c) {
            let p = c.profile
            lines.append("照护计划：运动前血糖下限 \(p.glucosePreExerciseMin.oneDecimal)，运动时上限 \(p.glucoseExerciseMax.oneDecimal) mmol/L；目标范围 \(p.glucoseLow.oneDecimal)–\(p.glucoseHigh.oneDecimal)。\(p.hypoRiskMeds(at: c.now) ? "使用有低血糖风险的药物。" : "")")
        }
        lines.append("数据完整度：" + findings(c, focus: focus).map { "\($0.title)（\($0.ok ? "正常" : "需要注意")）" }.joined(separator: "；") + "。")
        lines.append("Pulse 已准备的通用建议：" + checklist(c, focus: focus).items.map { "\($0.title)：\($0.detail)" }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    static let cloudInstructions = """
    你是 Pulse 应用中的 Health Agent，正在针对用户的训练需求，指导穿戴设备（手表、心率带、CGM）的使用。
    要求：
    1. 依据「设备与训练」中的事实（训练内容、照护计划数值、数据完整度）给出个性化指导，引用其中的数字；没有的数据不要编造。
    2. 只给通用、稳妥的使用方法；具体型号的操作、佩戴天数、防水和药物干扰等以产品说明书为准。
    3. 低血糖不能只凭推测排除：读数低或有症状时用指尖血复核。不建议开始、停止或调整任何药物、胰岛素和剂量；运动前后的药物调整按医生制定的方案。
    4. 先用一句话给结论，再按「佩戴」「训练前」「训练中」「训练后」给 3–5 条具体建议（每条以「• 」开头）。不超过 300 字，不用标题和表格。
    5. 用户描述胸痛、呼吸困难、晕厥等紧急症状时，第一句建议立即拨打 120。
    """
}
