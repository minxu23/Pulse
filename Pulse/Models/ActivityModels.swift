import Foundation
import SwiftData

/// A completed workout, imported from a device or logged by hand.
@Model
final class ActivitySession {
    var id: UUID = UUID()
    var start: Date = Date()
    var typeRaw: String = WorkoutType.walk.rawValue
    var minutes: Double = 30
    var rpe: Int? = nil
    var avgHR: Double? = nil
    var maxHR: Double? = nil
    var distanceKm: Double? = nil
    var sourceRaw: String = DataSource.manual.rawValue
    var externalID: String? = nil
    var planItemID: UUID? = nil
    var carbsG: Double? = nil
    var fluidMl: Double? = nil
    var feelingRaw: String? = nil
    var note: String = ""

    init(start: Date, type: WorkoutType, minutes: Double, source: DataSource = .manual) {
        self.start = start
        self.typeRaw = type.rawValue
        self.minutes = minutes
        self.sourceRaw = source.rawValue
    }

    var type: WorkoutType { WorkoutType(rawValue: typeRaw) ?? .other }
    var source: DataSource { DataSource(rawValue: sourceRaw) ?? .manual }
    var feeling: WorkoutFeeling? {
        get { feelingRaw.flatMap(WorkoutFeeling.init(rawValue:)) }
        set { feelingRaw = newValue?.rawValue }
    }
    var day: Date { Calendar.current.startOfDay(for: start) }
    /// Session-RPE load (minutes × perceived exertion).
    var load: Double { minutes * Double(rpe ?? type.defaultRPE) }
    var isHard: Bool { (rpe ?? type.defaultRPE) >= 7 }
}

/// One planned session (or activity/rest day) in the weekly plan.
@Model
final class PlanItem {
    var id: UUID = UUID()
    var day: Date = Date()
    var weekStart: Date = Date()
    var kindRaw: String = PlanKind.aerobic.rawValue
    var title: String = ""
    var detail: String = ""
    var guidance: String = ""
    var minutes: Int = 30
    var minimumMinutes: Int = 10
    var minimumDetail: String = ""
    var intensityRaw: String = Intensity.easy.rawValue
    var isKey: Bool = false
    var statusRaw: String = PlanStatus.planned.rawValue
    var completedMinutes: Int? = nil

    // Adjustment trail (需求 5)
    var originalTitle: String? = nil
    var originalMinutes: Int? = nil
    var originalIntensityRaw: String? = nil
    var originalKindRaw: String? = nil
    var adjustmentNote: String? = nil
    var adjustedAt: Date? = nil

    init(day: Date, weekStart: Date, kind: PlanKind, title: String, minutes: Int, intensity: Intensity) {
        self.day = Calendar.current.startOfDay(for: day)
        self.weekStart = weekStart
        self.kindRaw = kind.rawValue
        self.title = title
        self.minutes = minutes
        self.intensityRaw = intensity.rawValue
    }

    var kind: PlanKind {
        get { PlanKind(rawValue: kindRaw) ?? .aerobic }
        set { kindRaw = newValue.rawValue }
    }
    var intensity: Intensity {
        get { Intensity(rawValue: intensityRaw) ?? .easy }
        set { intensityRaw = newValue.rawValue }
    }
    var status: PlanStatus {
        get { PlanStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }
    var wasAdjusted: Bool { adjustedAt != nil }
    var originalIntensity: Intensity? { originalIntensityRaw.flatMap(Intensity.init(rawValue:)) }
}
