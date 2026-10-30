import Foundation

// 化验结果: kidney function and the blood tests that go with it, entered from the lab report.
// Pulse reads each value against common adult reference ranges and the KDIGO stages, estimates
// eGFR from creatinine (CKD-EPI 2021, no race term) and follows the eGFR trend. It never
// diagnoses: stages need two results 3 months apart and a doctor; ranges differ between labs.

enum LabKind: String, Codable, CaseIterable, Identifiable {
    case egfr, uacr, creatinine, potassium, phosphorus, hemoglobin, uricAcid, hba1c
    var id: String { rawValue }
    var label: String {
        switch self {
        case .egfr: "eGFR"
        case .uacr: "尿白蛋白/肌酐比"
        case .creatinine: "血肌酐"
        case .potassium: "血钾"
        case .phosphorus: "血磷"
        case .hemoglobin: "血红蛋白"
        case .uricAcid: "血尿酸"
        case .hba1c: "糖化血红蛋白"
        }
    }
    /// What it tells, in one line.
    var meaning: String {
        switch self {
        case .egfr: "估算肾小球滤过率，反映肾脏的过滤功能"
        case .uacr: "尿里漏出的白蛋白，反映肾脏有没有受损（化验单上也叫 UACR / ACR）"
        case .creatinine: "肾功能变差时会升高；Pulse 用它估算 eGFR"
        case .potassium: "过高或过低都会影响心跳和肌肉"
        case .phosphorus: "肾功能下降时容易升高，影响骨骼和血管"
        case .hemoglobin: "偏低就是贫血，静息心率会偏高、运动更容易累"
        case .uricAcid: "偏高可能引起痛风，也和肾脏有关"
        case .hba1c: "近 2–3 个月的平均血糖"
        }
    }
    var unit: String {
        switch self {
        case .egfr: "mL/min/1.73m²"
        case .uacr: "mg/g"
        case .creatinine, .uricAcid: "μmol/L"
        case .potassium, .phosphorus: "mmol/L"
        case .hemoglobin: "g/L"
        case .hba1c: "%"
        }
    }
    /// The units lab reports use; the first is Pulse's own (`unit`).
    var units: [String] {
        switch self {
        case .uacr: ["mg/g", "mg/mmol"]
        case .creatinine, .uricAcid: ["μmol/L", "mg/dL"]
        case .phosphorus: ["mmol/L", "mg/dL"]
        case .hemoglobin: ["g/L", "g/dL"]
        case .hba1c: ["%", "mmol/mol"]
        default: [unit]
        }
    }
    /// A value in one of `units`, in Pulse's own unit.
    func standard(_ v: Double, unit u: String) -> Double {
        switch (self, u) {
        case (.uacr, "mg/mmol"): v * 8.84
        case (.creatinine, "mg/dL"): v * 88.4
        case (.uricAcid, "mg/dL"): v * 59.48
        case (.phosphorus, "mg/dL"): v * 0.3229
        case (.hemoglobin, "g/dL"): v * 10
        case (.hba1c, "mmol/mol"): v / 10.929 + 2.152
        default: v
        }
    }
    var decimals: Int {
        switch self {
        case .potassium, .hba1c: 1
        case .phosphorus: 2
        default: 0
        }
    }
    /// Values outside this are typing mistakes.
    var plausible: ClosedRange<Double> {
        switch self {
        case .egfr: 1...200
        case .uacr: 0...10000
        case .creatinine: 10...2500
        case .potassium: 1.5...9
        case .phosphorus: 0.2...5
        case .hemoglobin: 30...250
        case .uricAcid: 30...1500
        case .hba1c: 3...20
        }
    }
    var icon: String {
        switch self {
        case .egfr, .creatinine: "drop.halffull"
        case .uacr: "flask"
        case .hba1c: "drop.fill"
        default: "testtube.2"
        }
    }
    /// Kidney function first, then the blood tests that go with it.
    var isKidney: Bool { [.egfr, .uacr, .creatinine].contains(self) }

    func format(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
}

struct LabPoint: Equatable {
    var date: Date
    var kind: LabKind
    var value: Double
    /// eGFR worked out from creatinine rather than printed on the report.
    var estimated = false
    var valueText: String { kind.format(value) }
}

/// How one result reads against the usual range.
struct LabStatus: Equatable {
    enum Level: Int, Comparable {
        case normal, watch, abnormal, urgent
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    var level: Level
    /// 「偏低」「G3a · 轻到中度下降」.
    var text: String
}

enum LabAnalyzer {
    static let rangeNote = "各医院的参考范围略有不同，以化验单上的为准。"

