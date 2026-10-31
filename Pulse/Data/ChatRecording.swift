import Foundation
import SwiftData

/// Writes what a 记下 card in the conversation holds, and takes it back on 撤销.
extension DataHub {
    struct RecordUndo: Equatable {
        var vitals: [UUID] = []
        var labs: [UUID] = []
        var tasks: [UUID] = []
        var waterDay: Date? = nil
        var waterMl = 0
        /// The day's swelling and urine before, to put back.
        var signsDay: Date? = nil
        var edema: Int? = nil
        var places: [String] = []
        var urine: Int? = nil
        var foamy: Bool? = nil
    }

    /// Records the card's items; the reminder's date is the one shown on the card. New readings are
    /// checked against the same alert rules as a reading logged in a form.
    @discardableResult
    static func applyRecord(_ p: RecordProposal, reminderDue: Date? = nil, in ctx: ModelContext) -> RecordUndo {
        var undo = RecordUndo()
        let snap = profile(in: ctx)?.snapshot(medications: medications(in: ctx)) ?? ProfileSnapshot()
        var newLabs: [LabPoint] = []
        let history = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        for item in p.items {
            switch item {
            case .bloodPressure(let s, let d, let c):
                let v = VitalReading(time: p.time, kind: .bloodPressure, value: Double(s), value2: Double(d), context: c)
                v.note = "在对话里记下"
                ctx.insert(v)
                undo.vitals.append(v.id)
            case .glucose(let g, let c):
                let v = VitalReading(time: p.time, kind: .glucose, value: g, context: c)
                v.note = "在对话里记下"
                ctx.insert(v)
                undo.vitals.append(v.id)
            case .weight(let kg):
                let v = VitalReading(time: p.time, kind: .weight, value: kg, context: .morning)
                v.note = "在对话里记下"
                ctx.insert(v)
                undo.vitals.append(v.id)
            case .water(let ml):
                let r = record(for: p.time, in: ctx)
                r.waterMl += ml
                undo.waterDay = r.day
                undo.waterMl = ml
            case .swelling, .urine, .foamyUrine:
                let r = record(for: p.time, in: ctx)
                if undo.signsDay == nil {
                    undo.signsDay = r.day
                    undo.edema = r.edema; undo.places = r.edemaPlaces; undo.urine = r.urineOutput; undo.foamy = r.foamyUrine
                }
                switch item {
                case .swelling(let e, let places): r.edema = e.rawValue; r.edemaPlaces = places
                case .urine(let u): r.urineOutput = u.rawValue
                default: r.foamyUrine = true
                }
            case .lab(let k, let v):
                let day = p.time.startOfDay.adding(minutes: 8 * 60)
                let l = LabResult(date: day, kind: k, value: v)
                l.note = "在对话里记下"
                ctx.insert(l)
                undo.labs.append(l.id)
                newLabs.append(l.point)
                // Creatinine alone gives an estimated eGFR, as in the form.
                if k == .creatinine, !p.items.contains(where: { if case .lab(.egfr, _) = $0 { true } else { false } }),
                   let e = LabAnalyzer.ckdEPI(creatinine: v, age: snap.age, sex: snap.sex) {
                    let est = LabResult(date: day, kind: .egfr, value: e.rounded(), estimated: true)
                    ctx.insert(est)
                    undo.labs.append(est.id)
                    newLabs.append(est.point)
                }
            case .reminder(let title, let area, let due, _):
                let t = CareTask(title: title, area: area, due: reminderDue ?? due, note: "在对话里添加")
                t.createdAt = .app
                ctx.insert(t)
                undo.tasks.append(t.id)
            }
        }
        if let c = LabAnalyzer.alert(for: newLabs, history: history, profile: snap) { addEvent(c, in: ctx) }
        try? ctx.save()
        if !undo.vitals.isEmpty || undo.signsDay != nil { refreshAlerts(in: ctx) }
        try? ctx.save()
        if !undo.tasks.isEmpty { CareReminders.sync(in: ctx) }
        return undo
    }

    /// 撤销: removes what the card added and puts the day's values back.
    static func undoRecord(_ u: RecordUndo, in ctx: ModelContext) {
        for id in u.vitals {
            for v in (try? ctx.fetch(FetchDescriptor<VitalReading>(predicate: #Predicate { $0.id == id }))) ?? [] { ctx.delete(v) }
        }
        for id in u.labs {
            for l in (try? ctx.fetch(FetchDescriptor<LabResult>(predicate: #Predicate { $0.id == id }))) ?? [] { ctx.delete(l) }
        }
        for id in u.tasks {
            for t in (try? ctx.fetch(FetchDescriptor<CareTask>(predicate: #Predicate { $0.id == id }))) ?? [] { ctx.delete(t) }
        }
        if let d = u.waterDay {
            let r = record(for: d, in: ctx)
            r.waterMl = max(0, r.waterMl - u.waterMl)
        }
        if let d = u.signsDay {
            let r = record(for: d, in: ctx)
            r.edema = u.edema; r.edemaPlaces = u.places; r.urineOutput = u.urine; r.foamyUrine = u.foamy
        }
        try? ctx.save()
        if !u.tasks.isEmpty { CareReminders.sync(in: ctx) }
    }
}
