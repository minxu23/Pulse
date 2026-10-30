import Foundation

struct AlertCandidate: Equatable {
    var dedupeKey: String
    var kind: EventKind
    var severity: Severity
    var title: String
    var detail: String
    var guidance: String
    var relatedDate: Date
    var valueText: String = ""
}

/// Rules that turn data into events needing separate attention (需求 8). These are prompts to
/// verify or seek care — never diagnoses.
enum AlertEngine {
    static let emergencyLine = "如症状正在发生或很严重，请立即拨打 120，不要自行驾车就医。"

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.pulse.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func evaluate(days: [DayData], vitals: [VitalPoint], trend: RHRTrend,
                         profile p: ProfileSnapshot, now: Date = .app) -> [AlertCandidate] {
        var out: [AlertCandidate] = []
        out += rhrAlerts(days: days, trend: trend, profile: p, now: now)
        out += vitalAlerts(vitals.filter { $0.time > now.adding(days: -3) }, profile: p)
        out += bpTrendAlerts(vitals: vitals, profile: p, now: now)
        out += spo2Alerts(days: days, now: now)
        if let w = weightAlert(vitals, profile: p, now: now) { out.append(w) }
        if let k = KidneySigns.alert(days, vitals: vitals, profile: p, now: now) { out.append(k) }
        if let g = Dialysis.alert(vitals, profile: p, now: now) { out.append(g) }
        return out
    }

    // MARK: Weight

    /// For kidney disease, heart failure or a fluid limit: weight up ≥ 2 kg within 3 days usually
    /// means retained fluid, not fat.
    /// On dialysis, gaining between sessions is expected; `Dialysis.alert` reads it against the dry weight.
    static func weightAlert(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> AlertCandidate? {
        guard p.watchesWeight, !p.onDialysis, let g = CardioAnalyzer.weightGain(vitals, now: now) else { return nil }
        let day = Date.FormatStyle().month().day()
        return AlertCandidate(
            dedupeKey: "weightGain-\(dayKey(g.to.time))", kind: .weightGain, severity: .consult,
            title: "3 天内体重增加 \(g.kg.oneDecimal) kg",
            detail: "\(g.from.time.formatted(day)) \(g.from.value.oneDecimal) kg → \(g.to.time.formatted(day)) \(g.to.value.oneDecimal) kg。体重短时间上升，常常是体内存了水，而不是长胖。",
            guidance: "1. 明早起床排尿后、早餐前再称一次，穿差不多的衣服。\n2. 看看脚踝、小腿有没有浮肿，尿量有没有变少，是否比平时容易气短。\n3. 复称仍偏高，或有上面任一情况，请联系你的医生；回顾这几天饮水和吃咸的情况，在「今日」里记下来。\n4. 不要自己加用或停用利尿剂等药物。\n如果休息时也气短、躺下更喘，请立即就医。",
            relatedDate: g.to.time, valueText: "+\(g.kg.oneDecimal) kg")
    }

    // MARK: Resting heart rate

    static func rhrAlerts(days: [DayData], trend: RHRTrend, profile p: ProfileSnapshot, now: Date) -> [AlertCandidate] {
        var out: [AlertCandidate] = []
        let pts = trend.points
        guard pts.count >= 10, let last = pts.last, last.day >= now.startOfDay.adding(days: -3) else { return out }
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })

        let last3 = Array(pts.suffix(3))
        if last3.count == 3, last3.first!.day >= last.day.adding(days: -3) {
            let ref = pts.filter { $0.day < last3.first!.day && $0.day >= last3.first!.day.adding(days: -28) }.map(\.value)
            if ref.count >= 7, let r = Stats.mean(ref) {
                let thr = max(7, 2 * trend.personalSD)
                if last3.allSatisfy({ $0.value - r >= thr }) {
                    let ill = last3.contains { byDay[$0.day]?.isIll == true }
                    let vals = last3.map { $0.value.noDecimal }.joined(separator: " / ")
                    out.append(AlertCandidate(
                        dedupeKey: "rhrRise-\(dayKey(last3.first!.day))",
                        kind: .rhrSustainedRise, severity: ill ? .info : .verify,
                        title: "静息心率连续 3 天明显高于平时",
                        detail: "近 3 天为 \(vals) bpm，此前 4 周平均约 \(r.noDecimal) bpm。" + (ill ? "同期记录了生病 / 不适。" : "未记录到明确的相关背景。"),
                        guidance: ill
                            ? "生病期间静息心率升高较常见，通常在恢复后回落。期间以休息为主；若持续升高、或出现胸痛、气短、心悸，请就医。"
                            : "1. 确认测量条件一致（佩戴松紧、测量时间、是否刚起身）。\n2. 回顾近期饮酒、熬夜、压力、感染迹象或用药变化，并补充记录。\n3. 这几天以休息或低强度活动为主。\n4. 若持续超过 1 周，或伴随胸闷、心悸、发热、明显乏力，请咨询医生。",
                        relatedDate: last.day, valueText: "\(last.value.noDecimal) bpm"))
                }
            }
        }

        let recent = pts.suffix(3)
        if recent.filter({ $0.value > 100 }).count >= 2 {
            out.append(AlertCandidate(
                dedupeKey: "rhrHigh-\(dayKey(last.day.weekStart))", kind: .rhrHigh, severity: .consult,
                title: "静息状态心率超过 100 bpm",
                detail: "近 3 次中有 \(recent.filter { $0.value > 100 }.count) 次超过 100 bpm。成人静息心率通常在 60–100 bpm。",
                guidance: "安静休息 5 分钟后复测，确认不是刚活动、发热或焦虑造成的。若仍持续偏高，或伴随心悸、头晕、气短，请咨询医生。\(emergencyLine)",
                relatedDate: last.day, valueText: "\(last.value.noDecimal) bpm"))
        }

