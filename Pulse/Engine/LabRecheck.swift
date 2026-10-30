import Foundation

// MARK: - When to recheck lab results

/// One kind of recheck and when it is next due.
struct LabRecheckItem: Equatable, Identifiable {
    enum Group: String, CaseIterable { case kidney, potassium, hba1c, uricAcid }
    enum Status { case overdue, soon, later, noRecord }

    let group: Group
    /// What is checked (「eGFR、血肌酐、尿白蛋白/肌酐比，通常和血钾一起查」).
    let tests: String
    /// The latest result in the group; nil before one is recorded.
    let last: Date?
    /// When it is next due; nil without a result to count from.
    let due: Date?
    /// 「一般每 6 个月一次」.
    let interval: String
    /// What the interval rests on (「eGFR 57（G3a）、尿白蛋白/肌酐比 45（A2）」).
    let basis: String

    var id: String { group.rawValue }
    /// 「肾功能」.
    var name: String {
        switch group {
        case .kidney: "肾功能"
        case .potassium: "血钾"
        case .hba1c: "糖化血红蛋白"
        case .uricAcid: "尿酸"
        }
    }
    /// 「复查肾功能」: also the title of the 照护与随访 task Pulse adds.
    var title: String { "复查" + name }
    var area: CareArea { group == .hba1c ? .diabetes : .kidney }

    func status(now: Date) -> Status {
        guard let d = due else { return .noRecord }
        if d < now.startOfDay { return .overdue }
        return d <= now.adding(days: LabRecheck.taskLead) ? .soon : .later
    }
}

/// When each lab result is next due, from the latest results and the person's conditions: kidney
/// function by KDIGO risk (eGFR × albuminuria), an out-of-range potassium within weeks, HbA1c by
/// whether it is at target (ADA), a high uric acid about twice a year. Patient-education level: a
/// date the doctor gave always wins — it is kept as the 照护与随访 task's due date.
enum LabRecheck {
    /// Days before the due date that the 照护与随访 task appears.
    static let taskLead = 30
    /// Days before the due date that 今日 flags it.
    static let flagLead = 7

    static func items(_ labs: [LabPoint], profile p: ProfileSnapshot, now: Date) -> [LabRecheckItem] {
        func latest(_ k: LabKind, within days: Int = 3650) -> LabPoint? {
            labs.filter { $0.kind == k && $0.date > now.adding(days: -days) }.max { $0.date < $1.date }
        }
        let day = Date.FormatStyle().month().day()
        let egfr = LabAnalyzer.egfrSeries(labs).last, uacr = latest(.uacr), cr = latest(.creatinine)
        let ua = latest(.uricAcid, within: 365)
        let uaHigh = ua.map { $0.value > 420 } ?? false
        let ckd = p.conditions.contains(.ckd) || egfr.map { $0.value < 60 } == true || uacr.map { $0.value >= 30 } == true
        var out: [LabRecheckItem] = []

        if ckd {
            let months = kidneyMonths(egfr: egfr?.value, uacr: uacr?.value)
            let last = [egfr?.date, uacr?.date, cr?.date].compactMap { $0 }.max()
            var with = ["血钾"]
            if (egfr?.value ?? 60) < 60 || labs.contains(where: { $0.kind == .hemoglobin }) { with.append("血红蛋白") }
            if (egfr?.value ?? 60) < 45 || labs.contains(where: { $0.kind == .phosphorus }) { with.append("血磷") }
            if uaHigh { with.append("尿酸") }
            let basis = [egfr.map { "eGFR \($0.valueText)（\(LabAnalyzer.egfrStage($0.value).code)）" },
                         uacr.map { "尿白蛋白/肌酐比 \($0.valueText)（\(LabAnalyzer.uacrStage($0.value).code)）" }].compactMap { $0 }
            out.append(.init(group: .kidney, tests: "eGFR、血肌酐、尿白蛋白/肌酐比，通常和\(with.joined(separator: "、"))一起查",
                             last: last, due: last?.adding(months: months).startOfDay, interval: "一般每 \(months) 个月一次",
                             basis: basis.isEmpty ? "慢性肾病" : basis.joined(separator: "、") + "，按 KDIGO 的风险分级"))
        }
        if let k = latest(.potassium, within: 180), k.value > 5.0 || k.value < 3.5 {
            out.append(.init(group: .potassium, tests: "血钾",
                             last: k.date, due: k.date.adding(days: 28).startOfDay, interval: "偏\(k.value > 5 ? "高" : "低")时一般几周内复查，按医生的安排",
                             basis: "\(k.date.formatted(day)) 血钾 \(k.valueText) mmol/L"))
        }
        if p.hasDiabetes {
            let a = latest(.hba1c, within: 400)
            let atTarget = a.map { $0.value <= 7.0 } ?? false
            out.append(.init(group: .hba1c, tests: "糖化血红蛋白（HbA1c）",
                             last: a?.date, due: a?.date.adding(months: atTarget ? 6 : 3).startOfDay,
                             interval: atTarget ? "达标时一般每 6 个月一次" : "还没达标时一般每 3 个月一次",
                             basis: a.map { "上次 \($0.valueText)%\(atTarget ? "，在 7% 以内" : "")" } ?? "糖尿病"))
        }
        if uaHigh, !ckd, let ua {
            out.append(.init(group: .uricAcid, tests: "血尿酸",
                             last: ua.date, due: ua.date.adding(months: 6).startOfDay, interval: "偏高时一般半年左右复查一次",
                             basis: "上次 \(ua.valueText) μmol/L"))
        }
        return out
    }

