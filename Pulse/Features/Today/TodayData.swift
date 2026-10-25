import SwiftUI
import SwiftData

/// Everything the home page and its phase pages show for today, computed once per render.
struct TodayData {
    let now: Date
    /// The day the page shows: until its boundary still the previous date (see DayClock).
    let day: Date
    /// That day from waking to its main sleep (follows the roster when there is one).
    let window: DayWindow
    let profile: UserProfile?
    let analytics: Analytics
    let readiness: ReadinessResult
    let guidance: ReadinessGuidance
    let record: DailyRecord?
    let todayItems: [PlanItem]
    let weekItems: [PlanItem]
    let tomorrow: [SessionSnapshot]
    let activeEvents: [HealthEvent]
    let recentVitals: [VitalPoint]
    let todayVitals: [VitalPoint]
    let todaySessions: [ActivitySession]
    let todayMeals: [MealLog]
    let openTasks: [CareTask]
    let vitality: VitalityResult
    let phase: DayPhase
    /// Today's forecast, when there is one.
    var weather: DayWeather? = nil
    /// Today's weather for today's outdoor training.
    var weatherReminder: WeatherReminder? { WeatherPlanner.reminder(today: weather, sessions: trainings.map(\.snapshot), profile: p) }

    var p: ProfileSnapshot { analytics.profile }

    /// A race-type goal without the specialist module switched on.
    var suggestsMarathon: Bool {
        guard let p = profile, !p.hasModule(.marathon) else { return false }
        let text = p.goalNote + p.raceName
        return p.goals.contains(.event) || ["马拉松", "全马", "半马", "越野", "铁人"].contains { text.contains($0) }
    }
    var trainings: [PlanItem] { todayItems.filter { $0.kind.isTraining } }

    var summary: DaySummary {
        RecoveryAdvisor.daySummary(today: analytics.today, readiness: readiness,
                                   trainingsDone: trainings.filter { $0.status == .done || $0.status == .partial }.count,
                                   trainingsPlanned: trainings.count, vitality: vitality, readings: todayVitals,
                                   openEvents: activeEvents.count, tomorrow: tomorrow, profile: p)
    }
}

struct TodayDataReader<Content: View>: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \PlanItem.day) private var planItems: [PlanItem]
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]
    @Query(sort: \CareTask.due) private var tasks: [CareTask]
    /// Re-renders when the user starts the day early (or undoes it).
    @AppStorage(DayClock.earlyStartKey) private var earlyStart: Double = 0
    @ViewBuilder var content: (TodayData) -> Content

    var body: some View {
        let _ = earlyStart
        content(make())
            .task(id: Date.app.startOfDay) { await WeatherStore.shared.load(demo: profiles.first?.usesDemoData == true) }
    }

    private func make() -> TodayData {
        let now = Date.app
        let snap = profiles.first?.snapshot(medications: meds)
        DayClock.current = snap
        let today = DayClock.logicalToday(now, snap)
        let window = DayClock.window(for: today, profile: snap)
        // Before the boundary the analysis looks at the day that is ending, not the date that has just begun.
        let a = Analytics(profile: profiles.first, medications: meds, records: records, sessions: sessions,
                          now: DayClock.isBeforeWake(now, snap) ? today.adding(minutes: 24 * 60 - 1) : now)
        let readiness = a.readiness()
        let todayItems = planItems.filter { $0.day == today }
        let recent = vitals.filter { $0.time > today.adding(days: -15) }.map(\.point)
        let planned = todayItems.filter { $0.kind.isTraining || $0.kind == .walk }.map(\.minutes).reduce(0, +)
        return TodayData(
            now: now, day: today, window: window, profile: profiles.first, analytics: a, readiness: readiness,
            guidance: ReadinessEngine.guidance(readiness, profile: a.profile),
            record: records.first { $0.day == today },
            todayItems: todayItems,
            weekItems: planItems.filter { $0.weekStart == today.weekStart },
            tomorrow: planItems.filter { $0.day == today.adding(days: 1) }.map(\.snapshot),
            activeEvents: events.filter { $0.status.isActive }.sorted { $0.severity > $1.severity },
            recentVitals: recent,
            todayVitals: recent.filter { $0.time >= today },
            todaySessions: sessions.filter { $0.day == today },
            todayMeals: meals.filter { $0.time >= today },
            openTasks: tasks.filter { !$0.done },
            vitality: VitalityEngine.evaluate(today: a.today, plannedMinutes: planned, stepsTarget: a.profile.stepsTarget, readiness: readiness),
            phase: DayPhase.current(at: now, window: window),
            weather: WeatherStore.shared.days.first { $0.day == today })
    }
}

/// Presents the check-in, adjustment and logging sheets used across the home page.
struct TodaySheetHost: ViewModifier {
    @Binding var sheet: TodaySheet?
    let data: TodayData
    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { s in
            switch s {
            case .checkIn: MorningCheckInView()
            case .earlyStart: EarlyStartSheet(data: data) {
                DayClock.startEarly()
                sheet = .checkIn
            }
            case .evening: EveningCheckInView()
            case .adjust: AdjustPlanView(items: data.todayItems, readiness: data.readiness, analytics: data.analytics,
                                         weekItems: data.weekItems, urgentOpen: data.activeEvents.contains { $0.severity == .urgent })
            case .log(let k): QuickLogSheet(kind: k)
            case .workout(let id): QuickLogSheet(kind: .workout, planItemID: id)
            }
        }
    }
}

extension View {
    func todaySheets(_ sheet: Binding<TodaySheet?>, _ data: TodayData) -> some View {
        modifier(TodaySheetHost(sheet: sheet, data: data))
    }
}
