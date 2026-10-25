import Foundation
import SwiftData

enum ExportCategory: String, CaseIterable, Identifiable {
    case profile, heart, sleep, activity, behavior, vitals, events, medications
    var id: String { rawValue }
    var label: String {
        switch self {
        case .profile: "基础信息与目标"
        case .heart: "静息心率与恢复"
        case .sleep: "睡眠与呼吸线索"
        case .activity: "活动与训练"
        case .behavior: "饮食、饮酒与压力"
        case .vitals: "血压、血糖等指标"
        case .events: "异常事件与照护事项"
        case .medications: "用药"
        }
    }
    var icon: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .heart: "heart"
        case .sleep: "bed.double"
        case .activity: "figure.walk"
        case .behavior: "fork.knife"
        case .vitals: "gauge.with.dots.needle.33percent"
        case .events: "exclamationmark.bubble"
        case .medications: "pills"
        }
    }
}

/// User-controlled export: the user chooses what leaves the device and in which form (需求 10).
@MainActor
enum DataExporter {
    private static let iso = ISO8601DateFormatter()

    private static func fileURL(_ name: String) -> URL {
        let stamp = Date.app.formatted(.iso8601.year().month().day())
        return FileManager.default.temporaryDirectory.appendingPathComponent("Pulse-\(name)-\(stamp)")
    }