    /// KDIGO: how often eGFR and albuminuria are checked, by risk — about 1, 2, 3 or 4 times a year.
    static func kidneyMonths(egfr: Double?, uacr: Double?) -> Int {
        switch (egfr ?? 60, uacr ?? 0) {
        case (..<30, _): 3
        case (30..<45, 30...), (45..<60, 300...): 4
        case (30..<45, _), (45..<60, 30...), (60..., 300...): 6
        default: 12
        }
    }

    // MARK: Reminders as 照护与随访 tasks

    /// Which rechecks a task title is about — the task Pulse adds, or one the user or 复盘 added
    /// (「复查肾功能和血钾」「糖化血红蛋白（HbA1c）检测」).
    static func groups(inTitle t: String) -> Set<LabRecheckItem.Group> {
        var out: Set<LabRecheckItem.Group> = []
        if ["肾功能", "eGFR", "尿白蛋白"].contains(where: t.contains) { out.insert(.kidney) }
        if t.contains("血钾") { out.insert(.potassium) }
        if ["糖化血红蛋白", "HbA1c"].contains(where: t.contains) { out.insert(.hba1c) }
        if t.contains("尿酸") { out.insert(.uricAcid) }
        return out
    }

    /// A task as the plan below sees it.
    struct Task {
        let title: String
        let createdAt: Date
        let done: Bool
        let due: Date?
    }

    /// Tasks to tick off (a newer result has come in) and items to add as tasks (due within
    /// `taskLead` days, and no task for this round yet — open or ticked off by the user).
    static func plan(items: [LabRecheckItem], tasks: [Task], labs: [LabPoint], now: Date) -> (complete: [Int], add: [LabRecheckItem]) {
        func latest(_ g: LabRecheckItem.Group) -> Date? {
            let kinds: [LabKind] = switch g {
            case .kidney: [.egfr, .uacr, .creatinine]
            case .potassium: [.potassium]
            case .hba1c: [.hba1c]
            case .uricAcid: [.uricAcid]
            }
            return labs.filter { kinds.contains($0.kind) }.map(\.date).max()
        }
        // A result after the task was added answers it, and so does one from the week before it was due
        // (a task added long ago). Not the result it was added for: that would tick it off at once.
        func answered(_ t: Task, by d: Date?) -> Bool {
            guard let d else { return false }
            return d > t.createdAt || t.due.map { d >= $0.adding(days: -7).startOfDay } == true
        }
        var complete: [Int] = []
        for (i, t) in tasks.enumerated() where !t.done {
            let groups = groups(inTitle: t.title)
            if groups.contains(where: { answered(t, by: latest($0)) }) { complete.append(i) }
        }
        var add: [LabRecheckItem] = []
        for item in items {
            guard let due = item.due, due <= now.adding(days: taskLead) else { continue }
            let last = latest(item.group)
            let round = tasks.enumerated().contains { i, t in
                groups(inTitle: t.title).contains(item.group) && !complete.contains(i) && !answered(t, by: last)
            }
            if !round { add.append(item) }
        }
        return (complete, add)
    }
}
