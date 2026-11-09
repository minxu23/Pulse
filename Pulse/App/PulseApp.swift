import SwiftUI
import SwiftData

@main
struct PulseApp: App {
    /// Your own records and the sample users, in separate stores (see DataStores).
    @State private var stores = DataStores.shared

    init() {
        // Pulse is written in Simplified Chinese only. On a device that lists Traditional Chinese
        // before Simplified, computed strings and text fields were set the Traditional way (centred
        // ，。 and other glyph forms) while strings from the app bundle stayed Simplified, so pages
        // looked like two fonts. Takes effect before the first text is drawn.
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    }

    var body: some Scene {
        WindowGroup {
            // Switching between your own data and a sample user rebuilds the screens on the other store.
            VStack(spacing: 0) {
                if stores.mode == .sample {
                    HStack {
                        Text("测试模式 · 示例数据").font(Theme.TypeScale.body.weight(.semibold))
                        Spacer()
                        Button("退出测试") { stores.exitTesting() }
                    }
                    .padding(.horizontal, Theme.Space.gutter).padding(.vertical, Theme.Space.item)
                    .background(Theme.card)
                }
                RootView()
            }
                .id(stores.mode)
                .modelContainer(stores.container)
                .tint(Theme.accent)
                .font(Theme.TypeScale.body)
                .pageMargins()
        }
        .backgroundTask(.appRefresh(BackgroundCheck.id)) { await BackgroundCheck.runOwn() }
    }
}

enum AppTab: Hashable {
    case today, heart, plan, review, me
}

struct RootView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]
    @State private var tab: AppTab = .today
    @State private var booted = false
    @State private var prepared = false
    #if DEBUG
    @State private var debugPage: DebugPage?
    #endif

    var body: some View {
        Group {
            if !prepared {
                ProgressView("正在读取档案")
            } else if let p = profiles.first, p.onboardingDone {
                TabView(selection: $tab) {
                    Tab("今日", systemImage: "sun.max", value: AppTab.today) { TodayView(tab: $tab) }
                    Tab("趋势", systemImage: "heart.text.square", value: AppTab.heart) { HeartView() }
                    Tab("计划", systemImage: "calendar", value: AppTab.plan) { PlanView() }
                    Tab("复盘", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.review) { ReviewView() }
                    Tab("我的", systemImage: "person.crop.circle", value: AppTab.me) { ProfileView() }
                }
            } else {
                OnboardingView()
            }
        }
        .task {
            guard !booted else { return }
            booted = true
            let args = ProcessInfo.processInfo.arguments
            let demoLaunch = args.contains("-PulseDemo") && DataStores.shared.mode == .sample
            // 演示时间 belongs to the demo: a real start, a fresh demo or a test run uses the real clock;
            // -PulseTime HH:mm (or yyyy-MM-dd HH:mm) starts the demo at that moment.
            let demoTime = args.firstIndex(of: "-PulseTime").flatMap { i in i + 1 < args.count ? DemoTimeView.parse(args[i + 1]) : nil }
            if !demoLaunch || args.contains("-PulseReset") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                DemoClock.set(nil)
            }
            if demoLaunch, let t = demoTime { DemoClock.set(t) }
            // A demo reopened on a later day would have no night for today (身体准备度 empty): it is
            // generated again for the same sample user, so the sample always reaches today.
            let stale = DemoDataGenerator.isStale(in: ctx)
            if demoLaunch && (DataHub.profile(in: ctx) == nil || args.contains("-PulseReset") || stale || demoTime != nil) {
                let persona = args.firstIndex(of: "-PulsePersona").flatMap { i in i + 1 < args.count ? DemoPersona(rawValue: args[i + 1]) : nil }
                    ?? DataHub.profile(in: ctx).flatMap { DemoPersona(rawValue: $0.demoPersona) }
                DemoDataGenerator.populate(ctx, persona: persona ?? .xiaolin)
                AgentConversation.shared.clear()
            }
            #if DEBUG
            // -PulseNoVO2: no cardio-fitness estimates, as for someone who hasn't walked outdoors with the watch yet.
            if args.contains("-PulseNoVO2") {
                for r in (try? ctx.fetch(FetchDescriptor<DailyRecord>())) ?? [] { r.vo2Max = nil }
                try? ctx.save()
            }
            // Screenshot helper: put the sample user N weeks into a pack (-PulseProgram cardio|fitness|metabolic|event|auto,
            // -PulseProgramWeek N), with the baseline taken from the two weeks before the round began.
            // -PulseProgram baseline [-PulseBaselineDay N]: the sample user in 基线期, N days in (the report is
            // ready at once when N is left out, since sample users have months of history).
            if DebugLaunch.value("-PulseProgram") == "baseline", let p = DataHub.profile(in: ctx), p.usesDemoData {
                ProgramFlow.startBaseline(p, in: ctx)
                if let n = DebugLaunch.value("-PulseBaselineDay").flatMap(Int.init) {
                    p.programBaselineStart = DayClock.logicalToday(.app).adding(days: -n)
                }
                try? ctx.save()
            } else if let v = DebugLaunch.value("-PulseProgram"), let p = DataHub.profile(in: ctx), p.usesDemoData {
                p.programQuestionsDone = true
                p.parqAnswers = Array(repeating: false, count: ParQ.allCases.count)
                // -PulseNoBPMonitor: without a home monitor, blood pressure comes from clinic readings.
                if CommandLine.arguments.contains("-PulseNoBPMonitor") { p.hasBPMonitor = false }
                let n = max(1, Int(DebugLaunch.value("-PulseProgramWeek") ?? "1") ?? 1)
                let monday = DayClock.logicalToday(.app).weekStart.adding(days: -7 * (n - 1))
                let window = DateInterval(start: monday.adding(days: -14), end: monday)
                let result = DataHub.baseline(in: ctx, window: window, now: monday)
                // A sample user's danger signs count as seen by a doctor, so the screenshot shows the pack.
                ProgramFlow.confirmDoctor(p, result.report)
                ProgramFlow.choose(ProgramPack(rawValue: v) ?? result.recommendation.recommended.pack, result: result, profile: p, in: ctx, now: monday)
                DataHub.regenerateWeekPlan(in: ctx)
                try? ctx.save()
            }
            // Screenshot helper: make today a training day in the demo plan.
            if args.contains("-PulseTrainingToday"), let p = DataHub.profile(in: ctx), !p.availableWeekdays.contains(Date.app.weekday) {
                p.availableWeekdays.append(Date.app.weekday)
                DataHub.regenerateWeekPlan(in: ctx)
                try? ctx.save()
            }
            #endif
            if let i = args.firstIndex(of: "-PulseTab"), i + 1 < args.count {
                tab = ["heart": .heart, "plan": .plan, "review": .review, "me": .me][args[i + 1]] ?? .today
            }
            prepared = true
            refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
            // Whatever changed while the app was open (a task ticked off, a date moved) is what rings.
            if phase == .background {
                CareReminders.sync(in: ctx)
                BackgroundCheck.schedule()
            }
        }
        #if DEBUG
        .fullScreenCover(item: $debugPage) { page in
            if page == .agent {
                HealthAgentChatView(initialQuestion: DebugLaunch.value("-PulseAsk"))
            } else {
                NavigationStack {
                    page.view.toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { debugPage = nil } } }
                }
                .pageMargins()
            }
        }
        .task {
            if let v = DebugLaunch.value("-PulseOpen"), let page = DebugPage(rawValue: v) {
                try? await Task.sleep(for: .seconds(1))
                debugPage = page
            }
        }
        #endif
    }

    private func refresh() {
        guard let p = profiles.first, p.onboardingDone else { return }
        DataHub.ensureWeekPlan(in: ctx)
        DataHub.refreshAlerts(in: ctx)
        try? ctx.save()
        CareReminders.sync(in: ctx)
        if p.useHealthKit {
            Task { await HealthKitService.shared.sync(into: ctx, days: 14) }
        }
        // New readings (blood pressure first) show on 今日 as soon as Apple Health has them.
        HealthKitService.shared.observeUpdates(into: p.useHealthKit && !p.usesDemoData ? ctx : nil)
    }
}

