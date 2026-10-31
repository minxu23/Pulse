import SwiftUI
import SwiftData
import Charts

// Native rendering of the Health Agent's Generative UI components. Charts are drawn from the
// user's own records; forms send the answers back into the conversation; a plan proposal is only
// written to the plan when the user adopts it, and can be undone.

struct AgentBlocksView: View {
    let blocks: [AgentUIBlock]
    let messageID: UUID
    let context: AgentContext
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            ForEach(blocks) { b in
                Group {
                    switch b {
                    case .form(let f): AgentFormView(form: f, key: "\(messageID.uuidString)|\(f.id)", onSubmit: onSubmit)
                    case .chart(let m, let d, let cap): AgentChartBlock(metric: m, days: d, caption: cap, context: context)
                    case .checklist(let c): AgentChecklistView(list: c)
                    case .steps(let s): AgentStepsView(steps: s)
                    case .plan(let p): PlanProposalCard(proposal: p)
                    case .condition(let c): ConditionCard(proposal: c)
                    case .record(let r): RecordCard(proposal: r)
                    }
                }
                .cardSurface()
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }
}

/// Small header that marks a component as generated for this conversation.
private struct BlockHeader: View {
    let title: String
    let icon: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon).font(.headline)
            Spacer(minLength: Theme.Space.item)
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

// MARK: - Form

