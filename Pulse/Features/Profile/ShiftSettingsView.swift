import SwiftUI
import SwiftData

/// 作息与倒班: a rotating roster (白班 / 夜班 / 休息) and the shift times. With a roster, Pulse divides
/// days at the main sleep instead of the calendar date, plans training around night shifts, and
/// times the morning assessment, bedtime reminders and the agent's answers to each day.
struct ShiftSettingsView: View {
    @Bindable var profile: UserProfile
    @Environment(\.modelContext) private var ctx
    @State private var changed = false

    var body: some View {
        Form {
            Section {
                Toggle("倒班 / 轮班作息", isOn: Binding(get: { profile.shiftWork }, set: { on in
                    profile.shiftWork = on
                    if on && profile.shiftPattern.isEmpty { apply(ShiftSchedule.presets[0].pattern, todayIndex: 0) }
                    changed = true
                }))
            } footer: {
                Text(AgentNameSettings.shared.phrase("开启后，Pulse 按你的睡眠划分一天：夜班后白天补觉醒来，才算新的一天开始。晨起评估、睡前提醒、运动计划和", "都会按班次安排。"))
            }

            if profile.shiftWork {
                Section {
                    patternEditor
                    Menu {
                        ForEach(ShiftSchedule.presets, id: \.name) { preset in
                            Button(preset.name) { apply(preset.pattern, todayIndex: 0) }
                        }
                    } label: {
                        Label("使用常见排班", systemImage: "list.bullet").frame(minHeight: Theme.Size.tap)
                    }
                    Picker("今天是", selection: Binding(get: { todayIndex }, set: { apply(profile.shiftPattern, todayIndex: $0) })) {
                        ForEach(Array(profile.shiftPattern.enumerated()), id: \.offset) { i, k in
                            Text("第 \(i + 1) 天 · \(k.label)").tag(i)
                        }
                    }
                } header: { Text("轮班周期") } footer: {
                    Text("轻点某一天切换白班、夜班、休息。周期会一直重复；临时调班时，改「今天是」即可。")
                }

                Section("班次时间") {
                    timeRow("白班上班", \.dayShiftStart)
                    timeRow("白班下班", \.dayShiftEnd)
                    timeRow("夜班上班", \.nightShiftStart)
                    timeRow("夜班下班", \.nightShiftEnd)
                }

                Section {
                    ForEach(0..<14, id: \.self) { i in previewRow(Date.app.startOfDay.adding(days: i)) }
                } header: { Text("接下来两周") } footer: {
                    Text("起床和入睡时间按班次和你的睡眠需要（\((profile.sleepNeedHours).oneDecimal) 小时）推算：夜班后先回家补觉，连续夜班时睡满一整段，最后一个夜班后只睡约 4 小时，晚上按时上床把作息调回来。")
                }

                Section("夜班作息建议") {
                    BulletText(text: "第一个夜班前，下午小睡约 90 分钟。")
                    BulletText(text: "夜班后半段不再喝咖啡；下班路上戴墨镜，到家后尽快在全遮光、安静的房间睡觉。")
                    BulletText(text: "白天补觉的时段尽量固定，告诉家人这是你的「夜里」。")
                    BulletText(text: "不在夜班当天和夜班后的恢复日安排训练；训练放在白班下班后或休息日。")
                }
            }
        }
        .navigationTitle("作息与倒班").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // The rest of this week follows the new roster.
            if changed { DataHub.regenerateWeekPlan(in: ctx) }
        }
    }

    private var todayIndex: Int {
        guard let s = profile.shiftSchedule, !s.pattern.isEmpty else { return 0 }
        let n = Date.app.startOfDay.daysSince(s.cycleStart.startOfDay)
        return ((n % s.pattern.count) + s.pattern.count) % s.pattern.count
    }

    /// Sets the pattern so that today is day `todayIndex + 1` of it.
    private func apply(_ pattern: [ShiftKind], todayIndex: Int) {
        profile.shiftPattern = pattern
        profile.shiftCycleStart = Date.app.startOfDay.adding(days: -min(todayIndex, max(0, pattern.count - 1)))
        changed = true
    }

    private var patternEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.item) {
                    ForEach(Array(profile.shiftPattern.enumerated()), id: \.offset) { i, k in
                        Button {
                            var p = profile.shiftPattern
                            p[i] = ShiftKind.allCases[(ShiftKind.allCases.firstIndex(of: k)! + 1) % ShiftKind.allCases.count]
                            apply(p, todayIndex: todayIndex)
                        } label: {
                            VStack(spacing: Theme.Space.hairline) {
                                Text("\(i + 1)").font(.caption).foregroundStyle(i == todayIndex ? Color.white : .secondary)
                                Text(k.short).font(.headline)
                            }
                            .foregroundStyle(i == todayIndex ? Color.white : Color.primary)
                            .frame(width: Theme.Size.tap, height: 52)
                            .background(i == todayIndex ? Theme.accent : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(i + 1) 天，\(k.label)\(i == todayIndex ? "，今天" : "")")
                        .accessibilityHint("轻点切换班次")
                    }
                }
            }
            // The cells sit flush with the row; the page margin is for page-level scroll content only.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            HStack {
                // The 44 pt frame is on each label, so the whole height is tappable.
                Button { apply(profile.shiftPattern + [.off], todayIndex: todayIndex) } label: {
                    Label("加一天", systemImage: "plus").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .disabled(profile.shiftPattern.count >= 14)
                Spacer()
                Button(role: .destructive) { apply(Array(profile.shiftPattern.dropLast()), todayIndex: min(todayIndex, profile.shiftPattern.count - 2)) } label: {
                    Label("减一天", systemImage: "minus").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .disabled(profile.shiftPattern.count <= 2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, Theme.Space.tight)
    }

    private func timeRow(_ title: String, _ key: ReferenceWritableKeyPath<UserProfile, Int>) -> some View {
        DatePicker(title, selection: Binding(get: { Date.app.startOfDay.adding(minutes: profile[keyPath: key]) },
                                             set: { profile[keyPath: key] = $0.minutesOfDay; changed = true }),
                   displayedComponents: .hourAndMinute)
    }

    private func previewRow(_ day: Date) -> some View {
        var snap = ProfileSnapshot()
        snap.wakeMinutes = profile.wakeMinutes
        snap.bedtimeMinutes = profile.bedtimeMinutes
        snap.sleepNeedMinutes = profile.sleepNeedHours * 60
        snap.shift = profile.shiftSchedule
        let w = DayClock.window(for: day, profile: snap)
        let k = w.kind ?? .off
        let bedDay = w.bed.startOfDay == day ? "" : "次日 "
        return HStack(spacing: Theme.Space.block) {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(day.formatted(.dateTime.month().day())).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(Weekday.name(day.weekday)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 52, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                Image(systemName: k.icon).imageScale(.small).foregroundStyle(k == .night ? Color.indigo : (k == .day ? Color.orange : Color.secondary))
                Text(k.label)
            }
            .font(.subheadline)
            .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text("\(Clock.text(w.wake.minutesOfDay)) 起床 · \(bedDay)\(Clock.text(w.bed.minutesOfDay)) 入睡").font(.subheadline).monospacedDigit()
                if let nap = w.nap {
                    Text("上班前 \(Clock.text(nap.start.minutesOfDay)) 小睡 90 分钟").font(.footnote).foregroundStyle(.secondary)
                } else if w.afterNightShift {
                    Text(k == .night ? "夜班后白天补觉" : "夜班后补觉，晚上按时睡").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