    /// eGFR from serum creatinine (μmol/L) by CKD-EPI 2021; nil without a sex or for under-18s.
    static func ckdEPI(creatinine umol: Double, age: Int, sex: Sex) -> Double? {
        guard sex != .unspecified, umol > 0, age >= 18 else { return nil }
        let scr = umol / 88.4
        let female = sex == .female
        let k = female ? 0.7 : 0.9, a = female ? -0.241 : -0.302
        var e = 142 * pow(min(scr / k, 1), a) * pow(max(scr / k, 1), -1.2) * pow(0.9938, Double(age))
        if female { e *= 1.012 }
        return e
    }

    /// KDIGO G stage: 「G3a」 and what it means.
    static func egfrStage(_ v: Double) -> (code: String, text: String) {
        switch v {
        case 90...: ("G1", "正常或偏高")
        case 60..<90: ("G2", "轻度下降")
        case 45..<60: ("G3a", "轻到中度下降")
        case 30..<45: ("G3b", "中到重度下降")
        case 15..<30: ("G4", "重度下降")
        default: ("G5", "肾衰竭范围")
        }
    }

    /// KDIGO A stage for albuminuria (mg/g).
    static func uacrStage(_ v: Double) -> (code: String, text: String) {
        switch v {
        case ..<30: ("A1", "正常或轻度增加")
        case 30...300: ("A2", "中度增加")
        default: ("A3", "重度增加")
        }
    }

    static func status(_ kind: LabKind, _ v: Double, profile p: ProfileSnapshot) -> LabStatus {
        let female = p.sex == .female
        switch kind {
        case .egfr:
            let s = egfrStage(v)
            let level: LabStatus.Level = v >= 90 ? .normal : (v >= 60 ? .watch : (v >= 15 ? .abnormal : .urgent))
            return LabStatus(level: level, text: "\(s.code) · \(s.text)")
        case .uacr:
            let s = uacrStage(v)
            return LabStatus(level: v < 30 ? .normal : .abnormal, text: "\(s.code) · \(s.text)")
        case .creatinine:
            guard let e = ckdEPI(creatinine: v, age: p.age, sex: p.sex) else { return LabStatus(level: .normal, text: "填写性别后可以估算 eGFR") }
            let s = status(.egfr, e, profile: p)
            return LabStatus(level: s.level, text: "估算 eGFR 约 \(Int(e.rounded()))（\(egfrStage(e).code)）")
        case .potassium:
            switch v {
            case ..<3.0: return LabStatus(level: .urgent, text: "明显偏低")
            case ..<3.5: return LabStatus(level: .abnormal, text: "偏低")
            case ...5.3: return LabStatus(level: .normal, text: "正常范围（3.5–5.3）")
            case ..<6.0: return LabStatus(level: .abnormal, text: "偏高")
            default: return LabStatus(level: .urgent, text: "明显偏高")
            }
        case .phosphorus:
            if v < 0.81 { return LabStatus(level: .abnormal, text: "偏低") }
            if v > 1.45 { return LabStatus(level: .abnormal, text: "偏高") }
            return LabStatus(level: .normal, text: "正常范围（0.81–1.45）")
        case .hemoglobin:
            let low: Double = female ? 120 : 130
            if v < 90 { return LabStatus(level: .abnormal, text: "明显偏低（贫血）") }
            if v < low { return LabStatus(level: .watch, text: "偏低（贫血，低于 \(Int(low))）") }
            if v > (female ? 160 : 175) { return LabStatus(level: .watch, text: "偏高") }
            return LabStatus(level: .normal, text: "正常范围")
        case .uricAcid:
            let high: Double = female ? 360 : 420
            return v > high ? LabStatus(level: .watch, text: "偏高（高于 \(Int(high))）") : LabStatus(level: .normal, text: "正常范围")
        case .hba1c:
            if p.hasDiabetes {
                if v >= 10 { return LabStatus(level: .abnormal, text: "明显高于常见目标") }
                return v > 7 ? LabStatus(level: .watch, text: "高于常见目标 7%，你的目标以医生定的为准") : LabStatus(level: .normal, text: "在常见目标 7% 以内")
            }
            if v >= 6.5 { return LabStatus(level: .abnormal, text: "在糖尿病的诊断切点以上，需要医生复查确认") }
            if v >= 5.7 { return LabStatus(level: .watch, text: "糖尿病前期范围") }
            return LabStatus(level: .normal, text: "正常范围")
        }
    }

    /// The latest result of each kind, newest first within the usual order.
    static func latest(_ labs: [LabPoint]) -> [LabPoint] {
        LabKind.allCases.compactMap { k in labs.filter { $0.kind == k }.max { $0.date < $1.date } }
    }

    /// eGFR results to follow: measured ones, and estimates on days without a measured one.
    static func egfrSeries(_ labs: [LabPoint]) -> [LabPoint] {
        let measured = labs.filter { $0.kind == .egfr && !$0.estimated }
        let days = Set(measured.map { $0.date.startOfDay })
        return (measured + labs.filter { $0.kind == .egfr && $0.estimated && !days.contains($0.date.startOfDay) }).sorted { $0.date < $1.date }
    }

