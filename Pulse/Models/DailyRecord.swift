import Foundation
import SwiftData

/// One calendar day. Morning values (resting HR, HRV, the night's sleep, check-in) belong to the
/// day the user woke up; behaviours (alcohol, caffeine, meals, training) belong to the day they happened.
@Model
final class DailyRecord {
    @Attribute(.unique) var day: Date = Date()

    // Morning physiology
    var restingHR: Double? = nil
    var rhrSourceRaw: String? = nil
    var hrv: Double? = nil
    var respiratoryRate: Double? = nil
    var spo2Avg: Double? = nil
    var spo2Min: Double? = nil
    var breathingDisturbances: Double? = nil
    var vo2Max: Double? = nil

    // The night ending this morning
    var sleepStart: Date? = nil
    var sleepEnd: Date? = nil
    var sleepMinutes: Double? = nil
    var deepMinutes: Double? = nil
    var remMinutes: Double? = nil
    var awakeMinutes: Double? = nil

    // Daytime activity
    var steps: Int? = nil
    var activeKcal: Double? = nil
    var exerciseMinutes: Double? = nil

    // Morning check-in (how the user feels)
    var checkInAt: Date? = nil
    var energy: Int? = nil        // 1–5
    var sleepFeel: Int? = nil     // 1–5
    var soreness: Int? = nil      // 0–3
    var sorenessAreaRaw: String? = nil
    var stress: Int? = nil        // 1–5
    var illnessSymptoms: Bool = false

    // Behaviours & context
    var tagsRaw: [String] = []
    var alcoholUnits: Double = 0
    var caffeineCups: Int = 0
    var lastCaffeineHour: Int? = nil
    var waterMl: Int = 0
    var lateMeal: Bool = false
    var dietQuality: Int? = nil   // 1 不理想 · 2 一般 · 3 均衡
    var medsTaken: Bool? = nil

    // Kidney diet (肾脏饮食): what was eaten, see `DietFoods`
    var nutrientsLogged: Bool = false
    var saltG: Double? = nil
    var saltSources: [String] = []
    var proteinServings: Double? = nil
    /// Portions eaten, one entry each (「鸡蛋」「鸡蛋」「米饭」); replaces `proteinServings`.
    var proteinFoods: [String] = []
    var potassiumFoods: [String] = []
    var phosphorusFoods: [String] = []
    // Swelling and urine (水肿与尿量), see `KidneySigns`
    var edema: Int? = nil
    var edemaPlaces: [String] = []
    var urineOutput: Int? = nil
    var urineMl: Int? = nil
    var foamyUrine: Bool? = nil

    // Sleep-breathing cues for the night ending this morning
    var snoring: Bool = false
    var gasping: Bool = false
    var witnessedApnea: Bool = false
    var morningHeadache: Bool = false
    var daytimeSleepy: Bool = false
    var cpapHours: Double? = nil

    // Bedtime record (睡前记录)
    var eveningCheckInAt: Date? = nil
    var eveningFatigue: Int? = nil   // 1–5, 5 = 非常疲劳
    var eveningSoreness: Int? = nil  // 0–3
    var eveningStress: Int? = nil    // 1–5
    var plannedBedtime: Date? = nil
    var plannedWake: Date? = nil
    var sleepPlanNote: String = ""

    // Day review
    var dayNote: String = ""
    var bedtimeDone: [String] = []
    var reviewedAt: Date? = nil
    var availableMinutesToday: Int? = nil

    /// Fields edited by hand; device sync never overwrites them (需求 10).
    var manualFields: [String] = []

    init(day: Date) {
        self.day = Calendar.current.startOfDay(for: day)
    }
}

extension DailyRecord {
    var tags: Set<ContextTag> {
        get { Set(tagsRaw.compactMap(ContextTag.init(rawValue:))) }
        set { tagsRaw = newValue.map(\.rawValue).sorted() }
    }
    var rhrSource: RHRSource? {
        get { rhrSourceRaw.flatMap(RHRSource.init(rawValue:)) }
        set { rhrSourceRaw = newValue?.rawValue }
    }
    var sorenessArea: SorenessArea {
        get { sorenessAreaRaw.flatMap(SorenessArea.init(rawValue:)) ?? .none }
        set { sorenessAreaRaw = newValue.rawValue }
    }
    var hasCheckIn: Bool { checkInAt != nil }
    var hasEveningCheckIn: Bool { eveningCheckInAt != nil }

    func toggle(_ tag: ContextTag, on: Bool) {
        var t = tags
        if on { t.insert(tag) } else { t.remove(tag) }
        tags = t
    }
    func markManual(_ field: String) {
        if !manualFields.contains(field) { manualFields.append(field) }
    }
    func isManual(_ field: String) -> Bool { manualFields.contains(field) }
}

@Model
final class MedicationEntry {
    var id: UUID = UUID()
    var name: String = ""
    var categoryRaw: String = MedicationCategory.other.rawValue
    var dose: String = ""
    var startDate: Date = Date()
    var endDate: Date? = nil
    var note: String = ""

    init(name: String, category: MedicationCategory, dose: String = "", startDate: Date = .app) {
        self.name = name
        self.categoryRaw = category.rawValue
        self.dose = dose
        self.startDate = startDate
    }

    var category: MedicationCategory {
        get { MedicationCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
    var isActive: Bool { endDate.map { $0 > .app } ?? true }
}

@Model
final class MealLog {
    var id: UUID = UUID()
    var time: Date = Date()
    var kindRaw: String = MealKind.lunch.rawValue
    var carbsG: Double? = nil
    var fluidMl: Double? = nil
    var balanced: Bool = true
    var note: String = ""

    init(time: Date = .app, kind: MealKind) {
        self.time = time
        self.kindRaw = kind.rawValue
    }
    var kind: MealKind { MealKind(rawValue: kindRaw) ?? .snack }
}
