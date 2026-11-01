import SwiftUI
import SwiftData
import Charts

/// 心血管健康：与医生的照护计划保持一致——今天的血压、用药与症状在前，
/// 然后是 7 天家庭血压监测、心率与运动处方、用药、事件和随访。
struct CardioCareView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @State private var log: QuickLogKind?
    @State private var addTask = false
    @State private var editPlan = false
    @State private var exported: URL?

    var body: some View {
        if let p = profiles.first {
            let a = Analytics(profile: p, medications: meds, records: records, sessions: [])
            let snap = a.profile
            let points = vitals.map(\.point)
            ScreenScroll {
                EmergencyStrip()
                todayCard(snap, points)
                AbnormalRecallCard(kind: .bloodPressure)
                if let n = NextHourForecaster.bloodPressure(points) {
                    Label { Text("未来 1 小时：" + n.message).fixedSize(horizontal: false, vertical: true) }
                        icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                        .font(.subheadline)
                        .cardSurface()
                }
                SectionTitle(title: "家庭血压监测", subtitle: "近 7 天")
                HomeBPCard(status: BPAnalyzer.homeMonitoring(points, profile: snap), readings: points, profile: snap)
                SectionTitle(title: "心率与运动")
                MetricGrid {
                    rhrCard(a)
                    capCard(snap)
                    adherenceCard(a)
                    weightOrTargetCard(points, snap)
                }
                exerciseCard(snap)
                medsCard(snap)
                eventsCard
                followUpCard
                PageFootnote("Pulse 帮助你记录并整理数据，用药与治疗调整请遵医嘱。")
            }
            .navigationTitle("心血管健康").calmStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("照护计划") { editPlan = true } } }
            .sheet(item: $log) { QuickLogSheet(kind: $0) }
            .sheet(isPresented: $addTask) { AddCareTaskSheet(defaultTitle: "心内科复诊", area: .cardio) }
            .sheet(isPresented: $editPlan) { CardioPlanSheet(profile: p) }
        }
    }

    // MARK: Today

    private func todayCard(_ p: ProfileSnapshot, _ points: [VitalPoint]) -> some View {
        let today = Date.app.startOfDay
        let bp = points.filter { $0.kind == .bloodPressure && $0.time >= today }
        let morning = bp.contains { (4..<12).contains($0.time.hour) }
        let evening = bp.contains { $0.time.hour >= 17 }
        let symptoms = events.filter { $0.kind == .symptom && $0.relatedDate >= today }
        let record = records.last { $0.day == today }
        let bpStatus: MetricStatus = {
            guard let last = bp.last else { return .neutral("今天还没有测量血压") }
            let text = "\(Int(last.value))/\(Int(last.value2 ?? 0)) mmHg · \(Clock.text(last.time.minutesOfDay))"
            return last.value > Double(p.bpTargetSys) || (last.value2 ?? 0) > Double(p.bpTargetDia) ? .attention(text + " · 高于目标") : .good(text + " · 在目标内")
        }()
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("今天")
            StatusLabel(bpStatus).font(.subheadline)
            StatusLabel(text: "晨起 \(morning ? "已测" : "未测") · 睡前 \(evening ? "已测" : "未测")", icon: morning && evening ? "checkmark.circle.fill" : "clock",
                        color: morning && evening ? .green : .gray, secondaryText: true).font(.subheadline)
            StatusLabel(symptoms.isEmpty ? .good("今天没有记录不适症状") : .attention("记录了 \(symptoms.count) 项症状：\(symptoms.first!.title)"))
                .font(.subheadline)
            if let r = record, !meds.filter(\.isActive).isEmpty {
                Picker("今天是否按时服药", selection: Binding(get: { r.medsTaken }, set: { r.medsTaken = $0 })) {
                    Text("服药未记录").tag(Bool?.none)
                    Text("已按时服药").tag(Bool?.some(true))
                    Text("有漏服").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
            }
            AdaptiveStack(spacing: Theme.Space.item) {
                Button { log = .bloodPressure } label: { Label("测量血压", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { log = .symptom } label: { Label("记录症状", systemImage: "person.fill.questionmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .cardSurface()
    }

    // MARK: Heart rate & exercise

    private func rhrCard(_ a: Analytics) -> some View {
        let t = a.trend
        let status: MetricStatus = {
            if case .rise(let d) = t.sustained { return .attention("持续高于平时 \(d.oneDecimal)") }
            if a.profile.onRateLoweringMeds() { return .neutral("受降心率药物影响") }
            return t.avg7 == nil ? .neutral("暂无数据") : .good("在平时范围内")
        }()
        return HealthMetricCard(title: "静息心率", icon: "heart.fill", color: Theme.heartData, time: "7 日均值",
                                value: t.avg7.map { $0.noDecimal } ?? "—", unit: "bpm", status: status)
    }

    private func capCard(_ p: ProfileSnapshot) -> some View {
        HealthMetricCard(title: "运动心率上限", icon: "heart.circle", color: Theme.heartData,
                         value: p.hrCap.map(String.init) ?? "未设定", unit: p.hrCap == nil ? "" : "bpm",
                         status: p.clinicianCleared ? .good("医生已确认强度范围") : .attention("确认前只安排低–中等强度"),
                         valueFont: p.hrCap == nil ? .title3.weight(.semibold) : .system(.title, design: .rounded).weight(.semibold))
    }

    private func adherenceCard(_ a: Analytics) -> some View {
        let r = CardioAnalyzer.medicationAdherence(a.days)
        return HealthMetricCard(title: "按时服药", icon: "pills.fill", color: .secondary, time: "近 14 天",
                                value: r.rate.map { "\(Int($0 * 100))" } ?? "—", unit: r.rate == nil ? "" : "%",
                                status: r.rate == nil ? .neutral(meds.contains(where: \.isActive) ? "在「今天」中记录" : "未记录用药")
                                    : (r.missed == 0 ? .good("\(r.recorded) 天均按时") : .attention("漏服 \(r.missed) 天")))
    }

    @ViewBuilder
    private func weightOrTargetCard(_ points: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        let weights = points.filter { $0.kind == .weight }
        if p.watchesWeight || !weights.isEmpty {
            let gain = CardioAnalyzer.rapidWeightGain(weights)
            HealthMetricCard(title: "体重", icon: "scalemass.fill", color: Theme.body,
                             time: weights.last.map { $0.time.formatted(.dateTime.month().day()) },
                             value: weights.last.map { $0.value.oneDecimal } ?? "—", unit: "kg",
                             status: gain.map { .attention("3 天内增加 \($0.oneDecimal) kg，请联系医生") } ?? .neutral("每天晨起同一条件下称重")) {
                if weights.isEmpty {
                    Button { log = .vital } label: { Label("记录", systemImage: "plus") }.buttonStyle(.bordered)
                }
            }
        } else {
            let s = BPAnalyzer.summary(points, profile: p)
            HealthMetricCard(title: "血压达标", icon: "target", color: Theme.heartData, time: "近 30 天",
                             value: s.inTargetRate.map { "\(Int($0 * 100))" } ?? "—", unit: s.inTargetRate == nil ? "" : "%",
                             status: .neutral("目标 \(p.bpTargetSys)/\(p.bpTargetDia) · \(s.count) 次"))
        }
    }

    private func exerciseCard(_ p: ProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("运动处方")
            ForEach(CardioAnalyzer.exerciseGuidance(profile: p), id: \.self) { line in
                let stop = line.contains("立即停止")
                IconTextRow(icon: stop ? "exclamationmark.triangle.fill" : (line.contains("药物") ? "pills" : (line.contains("热身") ? "timer" : "figure.walk")),
                            color: stop ? .red : .secondary, title: "", text: line)
            }
            if !p.clinicianCleared || p.hrCap == nil {
                Button { editPlan = true } label: { Label("记录医生确认的强度范围", systemImage: "stethoscope") }
                    .buttonStyle(.bordered)
            }
        }
        .cardSurface()
    }

    private func medsCard(_ p: ProfileSnapshot) -> some View {
        let active = meds.filter(\.isActive)
        return VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle("用药")
            if active.isEmpty { EmptyLine("未记录用药。") }
            ForEach(active) { m in
                HStack(spacing: Theme.Space.block) {
                    IconTile(icon: "pills.fill")
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(m.name).font(.body)
                        Text([m.dose, m.category.label, m.category.hrEffect.label].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Size.tap)
                .accessibilityElement(children: .combine)
            }
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            NavigationLink { Form { MedicationsSection() }.navigationTitle("用药").calmStyle() } label: {
                NavRowLabel(icon: "list.bullet", title: "管理用药", detail: "用药调整请遵医嘱，Pulse 仅记录背景")
            }
            .buttonStyle(.plain)
        }
        .cardSurface()
    }

    private var eventsCard: some View {
        let kinds: [EventKind] = [.bpCrisis, .bpHigh, .bpLow, .irregularRhythm, .rhrHigh, .rhrLow, .rhrSustainedRise, .symptom, .deviceHRAlert]
        let related = Array(events.filter { kinds.contains($0.kind) }.prefix(5))
        return VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle("相关事件")
            if related.isEmpty { EmptyLine("近期没有相关事件。") }
            ForEach(related) { e in
                NavigationLink { HealthEventDetailView(event: e) } label: {
                    HStack { EventRow(event: e); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                        .frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .cardSurface()
    }

    private var followUpCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle(title: "随访") {
                Button { addTask = true } label: { Label("添加", systemImage: "plus") }.buttonStyle(.bordered)
            }
            let list = tasks.filter { $0.area == .cardio }
            if list.isEmpty { EmptyLine("暂无随访事项。") }
            ForEach(list) { CareTaskRow(task: $0).frame(minHeight: Theme.Size.tap) }
            Divider()
            Button {
                exported = try? DataExporter.clinicianSummary(ctx, categories: [.profile, .heart, .vitals, .medications, .events])
            } label: { Label("生成复诊摘要", systemImage: "doc.text") }
                .buttonStyle(.bordered)
            if let url = exported {
                ShareLink(item: url) {
                    Label("分享 / 保存摘要", systemImage: "square.and.arrow.up")
                        .frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .cardSurface()
    }
}

/// Compact emergency reminder with a direct call action.
struct EmergencyStrip: View {
    var text = "胸痛或胸闷不缓解、晕厥、严重气短、一侧肢体无力或言语不清时"
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        // At accessibility sizes the call button goes under the text instead of squeezing it.
        let layout = size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.item)) : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Space.iconGap))
        layout {
            HStack(alignment: .center, spacing: Theme.Space.iconGap) {
                Image(systemName: "cross.case.fill").font(.subheadline).imageScale(.small).foregroundStyle(.red).accessibilityHidden(true)
                Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if !size.isAccessibilitySize { Spacer(minLength: Theme.Space.tight) }
            Link(destination: URL(string: "tel://120")!) {
                Text("拨打 120").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Space.block).frame(minHeight: Theme.Size.tap)
                    .background(Color.red.opacity(0.12), in: Capsule())
            }
            .foregroundStyle(.red)
        }
        .cardSurface()
    }
}

// MARK: - Home blood pressure

struct HomeBPCard: View {
    let status: HomeBPStatus
    let readings: [VitalPoint]
    let profile: ProfileSnapshot

    var body: some View {
        let recent = readings.filter { $0.kind == .bloodPressure && $0.time > Date.app.adding(days: -14) }
        let morning = recent.filter { (4..<12).contains($0.time.hour) }
        let evening = recent.filter { $0.time.hour >= 17 }
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            AdaptiveRow(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    Text(status.overallAvg.map { "\(Int($0.sys))/\(Int($0.dia))" } ?? "—")
                        .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit().fixedSize()
                    Text("mmHg 平均").font(.subheadline).foregroundStyle(.secondary)
                }
            } trailing: {
                Text("\(Int(status.progress * 14))/14 次").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressBar(value: status.progress, color: .gray, height: 6).accessibilityLabel("监测进度")
            StatusLabel(status.aboveHomeThreshold || (status.aboveTarget && status.progress >= 0.7) ? .attention(status.message)
                        : (status.progress < 0.7 ? .neutral(status.message) : .good(status.message)))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                fact("晨起平均", status.morningAvg, status.morningCount)
                fact("睡前平均", status.eveningAvg, status.eveningCount)
            }
            if recent.count >= 3 {
                Chart {
                    RuleMark(y: .value("目标", profile.bpTargetSys))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                        .annotation(position: .top, alignment: .leading) { Text("目标 \(profile.bpTargetSys)").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array(morning.enumerated()), id: \.offset) { _, v in
                        LineMark(x: .value("日期", v.time, unit: .day), y: .value("收缩压", v.value), series: .value("时段", "晨起"))
                            .foregroundStyle(Theme.heartData).symbol(.circle)
                    }
                    ForEach(Array(evening.enumerated()), id: \.offset) { _, v in
                        LineMark(x: .value("日期", v.time, unit: .day), y: .value("收缩压", v.value), series: .value("时段", "睡前"))
                            .foregroundStyle(Theme.heartData.opacity(0.45)).symbol(.diamond)
                    }
                }
                .chartYScale(domain: ((recent.map(\.value).min() ?? 110) - 8)...((recent.map(\.value).max() ?? 140) + 8))
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day(), collisionResolution: .greedy) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 140)
                .accessibilityLabel("近 14 天晨起与睡前收缩压")
                Text("近 14 天收缩压 · ● 晨起 · ◆ 睡前").font(.footnote).foregroundStyle(.secondary)
            }
            Text("每次测量前静坐 5 分钟，连测 2 遍取平均；晨起在服药和早餐前。").font(.footnote).foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    private func fact(_ label: String, _ v: (sys: Double, dia: Double)?, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("\(label) · \(n) 次").font(.caption).foregroundStyle(.secondary)
            Text(v.map { "\(Int($0.sys))/\(Int($0.dia))" } ?? "—").font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Care plan

struct CardioPlanSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Bindable var profile: UserProfile

    var body: some View {
        CalmNavigationStack {
            Form {
                Section {
                    Toggle("医生已确认我的运动强度范围", isOn: $profile.clinicianCleared)
                    Toggle("设定运动心率上限", isOn: Binding(get: { profile.exerciseHRCap != nil }, set: { profile.exerciseHRCap = $0 ? 130 : nil }))
                    if let cap = profile.exerciseHRCap {
                        Stepper("心率上限 \(cap) bpm", value: Binding(get: { cap }, set: { profile.exerciseHRCap = $0 }), in: 90...190)
                    }
                } header: { Text("运动") } footer: {
                    Text(profile.clinicianCleared ? "运动计划按你记录的范围安排。" : "在医生确认前，计划只安排低–中等强度活动。")
                }
                Section("血压目标") {
                    Stepper("收缩压 ≤ \(profile.bpTargetSys)", value: $profile.bpTargetSys, in: 110...150, step: 5)
                    Stepper("舒张压 ≤ \(profile.bpTargetDia)", value: $profile.bpTargetDia, in: 60...100, step: 5)
                }
                Section("医生的其他要求") {
                    TextField("如：避免憋气用力、需要报告的症状", text: $profile.careNotes, axis: .vertical)
                }
            }
            .navigationTitle("照护计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        DataHub.regenerateWeekPlan(in: ctx)
                        try? ctx.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
