import Foundation

struct AdjustmentContext: Equatable {
    var readiness: ReadinessResult?
    var availableMinutes: Int?
    var soreness: Int = 0
    var sorenessArea: SorenessArea = .none
    var energy: Int?
    var illness = false
    var urgentEventOpen = false
    var activeMinutesSoFar: Double = 0
    var stepsSoFar: Int = 0
    var stepsTarget: Int = 8000
    var missedKeySessions: [SessionSnapshot] = []
    var cardiacLimited = false
}

struct AdjustmentProposal: Identifiable, Equatable {
    var id: UUID
    var original: SessionSnapshot
    var kind: PlanKind
    var title: String
    var minutes: Int
    var intensity: Intensity
    var reasons: [String]
    var countsAsDone = false
    var changed: Bool {
        kind != original.kind || title != original.title || minutes != original.minutes || intensity != original.intensity || countsAsDone
    }
}

struct AdjustmentResult: Equatable {
    var proposals: [AdjustmentProposal]
    var notes: [String]
    var swapSuggestion: String?
    var anyChange: Bool { proposals.contains(where: \.changed) }
}

/// Adapts today's sessions to readiness, what has already been done, soreness, fatigue and
/// available time — and explains every change (需求 5).
enum PlanAdjuster {
    static func adjust(sessions: [SessionSnapshot], context c: AdjustmentContext) -> AdjustmentResult {
        var proposals: [AdjustmentProposal] = []
        var notes: [String] = []
        let level = c.readiness?.level
        let scoreText = c.readiness?.score.map { "准备度 \($0)" } ?? "准备度"

        for s in sessions where s.status == .planned {
            var p = AdjustmentProposal(id: s.id, original: s, kind: s.kind, title: s.title,
                                       minutes: s.minutes, intensity: s.intensity, reasons: [])

            if c.urgentEventOpen && s.kind.isTraining {
                p.kind = .rest; p.title = "暂停训练，先处理待核实的异常"; p.minutes = 0; p.intensity = .rest
                p.reasons.append("有尚未处理的紧急 / 需核实事件。在确认身体状况前，不建议进行训练。")
                proposals.append(p); continue
            }
            if c.illness && s.kind != .rest {
                p.kind = .rest; p.title = "休息；如感觉尚可，仅轻松散步 10–20 分钟"; p.minutes = min(20, s.minutes); p.intensity = .easy
                p.reasons.append("记录了生病 / 不适：身体需要把资源用于恢复，训练可能延长恢复时间。症状消退 1–2 天后再逐步恢复。")
                proposals.append(p); continue
            }

            if s.kind.isTraining {
                // Readiness
                switch level {
                case .rest:
                    p.kind = .mobility; p.title = "轻松散步或拉伸"; p.minutes = min(20, max(10, s.minutes / 2)); p.intensity = .easy
                    p.reasons.append("\(scoreText)（需要休息）：今天以恢复为主，计划中的训练不需要补回。")
                case .low:
                    if s.intensity == .hard || s.kind == .quality {
                        p.kind = .aerobic; p.title = "以低强度有氧替代「\(s.title)」"; p.intensity = .easy
                        p.minutes = max(20, Int(Double(s.minutes) * 0.7).roundedTo5())
                        p.reasons.append("\(scoreText)（恢复不足）：暂缓强度课，低强度有氧同样能积累有氧能力。")
                    } else if s.kind == .strength {
                        p.title = "轻量力量或灵活性训练"; p.intensity = .easy
                        p.minutes = max(10, Int(Double(s.minutes) * 0.6).roundedTo5())
                        p.reasons.append("\(scoreText)（恢复不足）：降低力量训练负荷，以动作质量为主。")
                    } else if s.kind == .long {
                        p.minutes = max(20, Int(Double(s.minutes) * 0.7).roundedTo5()); p.intensity = .easy
                        p.reasons.append("\(scoreText)（恢复不足）：长时间有氧缩短约 30%，保持轻松强度。")
                    } else if s.intensity > .easy {
                        p.intensity = .easy
                        p.reasons.append("\(scoreText)（恢复不足）：强度降为低强度。")
                    }
                case .moderate:
                    if s.intensity == .hard {
                        p.minutes = max(20, Int(Double(s.minutes) * 0.8).roundedTo5())
                        p.title = s.title + "（减量）"
                        p.reasons.append("\(scoreText)（基本恢复）：保留强度课，但减少约 1/3 的高强度组数。")
                    }
                default:
                    break
                }

                // Soreness
                if c.soreness >= 2 {
                    if p.kind == .strength {
                        switch c.sorenessArea {
                        case .lower: p.title = "上肢与核心力量（避开下肢）"
                        case .upper: p.title = "下肢与核心力量（避开上肢）"
                        default: p.kind = .mobility; p.title = "灵活性与拉伸"; p.intensity = .easy
                        }
                        p.reasons.append("肌肉酸痛明显：避免继续给酸痛部位加负荷。")
                    } else if [.aerobic, .long, .quality].contains(p.kind), c.sorenessArea == .lower || c.sorenessArea == .whole {
                        p.title = "低冲击有氧（骑行、游泳或快走）"
                        if p.intensity > .easy { p.intensity = .easy }
                        p.reasons.append("下肢 / 全身酸痛：换成低冲击方式，减少对酸痛部位的冲击。")
                    }
                    if c.soreness >= 3 { p.minutes = max(10, Int(Double(p.minutes) * 0.7).roundedTo5()) }
                }

                // Fatigue when readiness did not already lower things
                if let e = c.energy, e <= 2, level == .high || level == .moderate || level == nil, p.intensity > .easy {
                    p.intensity = p.intensity.lowered
                    p.reasons.append("醒后精力较低（\(e)/5）：强度下调一级，结合运动中的感受再决定是否继续。")
                }

                // Cardiac care limit
                if c.cardiacLimited && p.intensity == .hard {
                    p.intensity = .moderate
                    p.reasons.append("较高强度尚未得到医生确认，保持在中等强度以内。")
                }
            }

            // Already active today
            if [.aerobic, .walk].contains(p.kind), c.activeMinutesSoFar >= 10 {
                if c.activeMinutesSoFar >= Double(p.minutes) * 0.8 {
                    p.countsAsDone = true
                    p.reasons.append("今天已累计约 \(Int(c.activeMinutesSoFar)) 分钟中等强度活动，可以计为完成本次有氧。")
                } else {
                    let remaining = max(10, p.minutes - Int(c.activeMinutesSoFar)).roundedTo5()
                    if remaining < p.minutes {
                        p.minutes = remaining
                        p.reasons.append("今天已累计约 \(Int(c.activeMinutesSoFar)) 分钟活动，剩余约 \(remaining) 分钟即可。")
                    }
                }
            }

            // Busy day
            if let avail = c.availableMinutes, avail < p.minutes, !p.countsAsDone {
                if avail >= s.minimumMinutes && s.minimumMinutes > 0 {
                    p.minutes = max(s.minimumMinutes, avail.roundedTo5())
                    if !s.minimumDetail.isEmpty && avail <= s.minimumMinutes + 5 { p.title = "精简版：" + s.minimumDetail }
                    p.reasons.append("今天可用时间约 \(avail) 分钟：采用精简版。保持规律比单次时长更重要。")
                } else if avail >= 5 {
                    p.kind = .walk; p.title = "碎片化活动：\(avail) 分钟快走或爬楼梯"; p.minutes = avail; p.intensity = .easy
                    p.reasons.append("时间很紧：做一点也有帮助，不需要在其他日子补练。")
                } else {
                    p.kind = .rest; p.title = "今天跳过，不必补练"; p.minutes = 0; p.intensity = .rest
                    p.reasons.append("偶尔跳过一次不会影响长期效果；避免之后集中补练造成负荷突增。")
                }
            }
            proposals.append(p)
        }

        // Week-level notes
        let todayEasy = proposals.allSatisfy { $0.intensity <= .easy }
        if let missed = c.missedKeySessions.first, level == .high, todayEasy, (c.availableMinutes ?? 999) >= missed.minutes {
            let swap = "本周的「\(missed.title)」未完成。若今天时间充裕，可以用它替换今天的轻松课；不要在同一天叠加补练。"
            notes.append("错过的轻松课不需要补，按今天的安排继续即可。")
            return AdjustmentResult(proposals: proposals, notes: notes, swapSuggestion: swap)
        }
        if !c.missedKeySessions.isEmpty {
            notes.append("本周有 \(c.missedKeySessions.count) 次重点课未完成。结合准备度，今天不建议补练，下周计划会根据完成情况自动调整。")
        }
        if Double(c.stepsSoFar) >= 1.5 * Double(c.stepsTarget), level == .low || level == .rest {
            notes.append("今天活动量已较大，结合准备度偏低，剩余时间以恢复为主。")
        }
        if proposals.isEmpty {
            notes.append(level == .high ? "今天没有待完成的训练。状态不错，可以轻松散步、保持步数目标。" : "今天没有待完成的训练，好好休息。")
        }
        return AdjustmentResult(proposals: proposals, notes: notes, swapSuggestion: nil)
    }
}