        let lowThreshold: Double = p.onRateLoweringMeds(at: last.day) ? 50 : 40
        if recent.filter({ $0.value < lowThreshold }).count >= 2 && !(p.level == .athlete && lowThreshold == 40) {
            out.append(AlertCandidate(
                dedupeKey: "rhrLow-\(dayKey(last.day.weekStart))", kind: .rhrLow, severity: .consult,
                title: "静息心率偏低",
                detail: p.onRateLoweringMeds(at: last.day)
                    ? "近期多次低于 \(Int(lowThreshold)) bpm，且正在使用可能降低心率的药物。"
                    : "近期多次低于 \(Int(lowThreshold)) bpm。",
                guidance: "长期规律训练者静息心率偏低可能是正常的。若伴随头晕、乏力、运动耐力下降或晕厥，请及时就医；正在服用降心率药物时，请告知开药医生。",
                relatedDate: last.day, valueText: "\(last.value.noDecimal) bpm"))
        }
        return out
    }

    // MARK: Spot vitals

    static func vitalAlerts(_ vitals: [VitalPoint], profile p: ProfileSnapshot) -> [AlertCandidate] {
        vitals.compactMap { evaluateVital($0, profile: p) }
    }

    static func evaluateVital(_ v: VitalPoint, profile p: ProfileSnapshot) -> AlertCandidate? {
        let key = dayKey(v.time)
        switch v.kind {
        case .bloodPressure:
            let sys = v.value, dia = v.value2 ?? 0
            if sys >= 180 || dia >= 120 {
                return AlertCandidate(
                    dedupeKey: "bpCrisis-\(key)", kind: .bpCrisis, severity: .urgent,
                    title: "血压显著升高（≥180/120 mmHg）",
                    detail: "测得 \(Int(sys))/\(Int(dia)) mmHg（\(v.context.label)）。",
                    guidance: "安静坐 5 分钟后复测。若复测仍很高，并伴随胸痛、气短、背痛、肢体麻木无力、视物模糊或说话困难，请立即拨打 120。若无症状，也请尽快联系医生。",
                    relatedDate: v.time, valueText: "\(Int(sys))/\(Int(dia))")
            }
            if sys < 90 && v.context == .symptom {
                return AlertCandidate(
                    dedupeKey: "bpLow-\(key)", kind: .bpLow, severity: .consult,
                    title: "有症状时血压偏低",
                    detail: "出现症状时测得 \(Int(sys))/\(Int(dia)) mmHg。",
                    guidance: "坐下或躺下，缓慢起身。若反复出现头晕、晕厥，或正在服用降压药，请咨询医生。\(emergencyLine)",
                    relatedDate: v.time, valueText: "\(Int(sys))/\(Int(dia))")
            }
        case .glucose:
            if v.value < 3.0 {
                return AlertCandidate(
                    dedupeKey: "glucoseSevereLow-\(key)", kind: .glucoseSevereLow, severity: .urgent,
                    title: "血糖低于 3.0 mmol/L",
                    detail: "测得 \(v.value.oneDecimal) mmol/L（\(v.context.label)）。",
                    guidance: "立即按照护计划处理（通常为摄入 15–20 g 快速碳水，15 分钟后复测）。如出现意识不清或无法进食，请身边的人立即拨打 120。事后与医疗团队讨论原因。",
                    relatedDate: v.time, valueText: v.value.oneDecimal)
            }
            if v.value < p.glucoseLow {
                return AlertCandidate(
                    dedupeKey: "glucoseLow-\(key)", kind: .glucoseLow, severity: .verify,
                    title: "血糖低于 \(p.glucoseLow.oneDecimal) mmol/L",
                    detail: "测得 \(v.value.oneDecimal) mmol/L（\(v.context.label)）。",
                    guidance: "按照护计划处理：摄入 15 g 快速碳水，15 分钟后复测，直至恢复。之后记录可能原因（运动、进食延迟、用药），反复出现请联系医疗团队。",
                    relatedDate: v.time, valueText: v.value.oneDecimal)
            }
            if v.value > 13.9 {
                return AlertCandidate(
                    dedupeKey: "glucoseHigh-\(key)", kind: .glucoseHigh, severity: .consult,
                    title: "血糖高于 13.9 mmol/L",
                    detail: "测得 \(v.value.oneDecimal) mmol/L（\(v.context.label)）。",
                    guidance: "按照护计划处理。1 型糖尿病请按医嘱检测酮体；酮体阳性或伴随恶心、呕吐、腹痛时，避免运动并尽快就医。持续高于目标请联系医疗团队。",
                    relatedDate: v.time, valueText: v.value.oneDecimal)
            }
        case .spo2:
            if v.value < 92 && v.context != .night {
                return AlertCandidate(
                    dedupeKey: "spo2-\(key)", kind: .spo2Low, severity: v.value < 88 ? .urgent : .consult,
                    title: "血氧饱和度偏低",
                    detail: "测得 \(Int(v.value))%（\(v.context.label)）。",
                    guidance: "先确认手指温暖、静止、读数稳定后复测。若仍低于 92%，或伴随气短、胸痛、意识改变，请及时就医。\(emergencyLine)",
                    relatedDate: v.time, valueText: "\(Int(v.value))%")
            }
        case .temperature:
            if v.value >= 38.0 {
                return AlertCandidate(
                    dedupeKey: "fever-\(key)", kind: .other, severity: .info,
                    title: "体温 ≥38 °C",
                    detail: "测得 \(v.value.oneDecimal) °C。发热时静息心率通常会升高。",
                    guidance: "发热期间暂停训练，多休息、补水。高热不退或伴随胸痛、气短，请就医。",
                    relatedDate: v.time, valueText: v.value.oneDecimal)
            }
        default:
            break
        }
        return nil
    }

    static func bpTrendAlerts(vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> [AlertCandidate] {
        let bp = vitals.filter { $0.kind == .bloodPressure && $0.time > now.adding(days: -14) }
            .sorted { $0.time < $1.time }.suffix(5)
        guard bp.count >= 3,
              let sys = Stats.mean(bp.map(\.value)),
              let dia = Stats.mean(bp.compactMap(\.value2)) else { return [] }
        let key = dayKey(now.weekStart)
        if sys >= 140 || dia >= 90 {
            return [AlertCandidate(
                dedupeKey: "bpHigh-\(key)", kind: .bpHigh, severity: .consult,
                title: "近期血压平均 ≥140/90 mmHg",
                detail: "最近 \(bp.count) 次平均 \(Int(sys))/\(Int(dia)) mmHg。",
                guidance: "规范测量：测前安静坐 5 分钟、背部有支撑、袖带与心脏同高，每次测 2 遍取平均。持续偏高请咨询医生；已在治疗中请把记录带给医生，不要自行调整药物。",
                relatedDate: bp.last!.time, valueText: "\(Int(sys))/\(Int(dia))")]
        }
        if p.hasCardiac && (sys > Double(p.bpTargetSys) || dia > Double(p.bpTargetDia)) {
            return [AlertCandidate(
                dedupeKey: "bpTarget-\(key)", kind: .bpHigh, severity: .verify,
                title: "血压高于照护目标",
                detail: "最近 \(bp.count) 次平均 \(Int(sys))/\(Int(dia)) mmHg，目标 \(p.bpTargetSys)/\(p.bpTargetDia)。",
                guidance: "继续按规范测量并记录用药情况；下次随访时与医生讨论。不要自行调整药物。",
                relatedDate: bp.last!.time, valueText: "\(Int(sys))/\(Int(dia))")]
        }
        return []
    }

    static func spo2Alerts(days: [DayData], now: Date) -> [AlertCandidate] {
        let recent = days.filter { $0.day > now.adding(days: -7) }
        let lowNights = recent.filter { ($0.spo2Min ?? 100) < 88 }
        guard lowNights.count >= 2, let last = lowNights.map(\.day).max() else { return [] }
        return [AlertCandidate(
            dedupeKey: "spo2Night-\(dayKey(now.weekStart))", kind: .spo2Low, severity: .verify,
            title: "近一周多晚夜间血氧偏低",
            detail: "近 7 晚中有 \(lowNights.count) 晚最低血氧 <88%。",
            guidance: "可能与睡眠呼吸问题有关，也可能是佩戴松动造成的读数误差。请在「睡眠」中查看打鼾、憋醒等线索，并考虑进行专业睡眠评估。白天也偏低或伴随气短时请及时就医。",
            relatedDate: last, valueText: "<88%")]
    }

    // MARK: Symptoms

    static func symptomEvent(_ s: Symptom, at time: Date, note: String, profile p: ProfileSnapshot) -> AlertCandidate {
        let guidance: String
        switch s {
        case .chestPain:
            guidance = "立即停止活动并坐下休息。胸痛 / 胸闷持续数分钟不缓解、伴随出汗、气短、恶心或向肩背放射时，立即拨打 120。已有医生开具的急救药物，请按医嘱使用。"
        case .fainting:
            guidance = "晕厥需要尽快就医评估。若伴随胸痛、心悸或在运动中发生，请立即拨打 120。"
        case .breathless:
            guidance = "停止活动并坐下休息。休息后不缓解、或伴随胸痛、嘴唇发紫，请立即拨打 120。"
        case .palpitations:
            guidance = "记录发生时间、持续时长、当时在做什么以及心率读数。反复出现或伴随头晕、胸闷、晕厥，请咨询医生。"
        case .dizziness:
            guidance = "坐下或躺下，缓慢起身，补充水分。反复出现、伴随心悸或晕厥，请咨询医生。"
        case .unusualFatigue:
            guidance = "今天以休息为主，关注睡眠与饮食。持续数天或伴随气短、胸闷、发热时请咨询医生。"
        case .swelling:
            guidance = "记录肿胀部位与体重变化。新出现或加重的下肢水肿，特别是伴随气短时，请尽快联系医生。"
        case .hypoSymptoms:
            guidance = p.hasDiabetes
                ? "如有条件立即测血糖，按照护计划处理（通常摄入 15 g 快速碳水，15 分钟后复测）。意识不清时请身边的人拨打 120。"
                : "坐下休息并进食少量含糖食物。反复出现请咨询医生。"
        }
        return AlertCandidate(
            dedupeKey: "symptom-\(s.rawValue)-\(Int(time.timeIntervalSince1970))",
            kind: .symptom, severity: s.severity, title: s.label,
            detail: note.isEmpty ? "自述症状。" : "自述：\(note)",
            guidance: guidance, relatedDate: time)
    }
}