#if DEBUG
/// Pages that `-PulseOpen <name>` presents directly, for screenshots.
enum DebugPage: String, Identifiable {
    case glucose, cardio, marathon, agent, nutrition, evening, review, readiness, cloud, nextweek, labs, events, baseline, packs
    case program, summary, questions
    var id: String { rawValue }
    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .glucose: DiabetesCareView()
        case .cardio: CardioCareView()
        case .marathon: MarathonView()
        case .agent: HealthAgentChatView()
        case .nutrition: TodayPhaseView(phase: .nutrition, tab: .constant(.today))
        case .evening: TodayPhaseView(phase: .evening, tab: .constant(.today))
        case .review: TodayPhaseView(phase: .review, tab: .constant(.today))
        case .readiness: TodayDataReader { d in ReadinessDetailView(result: d.readiness, analytics: d.analytics) }
        case .cloud: CloudModelSettingsView()
        case .nextweek: WeeklyPlanView(startOnNextWeek: true).navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline)
        case .labs: LabResultsView()
        case .events: HealthEventsView()
        case .baseline: ProgramReportScreen()
        case .packs: DebugPackPicker()
        case .program: ProgramDetailScreen()
        case .summary: ProgramSummaryScreen()
        case .questions: DebugQuestions()
        }
    }
}

/// `-PulseOpen questions`: 基础信息 for the current profile.
private struct DebugQuestions: View {
    @Query private var profiles: [UserProfile]
    var body: some View {
        if let p = profiles.first { BaselineQuestionsView(profile: p).calmStyle() }
    }
}
#endif

/// Launch-argument helpers for screenshots and UI checks (no effect in normal use).
enum DebugLaunch {
    static func value(_ key: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: key), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }
}
