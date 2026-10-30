import SwiftUI

/// 「我已经起床了」: before 5 am the app treats the night as not over. Someone who is up for the
/// day (an early shift, an early flight) confirms once, sees how much they actually slept, and the
/// new day starts — the morning assessment, the agent and 复盘 all move to it.
struct EarlyStartSheet: View {
    let data: TodayData
    var onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let now = data.now
        let today = now.startOfDay
        let night = data.analytics.day(today)
        let need = data.p.sleepNeedMinutes
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            Label("开始 \(today.formatted(.dateTime.month().day()))？", systemImage: "sunrise.fill")
                .font(.title3.weight(.semibold)).labelStyle(.inline)
            Text("晨起评估会用昨夜到现在的数据：").font(.subheadline).foregroundStyle(.secondary)
            // Only a night that has actually ended counts (synced sleep that ends before now).
            if let n = night, let s = n.sleepStart, let e = n.sleepEnd, e <= now, let m = n.sleepMinutes {
                HStack {
                    Text("睡眠").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Clock.text(s.minutesOfDay)) → \(Clock.text(e.minutesOfDay)) · \((m / 60).oneDecimal) 小时").monospacedDigit()
                }
                .font(.subheadline)
                .padding(Theme.Space.block)
                .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                if m < need - 60 {
                    Text("比你需要的 \((need / 60).oneDecimal) 小时少约 \(((need - m) / 60).oneDecimal) 小时，准备度会把这一点算进去。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("昨夜的睡眠数据还没有同步，可以在晨起评估里补记。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onStart) {
                Text("开始今天，记录醒后感受").fontWeight(.semibold).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button { dismiss() } label: {
                Text("还没起床，继续睡").frame(maxWidth: .infinity, minHeight: Theme.Size.tap).contentShape(Rectangle())
            }
        }
        // A sheet without a scroll view: the page margins on the sides, a section's space at the top and bottom.
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.section)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Shown for five minutes after starting the day early, in case it was a mis-tap.
struct EarlyStartUndoRow: View {
    let start: Date
    var body: some View {
        HStack(spacing: Theme.Space.item) {
            Label("\(Clock.text(start.minutesOfDay)) 开始今天", systemImage: "sunrise").font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("不是起床？").font(.subheadline).foregroundStyle(.secondary)
            Button { DayClock.undoEarlyStart() } label: {
                Text("撤销").frame(minWidth: Theme.Size.tap, minHeight: Theme.Size.tap, alignment: .trailing).contentShape(Rectangle())
            }
            .font(.subheadline.weight(.semibold))
        }
        // The 44 pt button already leaves 12 pt above and below its line; 4 more matches the 16 pt sides.
        .padding(.horizontal, Theme.Space.cardPadding)
        .padding(.vertical, Theme.Space.tight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}