struct AgentFormView: View {
    let form: AgentForm
    let key: String
    var onSubmit: (String) -> Void
    @State private var convo = AgentConversation.shared
    @State private var choices: [String: [String]] = [:]
    @State private var days: [String: Set<Int>] = [:]
    @State private var numbers: [String: Int] = [:]
    @State private var toggles: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: form.title, icon: "hand.tap")
            if let sent = convo.answeredForms[key] {
                StatusLabel(.good("已发送：\(sent)")).font(.subheadline)
            } else {
                ForEach(form.fields) { field($0) }
                if !form.submitsOnTap {
                    Button(action: submit) {
                        Text(form.submitLabel).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || convo.isResponding)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ f: AgentFormField) -> some View {
        switch f.kind {
        case .choice(let options, let multiple):
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                if !form.submitsOnTap { Text(f.label).font(.subheadline).foregroundStyle(.secondary) }
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(options, id: \.self) { o in
                        let on = choices[f.id, default: []].contains(o)
                        Button {
                            if form.submitsOnTap { choices[f.id] = [o]; submit(); return }
                            var cur = choices[f.id, default: []]
                            if multiple { if on { cur.removeAll { $0 == o } } else { cur.append(o) } } else { cur = [o] }
                            choices[f.id] = cur
                        } label: {
                            HStack(spacing: Theme.Space.iconGap) {
                                if on { Image(systemName: "checkmark").fontWeight(.semibold).imageScale(.small) }
                                Text(o)
                            }
                            .font(.subheadline)
                            .frame(minHeight: Theme.Size.borderedLabel)
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? Theme.accent : nil)
                        .disabled(convo.isResponding)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        case .weekdays:
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text(f.label).font(.subheadline).foregroundStyle(.secondary)
                // Tight, so seven day circles stay close to the 44 pt tap width on a phone.
                HStack(spacing: Theme.Space.tight) {
                    ForEach(Weekday.mondayFirst, id: \.self) { wd in
                        let on = days[f.id, default: []].contains(wd)
                        Button {
                            var cur = days[f.id, default: []]
                            if on { cur.remove(wd) } else { cur.insert(wd) }
                            days[f.id] = cur
                        } label: {
                            Text(Weekday.name(wd)).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
                                .background(on ? Theme.accent : Theme.subtle, in: Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Weekday.name(wd))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        case .number(let lo, let hi, let step, let unit, let initial):
            let v = numbers[f.id] ?? initial
            Stepper(value: Binding(get: { numbers[f.id] ?? initial }, set: { numbers[f.id] = $0 }), in: lo...hi, step: step) {
                HStack {
                    Text(f.label).font(.subheadline)
                    Spacer()
                    Text("\(v) \(unit)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: Theme.Size.tap)
        case .toggle:
            Toggle(f.label, isOn: Binding(get: { toggles[f.id] ?? false }, set: { toggles[f.id] = $0 })).font(.subheadline)
        }
    }

    private var answers: [String: String] {
        var out: [String: String] = [:]
        for f in form.fields {
            switch f.kind {
            case .choice: out[f.id] = choices[f.id, default: []].joined(separator: "、")
            case .weekdays: out[f.id] = Weekday.mondayFirst.filter { days[f.id, default: []].contains($0) }.map(Weekday.name).joined(separator: "、")
            case .number(_, _, _, let unit, let initial): out[f.id] = "\(numbers[f.id] ?? initial) \(unit)".trimmingCharacters(in: .whitespaces)
            case .toggle: out[f.id] = (toggles[f.id] ?? false) ? "是" : "否"
            }
        }
        return out
    }

    private var canSubmit: Bool {
        form.fields.allSatisfy { f in
            switch f.kind {
            case .choice: !choices[f.id, default: []].isEmpty
            case .weekdays: !days[f.id, default: []].isEmpty
            default: true
            }
        }
    }

    private func submit() {
        guard canSubmit, !convo.isResponding else { return }
        let a = answers
        convo.answeredForms[key] = form.fields.compactMap { a[$0.id] }.filter { !$0.isEmpty }.joined(separator: "，")
        onSubmit(form.message(a))
    }
}

// MARK: - Plan proposal

struct PlanProposalCard: View {
    let proposal: PlanChangeProposal
    @Environment(\.modelContext) private var ctx
    @State private var convo = AgentConversation.shared

    var body: some View {
        let p = proposal
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: "\(p.scope.label)计划调整", icon: "calendar.badge.clock", trailing: p.source)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                ForEach(p.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.block) {
                        Text(Weekday.name(line.weekday)).font(.subheadline.weight(.semibold)).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(line.before).font(.footnote).foregroundStyle(.secondary).strikethrough()
                            Text(line.after).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Weekday.name(line.weekday))：原来\(line.before)，改为\(line.after)")
                }
            }
            ForEach(p.notes, id: \.self) { n in
                Text(n).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Label("Pulse 本机安全检查", systemImage: "checkmark.shield").font(.subheadline.weight(.semibold))
                ForEach(p.checks, id: \.self) { c in
                    Text("• " + c).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        let p = proposal
        switch convo.planOutcomes[p.id] {
        case nil:
            HStack(spacing: Theme.Space.item) {
                Button {
                    let undo = DataHub.applyPlanChange(p, in: ctx)
                    convo.planOutcomes[p.id] = .applied(undo)
                } label: { Text("采纳").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.borderedProminent)
                Button { convo.planOutcomes[p.id] = .dismissed } label: { Text("不用了").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                    .buttonStyle(.bordered)
            }
        case .applied(let undo):
            StatusLabel(.good("已更新到「计划 › \(p.scope.label)」")).font(.subheadline)
            HStack(spacing: Theme.Space.item) {
                NavigationLink {
                    WeeklyPlanView(startOnNextWeek: p.scope == .nextWeek)
                        .navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline).calmStyle()
                } label: { Label("查看计划", systemImage: "calendar").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.bordered)
                Button {
                    DataHub.revertPlanChange(p, undo: undo, in: ctx)
                    convo.planOutcomes[p.id] = .undone
                } label: { Label("撤销", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.bordered)
            }
        case .dismissed:
            StatusLabel(.neutral("没有采纳，计划保持不变")).font(.subheadline)
        case .undone:
            StatusLabel(.neutral("已撤销，计划恢复原样")).font(.subheadline)
        }
    }
}

// MARK: - Condition

/// A condition the user mentioned: what Pulse will change for it, recorded only on 记下.
struct ConditionCard: View {
    let proposal: ConditionProposal
    @Environment(\.modelContext) private var ctx
    @State private var convo = AgentConversation.shared

    var body: some View {
        let x = proposal.info
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: "记下健康情况", icon: "cross.case", trailing: x.native != nil ? "Pulse 内置" : (x.known ? "Pulse 资料库" : "资料库未收录"))
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(x.name).font(.subheadline.weight(.semibold))
                if !x.summary.isEmpty {
                    Text(x.summary).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("记下后 Pulse 会").font(.subheadline.weight(.semibold))
                ForEach(x.changes, id: \.self) { line in
                    Text("• " + line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !x.stopSigns.isEmpty {
                Label(x.stopSigns, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(ConditionLibrary.sourceNote).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        let c = proposal
        switch convo.conditionOutcomes[c.id] {
        case nil:
            HStack(spacing: Theme.Space.item) {
                Button {
                    convo.conditionOutcomes[c.id] = .recorded(added: DataHub.recordCondition(c.info, in: ctx))
                } label: { Text("记下").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.borderedProminent)
                Button { convo.conditionOutcomes[c.id] = .dismissed } label: { Text("不用了").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                    .buttonStyle(.bordered)
            }
        case .recorded(let added):
            StatusLabel(.good(added ? "已记在「我的 › 健康状况与用药」" : "之前已经记过")).font(.subheadline)
            if added {
                Button {
                    DataHub.forgetCondition(c.info, in: ctx)
                    convo.conditionOutcomes[c.id] = .undone
                } label: { Label("撤销", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.bordered)
            }
        case .dismissed:
            StatusLabel(.neutral("没有记下")).font(.subheadline)
        case .undone:
            StatusLabel(.neutral("已撤销，没有记下")).font(.subheadline)
        }
    }
}

// MARK: - Record

/// What the user asked to record — a reading, water, a symptom or a reminder — written only on 记下,
/// and undone on 撤销. A reminder's date and time can be changed first.
struct RecordCard: View {
    let proposal: RecordProposal
    @Environment(\.modelContext) private var ctx
    @State private var convo = AgentConversation.shared
    @State private var due: Date
    @AppStorage(CareReminders.enabledKey) private var careReminders = false

    init(proposal: RecordProposal) {
        self.proposal = proposal
        _due = State(initialValue: proposal.reminder?.due ?? proposal.time)
    }

    var body: some View {
        let reminder = proposal.reminder
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: reminder == nil ? "记下来" : "加一条提醒", icon: reminder == nil ? "square.and.pencil" : "bell",
                        trailing: reminder == nil ? proposal.time.formatted(.dateTime.month().day().hour().minute()) : nil)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                ForEach(Array(proposal.items.enumerated()), id: \.offset) { _, item in
                    Label(RecordProposal.label(item), systemImage: RecordProposal.icon(item))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let rep = proposal.repeats {
                Label("重复：\(rep.label)", systemImage: "repeat").font(.subheadline)
            }
            if let r = reminder, convo.recordOutcomes[proposal.id] == nil {
                // A repeating reminder's days follow its rule: only the time can change.
                if proposal.repeats == nil || r.timed {
                    DatePicker("时间", selection: $due, in: Date.app.startOfDay...,
                               displayedComponents: proposal.repeats != nil ? [.hourAndMinute] : (r.timed ? [.date, .hourAndMinute] : [.date]))
                        .font(.subheadline)
                }
                if !r.timed { Text(proposal.repeats == nil ? "当天上午 9 点提醒" : "每次上午 9 点提醒").font(.footnote).foregroundStyle(.secondary) }
            }
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch convo.recordOutcomes[proposal.id] {
        case nil:
            HStack(spacing: Theme.Space.item) {
                Button {
                    convo.recordOutcomes[proposal.id] = .recorded(DataHub.applyRecord(proposal, reminderDue: due, in: ctx))
                } label: { Text("记下").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.borderedProminent)
                Button { convo.recordOutcomes[proposal.id] = .dismissed } label: { Text("不用了").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                    .buttonStyle(.bordered)
            }
        case .recorded(let undo):
            StatusLabel(.good(proposal.reminder == nil ? "已记下" : "已加到「照护与随访事项」")).font(.subheadline)
            if proposal.reminder != nil, !careReminders {
                Button {
                    Task {
                        careReminders = await CareReminders.requestPermission()
                        CareReminders.sync(in: ctx)
                    }
                } label: { Label("打开到期提醒，到时手机通知我", systemImage: "bell.badge").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
                .buttonStyle(.bordered)
            }
            Button {
                DataHub.undoRecord(undo, in: ctx)
                convo.recordOutcomes[proposal.id] = .undone
            } label: { Label("撤销", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel) }
            .buttonStyle(.bordered)
        case .dismissed:
            StatusLabel(.neutral("没有记下")).font(.subheadline)
        case .undone:
            StatusLabel(.neutral("已撤销，没有记下")).font(.subheadline)
        }
    }
}

// MARK: - Chart

struct AgentChartBlock: View {
    let metric: AgentChartMetric
    let days: Int
    let caption: String?
    let context: AgentContext

    var body: some View {
        let c = context
        let start = c.now.startOfDay.adding(days: -(days - 1))
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: metric.title, icon: icon, trailing: metric == .glucose ? "近 \(days * 24) 小时" : "近 \(days) 天")
            switch metric {
            case .rhr:
                let pts = c.trend.points.filter { $0.day >= start }
                if pts.count < 3 { EmptyLine("静息心率数据还不够。") } else {
                    Chart {
                        if let b = c.trend.baseline {
                            RuleMark(y: .value("基线", b)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                        }
                        ForEach(pts) { p in
                            LineMark(x: .value("日期", p.day), y: .value("bpm", p.value)).foregroundStyle(Theme.heartData).interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                    .accessibilityLabel("静息心率，近 \(days) 天，\(c.trend.avg7.map { "近 7 天平均 \($0.noDecimal)" } ?? "")")
                }
            case .sleep:
                let ds = c.days.filter { $0.day >= start && $0.sleepMinutes != nil }
                if ds.isEmpty { EmptyLine("还没有睡眠数据。") } else {
                    Chart {
                        RuleMark(y: .value("目标", c.profile.sleepNeedMinutes / 60)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                        ForEach(ds) { d in BarMark(x: .value("日期", d.day, unit: .day), y: .value("小时", (d.sleepMinutes ?? 0) / 60)).foregroundStyle(Theme.sleep) }
                    }
                    .frame(height: 140)
                    .accessibilityLabel("睡眠时长，\(ds.count) 晚有记录")
                }
            case .activity:
                let ds = c.days.filter { $0.day >= start }
                Chart { ForEach(ds) { d in BarMark(x: .value("日期", d.day, unit: .day), y: .value("分钟", d.activeMinutes)).foregroundStyle(Theme.activity) } }
                    .frame(height: 140)
                    .accessibilityLabel("每日活动分钟，近 \(days) 天")
            case .glucose:
                let pts = c.vitals.filter { $0.kind == .glucose && $0.time > c.now.addingTimeInterval(-Double(days) * 86400) }
                if pts.isEmpty { EmptyLine("这段时间没有血糖数据。") } else {
                    Chart {
                        GlucoseRangeMarks(low: c.profile.glucoseLow, high: c.profile.glucoseHigh)
                        ForEach(Array(pts.enumerated()), id: \.offset) { _, v in
                            LineMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                                .foregroundStyle(Theme.glucose).interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                        ForEach(Array(c.workouts.filter { $0.start > c.now.addingTimeInterval(-Double(days) * 86400) }.enumerated()), id: \.offset) { _, w in
                            RuleMark(x: .value("训练", w.start)).foregroundStyle(Theme.activity.opacity(0.6))
                                .annotation(position: .top, spacing: Theme.Space.hairline) { Image(systemName: "figure.run").font(.caption).foregroundStyle(Theme.activity) }
                        }
                    }
                    .frame(height: 150)
                    .padding(.top, Theme.Space.block)
                    .accessibilityLabel("CGM 血糖曲线，虚线为目标范围 \(c.profile.glucoseLow.oneDecimal) 到 \(c.profile.glucoseHigh.oneDecimal)")
                    Text("虚线为目标范围，\(Image(systemName: "figure.run")) 为训练开始。").font(.footnote).foregroundStyle(.secondary)
                }
            case .bp:
                let pts = c.vitals.filter { $0.kind == .bloodPressure && $0.time >= start }
                if pts.isEmpty { EmptyLine("这段时间没有血压记录。") } else {
                    Chart {
                        ForEach(Array(pts.enumerated()), id: \.offset) { _, v in
                            PointMark(x: .value("日期", v.time), y: .value("收缩压", v.value)).foregroundStyle(by: .value("类型", "收缩压")).symbol(by: .value("类型", "收缩压"))
                            if let d = v.value2 {
                                PointMark(x: .value("日期", v.time), y: .value("舒张压", d)).foregroundStyle(by: .value("类型", "舒张压")).symbol(by: .value("类型", "舒张压"))
                            }
                        }
                    }
                    .chartForegroundStyleScale(["收缩压": Theme.heartData, "舒张压": Theme.heartData.opacity(0.45)])
                    .frame(height: 140)
                }
            case .wear:
                let all = (0..<days).map { start.adding(days: $0) }
                let byDay = Dictionary(c.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
                let recorded = all.filter { byDay[$0]?.rhr != nil || byDay[$0]?.sleepMinutes != nil }.count
                Chart {
                    ForEach(all, id: \.self) { d in
                        let has = byDay[d]?.rhr != nil || byDay[d]?.sleepMinutes != nil
                        BarMark(x: .value("日期", d, unit: .day), y: .value("记录", 1))
                            .foregroundStyle(by: .value("状态", has ? "有夜间数据" : "缺失"))
                    }
                }
                .chartForegroundStyleScale(["有夜间数据": Theme.heartData, "缺失": Color.gray.opacity(0.3)])
                .chartYAxis(.hidden)
                .frame(height: 70)
                .accessibilityLabel("佩戴记录：近 \(days) 天中 \(recorded) 天有夜间数据")
                Text("\(recorded)/\(days) 天有夜间心率或睡眠数据。").font(.footnote).foregroundStyle(.secondary)
            }
            if let caption { Text(caption).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var icon: String {
        switch metric {
        case .rhr: "heart.fill"
        case .sleep: "bed.double.fill"
        case .activity: "figure.walk"
        case .glucose: "drop.fill"
        case .bp: "heart.text.square.fill"
        case .wear: "applewatch"
        }
    }
}

// MARK: - Checklist and steps

struct AgentChecklistView: View {
    let list: AgentChecklist
    @State private var done: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: list.title, icon: "checklist", trailing: "\(done.count)/\(list.items.count) 已完成")
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                ForEach(list.items) { item in
                    ChecklistRow(done: done.contains(item.id), title: item.title, detail: item.detail) {
                        if done.contains(item.id) { done.remove(item.id) } else { done.insert(item.id) }
                        UserDefaults.standard.set(Array(done), forKey: storeKey)
                    }
                }
            }
        }
        .onAppear { done = Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? []) }
    }

    private var storeKey: String { "agent.checklist.\(list.id)" }
}

struct AgentStepsView: View {
    let steps: AgentSteps
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            BlockHeader(title: steps.title, icon: "list.number")
            ForEach(steps.steps) { s in
                HStack(alignment: .top, spacing: Theme.Space.block) {
                    Image(systemName: s.icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(s.title).font(.subheadline.weight(.semibold))
                        Text(s.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Entry points

/// Opens the Health Agent with a prepared question, from any page.
struct AgentAskButton: View {
    let title: String
    let question: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(title, systemImage: "sparkles").font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Theme.Size.borderedLabel)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .accessibilityHint(AgentNameSettings.shared.phrase("向", "提问：\(question)"))
        .sheet(isPresented: $open) { HealthAgentChatView(initialQuestion: question) }
    }
}