    static func json(_ ctx: ModelContext, categories: Set<ExportCategory>) throws -> URL {
        var root: [String: Any] = ["exportedAt": iso.string(from: .app), "app": "Pulse",
                                   "categories": categories.map(\.rawValue).sorted()]
        let records = ((try? ctx.fetch(FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.day)]))) ?? [])
        if let p = DataHub.profile(in: ctx), categories.contains(.profile) {
            root["profile"] = [
                "birthYear": p.birthYear, "sex": p.sexRaw, "heightCm": p.heightCm, "weightKg": p.weightKg,
                "activityLevel": p.activityLevelRaw, "conditions": p.conditionsRaw, "goals": p.goalsRaw,
                "goalNote": p.goalNote, "baselineRHR": p.baselineRHR as Any, "modules": p.modulesRaw,
                "availableWeekdays": p.availableWeekdays, "sessionMinutes": p.sessionMinutes,
                "extraConditions": p.extraConditionsRaw.map { ConditionLibrary.resolve($0).name },
                "fluidLimitMl": p.fluidLimit ? p.waterTargetMl as Any : NSNull(),
            ]
        }
        root["days"] = records.map { r -> [String: Any] in
            var d: [String: Any] = ["date": iso.string(from: r.day)]
            if categories.contains(.heart) {
                d["restingHR"] = r.restingHR as Any; d["rhrSource"] = r.rhrSourceRaw as Any; d["hrv"] = r.hrv as Any
                d["energy"] = r.energy as Any; d["soreness"] = r.soreness as Any; d["illness"] = r.illnessSymptoms
            }
            if categories.contains(.sleep) {
                d["sleepMinutes"] = r.sleepMinutes as Any
                d["sleepStart"] = r.sleepStart.map { iso.string(from: $0) } as Any
                d["spo2Min"] = r.spo2Min as Any; d["breathingDisturbances"] = r.breathingDisturbances as Any
                d["snoring"] = r.snoring; d["gasping"] = r.gasping; d["witnessedApnea"] = r.witnessedApnea
                d["cpapHours"] = r.cpapHours as Any
            }
            if categories.contains(.activity) {
                d["steps"] = r.steps as Any; d["exerciseMinutes"] = r.exerciseMinutes as Any; d["vo2Max"] = r.vo2Max as Any
            }
            if categories.contains(.behavior) {
                d["alcoholUnits"] = r.alcoholUnits; d["caffeineCups"] = r.caffeineCups; d["waterMl"] = r.waterMl
                if r.nutrientsLogged {
                    d["saltG"] = r.saltG as Any; d["saltSources"] = r.saltSources; d["proteinServings"] = r.proteinServings as Any
                    d["potassiumFoods"] = r.potassiumFoods; d["phosphorusFoods"] = r.phosphorusFoods
                }
                d["stress"] = r.stress as Any; d["lateMeal"] = r.lateMeal; d["tags"] = r.tagsRaw; d["note"] = r.dayNote
            }
            return d
        }
        if categories.contains(.activity) {
            root["workouts"] = ((try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []).map {
                ["start": iso.string(from: $0.start), "type": $0.typeRaw, "minutes": $0.minutes, "rpe": $0.rpe as Any,
                 "avgHR": $0.avgHR as Any, "distanceKm": $0.distanceKm as Any, "source": $0.sourceRaw] as [String: Any]
            }
        }
        if categories.contains(.vitals) {
            root["vitals"] = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map {
                ["time": iso.string(from: $0.time), "kind": $0.kindRaw, "value": $0.value, "value2": $0.value2 as Any,
                 "context": $0.contextRaw, "medsTaken": $0.medsTaken as Any, "source": $0.sourceRaw, "note": $0.note] as [String: Any]
            }
            root["labs"] = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map {
                ["date": iso.string(from: $0.date), "kind": $0.kindRaw, "name": $0.kind.label, "value": $0.value, "unit": $0.kind.unit,
                 "estimated": $0.estimated, "note": $0.note] as [String: Any]
            }
        }
        if categories.contains(.events) {
            root["events"] = ((try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? []).map {
                ["date": iso.string(from: $0.relatedDate), "kind": $0.kindRaw, "severity": $0.severityRaw,
                 "status": $0.statusRaw, "title": $0.title, "detail": $0.detail, "followUp": $0.followUpLog] as [String: Any]
            }
            root["careTasks"] = ((try? ctx.fetch(FetchDescriptor<CareTask>())) ?? []).map {
                ["title": $0.title, "area": $0.areaRaw, "due": $0.due.map { iso.string(from: $0) } as Any, "done": $0.done] as [String: Any]
            }
        }
        if categories.contains(.medications) {
            root["medications"] = DataHub.medications(in: ctx).map {
                ["name": $0.name, "category": $0.categoryRaw, "dose": $0.dose, "start": iso.string(from: $0.startDate),
                 "end": $0.endDate.map { iso.string(from: $0) } as Any] as [String: Any]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let url = fileURL("data").appendingPathExtension("json")
        try data.write(to: url)
        return url
    }

    static func csv(_ ctx: ModelContext) throws -> URL {
        let records = ((try? ctx.fetch(FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.day)]))) ?? [])
        var lines = ["日期,静息心率,来源,HRV,睡眠小时,入睡时间,步数,运动分钟,精力,酸痛,压力,饮酒单位,咖啡杯数,饮水ml,标签"]
        for r in records {
            let cells: [String] = [
                r.day.formatted(.iso8601.year().month().day()),
                r.restingHR.map { $0.noDecimal } ?? "", r.rhrSource?.shortLabel ?? "", r.hrv.map { $0.noDecimal } ?? "",
                r.sleepMinutes.map { ($0 / 60).oneDecimal } ?? "", r.sleepStart.map { Clock.text($0.minutesOfDay) } ?? "",
                r.steps.map(String.init) ?? "", r.exerciseMinutes.map { $0.noDecimal } ?? "",
                r.energy.map(String.init) ?? "", r.soreness.map(String.init) ?? "", r.stress.map(String.init) ?? "",
                r.alcoholUnits > 0 ? r.alcoholUnits.oneDecimal : "", String(r.caffeineCups), String(r.waterMl),
                r.tags.map(\.label).sorted().joined(separator: "/"),
            ]
            lines.append(cells.joined(separator: ","))
        }
        let url = fileURL("daily").appendingPathExtension("csv")
        try ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A concise summary to bring to a doctor's visit; contains only the chosen categories.
    static func clinicianSummary(_ ctx: ModelContext, categories: Set<ExportCategory>) throws -> URL {
        let a = DataHub.analytics(in: ctx)
        let p = a.profile
        let profile = DataHub.profile(in: ctx)
        var out: [String] = ["Pulse 健康摘要（用户自行记录与设备数据，仅供就诊沟通参考，非医疗诊断）",
                             "生成时间：\(Date.app.formatted(date: .long, time: .shortened))", ""]
        if categories.contains(.profile) {
            out.append("【基础信息】")
            out.append("年龄 \(p.age) 岁 · 性别 \(p.sex.label) · BMI \(String(format: "%.1f", p.bmi)) · 活动水平 \(p.level.label)")
            if !p.conditionNames.isEmpty { out.append("已知情况：\(p.conditionNames.joined(separator: "、"))") }
            if p.fluidLimited { out.append("限水：每天不超过 \(p.waterTargetMl) ml") }
            if let note = profile?.goalNote, !note.isEmpty { out.append("个人目标：\(note)") }
            out.append("")
        }
        if categories.contains(.medications), !p.medications.isEmpty {
            out.append("【用药】")
            for m in p.medications {
                out.append("· \(m.name)（\(m.category.label)）\(m.start.formatted(date: .numeric, time: .omitted)) 起\(m.end.map { " 至 \($0.formatted(date: .numeric, time: .omitted))" } ?? "")")
            }
            out.append("")
        }
        if categories.contains(.heart) {
            let t = a.trend
            out.append("【静息心率】（测量方式：\(t.dominantSource?.label ?? "—")）")
            out.append("个人基线 \(t.baseline.map { $0.noDecimal } ?? "—") bpm · 近 7 天平均 \(t.avg7.map { $0.noDecimal } ?? "—") · 近 4 周平均 \(t.avg28.map { $0.noDecimal } ?? "—")")
            out.append("解读：\(t.headline)")
            for l in t.limitations { out.append("局限：\(l)") }
            out.append("")
        }
        if categories.contains(.sleep) {
            let s = SleepAnalyzer.summary(days: a.days, profile: p, window: 30)
            let c = SleepAnalyzer.breathingCues(days: a.days)
            out.append("【睡眠与呼吸线索（近 30 天）】")
            out.append("平均睡眠 \(s.avgMinutes.map { ($0 / 60).oneDecimal } ?? "—") 小时 · 平均入睡 \(s.avgBedtime.map(Clock.text) ?? "—") · \(s.regularityText)")
            out.append("打鼾 \(c.snoring) 晚 · 憋醒 \(c.gasping) 晚 · 他人观察到呼吸暂停 \(c.witnessed) 次 · 晨起头痛 \(c.headache) 天 · 白天困倦 \(c.sleepy) 天 · 夜间最低血氧 <88% \(c.lowSpO2Nights) 晚")
            if let ans = profile?.stopBangAnswers, ans.count == 8 {
                let sb = SleepAnalyzer.stopBang(ans)
                out.append("STOP-BANG 自评 \(sb.score)/8（\(sb.risk)，筛查工具，非诊断）")
            }
            out.append("当前状态：\(p.apneaStatus.label)；治疗：\(p.apneaTreatment.label)")
            out.append("")
        }
        if categories.contains(.vitals) {
            let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point)
            let bp = BPAnalyzer.summary(vitals, profile: p)
            if bp.count > 0 {
                out.append("【血压（近 30 天，\(bp.count) 次）】平均 \(bp.avgSys.map { Int($0) } ?? 0)/\(bp.avgDia.map { Int($0) } ?? 0) mmHg · \(bp.category)")
            }
            let g = GlucoseAnalyzer.metrics(vitals.filter { $0.kind == .glucose }.map { ($0.time, $0.value) },
                                            low: p.glucoseLow, high: p.glucoseHigh)
            if g.readings > 0 {
                let tir = g.tir.map { "\(Int($0 * 100))%" } ?? "—"
                out.append("【血糖（近 14 天，\(g.readings) 个读数）】平均 \(g.mean.map { $0.oneDecimal } ?? "—") mmol/L · 目标范围内 \(tir)\(g.isContinuous ? " · CGM 覆盖 \(Int(g.coverage * 100))%" : "")")
            }
            let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
            if !labs.isEmpty {
                out.append("【化验结果（最近一次）】")
                for l in LabAnalyzer.latest(labs) {
                    out.append("\(l.date.formatted(.dateTime.year().month().day())) \(l.kind.label) \(l.valueText) \(l.kind.unit)\(l.estimated ? "（由肌酐估算）" : "")：\(LabAnalyzer.status(l.kind, l.value, profile: p).text)")
                }
                if let t = LabAnalyzer.egfrTrend(labs) { out.append("eGFR 变化：\(t.text)") }
            }
            if let k = KidneyDiet.digest(a.days, profile: p) { out.append("【\(k.replacingOccurrences(of: "：", with: "】", options: [], range: k.range(of: "：")))") }
            out.append("")
        }
        if categories.contains(.events) {
            let events = ((try? ctx.fetch(FetchDescriptor<HealthEvent>(sortBy: [SortDescriptor(\.relatedDate, order: .reverse)]))) ?? []).prefix(10)
            if !events.isEmpty {
                out.append("【近期需关注事件】")
                for e in events {
                    out.append("· \(e.relatedDate.formatted(date: .numeric, time: .omitted)) \(e.title)（\(e.status.label)）\(e.valueText.isEmpty ? "" : " \(e.valueText)")")
                    for l in e.followUpLog { out.append("    - \(l)") }
                }
                out.append("")
            }
        }
        out.append("想与医生讨论的问题：")
        out.append("1. ")
        out.append("2. ")
        let url = fileURL("summary").appendingPathExtension("txt")
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