// MARK: - Bedtime recovery focus (需求 7)

struct RecoveryItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let priority: Int
}

enum RecoveryAdvisor {
    static func bedtimeFocus(today: DayData?, history: [DayData], profile p: ProfileSnapshot,
                             readiness: ReadinessResult?, tomorrow: [SessionSnapshot], now: Date = .app) -> [RecoveryItem] {
        var items: [RecoveryItem] = []
        let d = today ?? DayData(day: now)
        let chronic = (Stats.mean(history.suffix(28).map(\.load)) ?? 0)

        let bedtime = Clock.text(d.plannedBedtime?.minutesOfDay ?? p.bedtimeMinutes)
        var bedDetail = "目标睡眠 \((p.sleepNeedMinutes / 60).oneDecimal) 小时。睡前 1 小时调暗灯光、减少屏幕。"
        if readiness?.level == .low || readiness?.level == .rest {
            bedDetail = "今天恢复偏弱，今晚比平时早 30 分钟上床，优先补足睡眠。"
        }
        items.append(.init(id: "bedtime", icon: "moon.stars.fill", title: "\(bedtime) 前上床", detail: bedDetail, priority: 0))

        if d.load > 0 && (d.hardSession || (chronic > 0 && d.load > 1.5 * chronic)) {
            items.append(.init(id: "refuel", icon: "fork.knife", title: "训练后的补充",
                               detail: "今天训练负荷较高：晚餐保证优质蛋白和适量碳水，\(p.fluidLimited ? "饮水仍按医生定的量" : "补足水分")。", priority: 1))
        }
        if d.hadAlcohol {
            items.append(.init(id: "alcohol", icon: "wineglass", title: "饮酒后的恢复",
                               detail: "今天饮酒 \(d.alcoholUnits.oneDecimal) 单位：\(p.fluidLimited ? "" : "睡前补水，")不再继续饮酒。明早心率偏高时，Pulse 会把这一因素纳入解读。", priority: 1))
        }
        if d.lateCaffeine(cutoff: p.caffeineCutoffHour) {
            items.append(.init(id: "caffeine", icon: "cup.and.saucer", title: "咖啡因可能影响入睡",
                               detail: "今天 \(p.caffeineCutoffHour) 点后摄入了咖啡因。若入睡困难，先做放松练习，不要强迫入睡。", priority: 2))
        }
        if (d.eveningSoreness ?? 0) >= 2 {
            items.append(.init(id: "soreness", icon: "figure.cooldown", title: "放松酸痛部位",
                               detail: "睡前 10 分钟轻柔拉伸或泡沫轴放松，温水淋浴也有帮助；避免在疼痛部位用力按压。", priority: 1))
        }
        if (d.eveningFatigue ?? 0) >= 4 {
            items.append(.init(id: "fatigue", icon: "battery.25", title: "今天比较疲劳",
                               detail: "今晚优先睡眠，明早先看准备度再决定训练安排。", priority: 1))
        }
        if d.highStress || (d.eveningStress ?? 0) >= 4 {
            items.append(.init(id: "stress", icon: "wind", title: "睡前放松 10 分钟",
                               detail: "今天压力较大：慢呼吸（每分钟约 6 次）、轻柔拉伸，或把明天的待办写下来。", priority: 1))
        }
        if d.lateMeal {
            items.append(.init(id: "meal", icon: "clock", title: "晚餐较晚",
                               detail: "睡前 2–3 小时避免大量进食，若饥饿可选择少量清淡食物。", priority: 3))
        }
        if p.fluidLimited {
            if d.waterMl > p.waterTargetMl {
                items.append(.init(id: "water", icon: "drop", title: "饮水超过上限",
                                   detail: "今天已喝约 \(d.waterMl) ml，超过医生定的 \(p.waterTargetMl) ml。今晚不再额外喝水，口渴时含一小口或用冰块润口；留意脚踝是否浮肿、明早称一下体重。", priority: 1))
            }
        } else if d.waterMl > 0 && Double(d.waterMl) < Double(p.waterTargetMl) * 0.6 {
            items.append(.init(id: "water", icon: "drop", title: "适量补水",
                               detail: "今天饮水约 \(d.waterMl) ml，傍晚前适当补充，睡前不要大量饮水以免夜醒。", priority: 3))
        }
        if p.apneaStatus == .diagnosed && p.apneaTreatment == .cpap {
            items.append(.init(id: "cpap", icon: "lungs.fill", title: "整晚使用 CPAP",
                               detail: "检查面罩与管路，目标每晚使用 ≥\(Int(p.cpapTargetHours)) 小时。", priority: 0))
        } else if p.apneaStatus == .diagnosed && p.apneaTreatment == .oralAppliance {
            items.append(.init(id: "oral", icon: "mouth", title: "佩戴口腔矫治器", detail: "按医嘱整晚佩戴。", priority: 0))
        } else if p.apneaStatus == .suspected || p.apneaStatus == .evaluating || history.suffix(7).filter(\.snoring).count >= 3 {
            items.append(.init(id: "breathing", icon: "lungs", title: "照顾夜间呼吸",
                               detail: "尽量侧卧睡，睡前 3 小时不饮酒、不服用助眠类药物（除非医生要求）；家人观察到憋气或呼吸暂停时请记录下来。", priority: 1))
        }
        if p.hasDiabetes && p.hypoRiskMeds() && d.activeMinutes >= 30 {
            items.append(.init(id: "glucose", icon: "drop.fill", title: "睡前血糖",
                               detail: "今天有运动且使用胰岛素 / 磺脲类药物，夜间低血糖风险较高，按照护计划检查睡前血糖。", priority: 0))
        }
        if let key = tomorrow.first(where: { $0.isKey && $0.status == .planned }) {
            items.append(.init(id: "tomorrow", icon: "calendar", title: "明天：\(key.title)",
                               detail: "明天有重点训练，今晚保证睡眠；运动装备提前准备好。", priority: 2))
        }
        items.append(.init(id: "device", icon: "applewatch", title: "佩戴设备入睡",
                           detail: "确认手表电量充足（>30%）并佩戴入睡，以记录夜间心率、HRV 和睡眠。没有设备时，明早醒来静躺 1 分钟后手动测量。", priority: 4))
        return items.sorted { $0.priority < $1.priority }
    }
}