    /// How eGFR is moving: a yearly change from ≥ 3 results over ≥ 6 months, or the change since
    /// the previous result. KDIGO calls a sustained fall of more than 5 a year rapid.
    static func egfrTrend(_ labs: [LabPoint]) -> (text: String, fast: Bool)? {
        let s = egfrSeries(labs)
        guard s.count >= 2, let first = s.first, let last = s.last else { return nil }
        let span = last.date.timeIntervalSince(first.date) / 86400
        if s.count >= 3, span >= 180 {
            let xs = s.map { $0.date.timeIntervalSince(first.date) / 86400 / 365 }
            let ys = s.map(\.value)
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let den = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
            guard den > 0 else { return nil }
            let slope = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / den
            let per = abs(slope).rounded()
            if slope <= -5 { return ("近 \(Int((span / 30).rounded())) 个月平均每年下降约 \(Int(per))，下降较快", true) }
            if slope < -1 { return ("近 \(Int((span / 30).rounded())) 个月平均每年下降约 \(Int(per))", false) }
            return ("近 \(Int((span / 30).rounded())) 个月大致稳定", false)
        }
        let prev = s[s.count - 2]
        let change = (last.value - prev.value) / prev.value
        if change <= -0.25 { return ("比上次（\(prev.valueText)）下降 \(Int((-change * 100).rounded()))%，下降明显", true) }
        return ("上次是 \(prev.valueText)", false)
    }

    /// Readings that should not wait for the next visit: potassium far out of range, eGFR in the
    /// kidney-failure range, or a fall of a quarter since the previous result.
    static func alert(for new: [LabPoint], history: [LabPoint], profile p: ProfileSnapshot) -> AlertCandidate? {
        let day = AlertEngine.dayKey(new.first?.date ?? .app)
        if let k = new.first(where: { $0.kind == .potassium }), status(.potassium, k.value, profile: p).level == .urgent {
            return AlertCandidate(
                dedupeKey: "labK-\(day)", kind: .labAbnormal, severity: .urgent,
                title: "血钾\(k.value < 3.5 ? "明显偏低" : "明显偏高")（\(k.valueText) mmol/L）",
                detail: "化验日期 \(k.date.formatted(.dateTime.month().day()))，常见参考范围 3.5–5.3 mmol/L。",
                guidance: "血钾过高或过低都会影响心跳。请今天就联系开化验单的医生，按医生的安排复查或处理；在这之前不做运动，不自己加减补钾药、利尿剂等药物，也不自己大量吃或停吃含钾食物。\n出现心慌、心跳不规律、胸闷或明显无力时，" + AlertEngine.emergencyLine,
                relatedDate: k.date, valueText: "\(k.valueText) mmol/L")
        }
        guard let e = new.first(where: { $0.kind == .egfr }) else { return nil }
        if e.value < 15 {
            return AlertCandidate(
                dedupeKey: "labEgfr-\(day)", kind: .labAbnormal, severity: .consult,
                title: "eGFR 低于 15", detail: "\(e.valueText) mL/min/1.73m²（\(e.date.formatted(.dateTime.month().day()))），在肾衰竭范围。",
                guidance: "请尽快和肾内科医生沟通结果和下一步安排。出现明显水肿、气短、尿量明显减少或恶心呕吐时，尽快就医。",
                relatedDate: e.date, valueText: e.valueText)
        }
        let earlier = egfrSeries(history).filter { $0.date < e.date && $0.date > e.date.adding(days: -400) }
        if let prev = earlier.last, (e.value - prev.value) / prev.value <= -0.25 {
            return AlertCandidate(
                dedupeKey: "labEgfrDrop-\(day)", kind: .labAbnormal, severity: .consult,
                title: "eGFR 比上次下降 \(Int(((prev.value - e.value) / prev.value * 100).rounded()))%",
                detail: "\(prev.date.formatted(.dateTime.month().day())) \(prev.valueText) → \(e.date.formatted(.dateTime.month().day())) \(e.valueText)。",
                guidance: "肾功能短时间明显下降，可能和脱水、感染、新用的药（比如止痛药）有关，也可能是病情变化。请尽快把结果给医生看，按医生的安排复查。不要自己停用或加用药物。",
                relatedDate: e.date, valueText: e.valueText)
        }
        return nil
    }

    /// One line for the language models and the clinician summary.
    static func digest(_ labs: [LabPoint], profile p: ProfileSnapshot) -> String? {
        let latest = latest(labs)
        guard !latest.isEmpty else { return nil }
        var parts = latest.map { l in
            "\(l.kind.label) \(l.valueText) \(l.kind.unit)\(l.estimated ? "（由肌酐估算）" : "")，\(status(l.kind, l.value, profile: p).text)，\(l.date.formatted(.dateTime.year().month().day()))"
        }
        if let t = egfrTrend(labs) { parts.append("eGFR 趋势：\(t.text)") }
        return parts.joined(separator: "；")
    }
}
