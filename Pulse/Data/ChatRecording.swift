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
        var meals: [UUID] = []
        var sessions: [UUID] = []
        /// The day's diet lists before a meal was counted in, to put back.
        var dietDay: Date? = nil
        var diet: [[String]] = []
        var dietLogged = false
        var proteinServings: Double? = nil
        /// A planned session the workout counted for, as it was.
        var planItem: UUID? = nil
        var planMinutes: Int? = nil
        var planStatus: PlanStatus? = nil
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
            case .meal(let m):
                let log = MealLog(time: m.at, kind: m.kind)
                log.note = m.said
                ctx.insert(log)
                undo.meals.append(log.id)
                // Kidney diet: the foods count as in the diet form, in the order of its lists.
                if profile(in: ctx)?.nutrientTracking == true, !m.foods.isEmpty {
                    let r = record(for: m.at, in: ctx)
                    if undo.dietDay == nil {
                        undo.dietDay = r.day
                        undo.diet = [r.proteinFoods, r.potassiumFoods, r.phosphorusFoods, r.saltSources]
                        undo.dietLogged = r.nutrientsLogged
                        undo.proteinServings = r.proteinServings
                    }
                    func merged(_ list: [String], _ names: [String]) -> [String] {
                        names.flatMap { n in Array(repeating: n, count: (list + m.foods).filter { $0 == n }.count) }
                    }
                    r.nutrientsLogged = true
                    r.proteinFoods = merged(r.proteinFoods, DietFoods.proteinFoods.map(\.name))
                    r.potassiumFoods = merged(r.potassiumFoods, DietFoods.potassium)
                    r.phosphorusFoods = merged(r.phosphorusFoods, DietFoods.phosphorus)
                    r.saltSources = DietFoods.salt.filter { r.saltSources.contains($0) || m.foods.contains($0) }
                    if !r.proteinFoods.isEmpty { r.proteinServings = nil }
                }
            case .workout(let w):
                let s = ActivitySession(start: w.start, type: w.type, minutes: Double(w.minutes), source: .manual)
                s.rpe = w.effort; s.distanceKm = w.km; s.note = "在对话里记下"
                // It counts for the session planned that day, as when logged from the plan.
                let day = w.start.startOfDay
                let items = (try? ctx.fetch(FetchDescriptor<PlanItem>(predicate: #Predicate { $0.day == day }))) ?? []
                if let planned = ChatRecord.planned(for: w, in: items.map(\.snapshot)), let item = items.first(where: { $0.id == planned.id }) {
                    undo.planItem = item.id; undo.planMinutes = item.completedMinutes; undo.planStatus = item.status
                    let done = (item.completedMinutes ?? 0) + w.minutes
                    item.completedMinutes = done
                    item.status = Double(done) >= Double(item.minutes) * 0.8 ? .done : .partial
                    s.planItemID = item.id
                }
                ctx.insert(s)
                undo.sessions.append(s.id)
            case .reminder(let title, let area, let due, let timed):
                var when = reminderDue ?? due
                // A repeating one starts at its next time, at the time shown on the card.
                if let r = p.repeats { when = r.first(onOrAfter: .app, minutes: timed ? when.minutesOfDay : nil) }
                let t = CareTask(title: title, area: area, due: when, note: "在对话里添加", repeats: p.repeats)
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
        for id in u.meals {
            for m in (try? ctx.fetch(FetchDescriptor<MealLog>(predicate: #Predicate { $0.id == id }))) ?? [] { ctx.delete(m) }
        }
        for id in u.sessions {
            for s in (try? ctx.fetch(FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.id == id }))) ?? [] { ctx.delete(s) }
        }
        if let d = u.dietDay, u.diet.count == 4 {
            let r = record(for: d, in: ctx)
            r.proteinFoods = u.diet[0]; r.potassiumFoods = u.diet[1]; r.phosphorusFoods = u.diet[2]; r.saltSources = u.diet[3]
            r.nutrientsLogged = u.dietLogged
            r.proteinServings = u.proteinServings
        }
        if let id = u.planItem, let item = ((try? ctx.fetch(FetchDescriptor<PlanItem>(predicate: #Predicate { $0.id == id }))) ?? []).first {
            item.completedMinutes = u.planMinutes
            if let s = u.planStatus { item.status = s }
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
