import SwiftUI
import SwiftData
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// The forecast the plan follows: the sample users' demo weather, or Apple WeatherKit for the device's
/// location once the app has the WeatherKit capability and location access. Nothing is sent to any
/// other weather service.
@MainActor
@Observable
final class WeatherStore {
    static let shared = WeatherStore()
    private(set) var days: [DayWeather] = []
    private(set) var sourceName = ""
    /// Why there is no forecast, when there is none.
    private(set) var unavailable: String?
    private var loadedFor: Date?

    func load(demo: Bool, now: Date = .app) async {
        guard loadedFor != now.startOfDay || days.isEmpty else { return }
        loadedFor = now.startOfDay
        if demo {
            days = DemoWeather.days(from: now); sourceName = DemoWeather().name; unavailable = nil
            return
        }
        #if canImport(WeatherKit)
        do {
            let source = WeatherKitSource()
            days = try await source.forecast(from: now)
            sourceName = source.name; unavailable = nil
        } catch {
            days = []
            unavailable = "暂时拿不到天气预报（需要定位权限，并在 App 中开启 WeatherKit）"
        }
        #else
        unavailable = "这台设备不支持天气预报"
        #endif
    }
}

#if canImport(WeatherKit)
/// Apple WeatherKit for the current location (approximate location is enough).
struct WeatherKitSource: WeatherSource {
    let name = "Apple 天气"
    func forecast(from: Date) async throws -> [DayWeather] {
        let location = try await OneShotLocation().current()
        let daily = try await WeatherService.shared.weather(for: location, including: .daily)
        return daily.forecast.filter { $0.date >= from.startOfDay }.map { d in
            let sky: DayWeather.Sky = switch d.condition {
            case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .tropicalStorm, .hurricane: .thunder
            case .heavyRain: .heavyRain
            case .rain, .drizzle, .sunShowers, .freezingRain, .freezingDrizzle: .rain
            case .snow, .heavySnow, .flurries, .sleet, .blizzard, .blowingSnow, .wintryMix, .sunFlurries: .snow
            case .clear, .mostlyClear, .hot: .clear
            default: .cloudy
            }
            return DayWeather(day: d.date.startOfDay, sky: sky, high: d.highTemperature.converted(to: .celsius).value,
                              low: d.lowTemperature.converted(to: .celsius).value, rainChance: d.precipitationChance)
        }
    }
}

/// One location fix, asking for "when in use" access the first time.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func current() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            switch m.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
            case .denied, .restricted: self.finish(.failure(CLError(.denied)))
            default: break
            }
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in if let l = locations.last { self.finish(.success(l)) } }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
    private func finish(_ r: Result<CLLocation, Error>) {
        continuation?.resume(with: r)
        continuation = nil
    }
}
#endif

/// 天气: the coming days next to this week's plan, and — when the weather gets in the way of an
/// outdoor session — a proposal to move it, take it indoors or ease it, to adopt or leave.
struct WeatherPlanCard: View {
    let context: AgentContext
    @State private var store = WeatherStore.shared
    @State private var convo = AgentConversation.shared
    @Query private var profiles: [UserProfile]
    /// Kept while the user acts on it: adopting changes the plan, and the card must still show what
    /// was adopted and offer to undo it.
    @State private var proposal: PlanChangeProposal?
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let days = Array(store.days.prefix(7))
        let advice = WeatherPlanner.advice(plan: context.plan, forecast: store.days, now: context.now, profile: context.profile)
        let signature = context.plan.filter { $0.day >= context.now.startOfDay }.map { "\($0.day.timeIntervalSince1970)\($0.title)\($0.minutes)\($0.intensity)" }.joined()
            + "|\(store.days.count)"
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("天气", detail: store.sourceName.isEmpty ? nil : store.sourceName)
            if days.isEmpty {
                Text(store.unavailable ?? "正在获取天气预报…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Seven columns; at accessibility sizes one line per day, where a seventh of the row fits one character.
                let layout = size.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: Theme.Space.tight)) : AnyLayout(HStackLayout(spacing: 0))
                layout {
                    ForEach(days) { d in
                        let training = context.plan.contains { $0.day == d.day && WeatherPlanner.isOutdoor($0) }
                        let cell = size.isAccessibilitySize
                            ? AnyLayout(HStackLayout(spacing: Theme.Space.item)) : AnyLayout(VStackLayout(spacing: Theme.Space.tight))
                        cell {
                            Text(d.day.isSameDay(context.now) ? "今天" : Weekday.name(d.day.weekday))
                                .font(.caption.weight(training ? .semibold : .regular))
                                .foregroundStyle(training ? Color.primary : Color.secondary)
                            if size.isAccessibilitySize { Spacer(minLength: Theme.Space.item) }
                            Image(systemName: d.icon).symbolRenderingMode(.multicolor).font(.title3).frame(height: 26)
                            Text("\(Int(d.high))°").font(.caption).monospacedDigit()
                            Circle().fill(advice.affected.contains(d.day.weekday) && d.day < context.now.weekStart.adding(days: 7) ? Color.orange
                                          : (training ? Theme.activity.opacity(0.6) : Color.clear))
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("小圆点：有户外训练的日子；橙色为天气可能有影响。").font(.caption).foregroundStyle(.secondary)
                if let p = proposal {
                    Divider()
                    PlanProposalCard(proposal: p)
                } else if !advice.notes.isEmpty {
                    Divider()
                    ForEach(advice.notes, id: \.self) { n in
                        // The glyph takes the sentence's size (the inline label style makes it a little smaller).
                        Label { Text(n).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "cloud.sun").foregroundStyle(.secondary) }
                            .font(.subheadline)
                    }
                } else {
                    Text("这周的户外训练日天气都合适，计划不用调整。").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .cardSurface()
        .task(id: context.now.startOfDay) { await store.load(demo: profiles.first?.usesDemoData == true, now: context.now) }
        .task(id: signature) {
            // A proposal the user has acted on stays; otherwise it follows the current plan and forecast.
            if let p = proposal, convo.planOutcomes[p.id] != nil { return }
            proposal = WeatherPlanner.proposal(context: context, forecast: store.days, source: "按天气预报")?.0
        }
    }
}
