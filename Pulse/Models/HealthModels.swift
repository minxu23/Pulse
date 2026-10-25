import Foundation
import SwiftData

/// A spot measurement with its context (需求 8): what was measured, when, in which situation,
/// and whether medication had been taken.
@Model
final class VitalReading {
    var id: UUID = UUID()
    var time: Date = Date()
    var kindRaw: String = VitalKind.bloodPressure.rawValue
    var value: Double = 0
    var value2: Double? = nil       // diastolic for blood pressure
    var pulse: Double? = nil
    var contextRaw: String = MeasureContext.random.rawValue
    var sourceRaw: String = DataSource.manual.rawValue
    var medsTaken: Bool? = nil
    var note: String = ""
    var externalID: String? = nil

    init(time: Date = .app, kind: VitalKind, value: Double, value2: Double? = nil,
         context: MeasureContext = .random, source: DataSource = .manual) {
        self.time = time
        self.kindRaw = kind.rawValue
        self.value = value
        self.value2 = value2
        self.contextRaw = context.rawValue
        self.sourceRaw = source.rawValue
    }

    var kind: VitalKind { VitalKind(rawValue: kindRaw) ?? .bloodPressure }
    var context: MeasureContext {
        get { MeasureContext(rawValue: contextRaw) ?? .random }
        set { contextRaw = newValue.rawValue }
    }
    var source: DataSource { DataSource(rawValue: sourceRaw) ?? .manual }

    var valueText: String {
        switch kind {
        case .bloodPressure: "\(Int(value))/\(Int(value2 ?? 0))"
        case .glucose, .lactate, .temperature: String(format: "%.1f", value)
        case .weight: String(format: "%.1f", value)
        case .spo2, .heartRate: "\(Int(value))"
        }
    }
}

/// An abnormal finding or reported symptom that needs separate attention and follow-up (需求 8).
@Model
final class HealthEvent {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var relatedDate: Date = Date()
    var kindRaw: String = EventKind.other.rawValue
    var severityRaw: String = Severity.info.rawValue
    var statusRaw: String = EventStatus.open.rawValue
    var title: String = ""
    var detail: String = ""
    var guidance: String = ""
    var valueText: String = ""
    var dedupeKey: String = ""
    var followUpDue: Date? = nil
    var followUpLog: [String] = []
    var resolvedAt: Date? = nil

    init(kind: EventKind, severity: Severity, title: String, detail: String, guidance: String,
         relatedDate: Date, valueText: String = "", dedupeKey: String) {
        self.kindRaw = kind.rawValue
        self.severityRaw = severity.rawValue
        self.title = title
        self.detail = detail
        self.guidance = guidance
        self.relatedDate = relatedDate
        self.valueText = valueText
        self.dedupeKey = dedupeKey
    }

    var kind: EventKind { EventKind(rawValue: kindRaw) ?? .other }
    var severity: Severity { Severity(rawValue: severityRaw) ?? .info }
    var status: EventStatus {
        get { EventStatus(rawValue: statusRaw) ?? .open }
        set {
            statusRaw = newValue.rawValue
            resolvedAt = newValue.isActive ? nil : .app
        }
    }
    func log(_ text: String) {
        let stamp = Date.app.formatted(.dateTime.month().day().hour().minute())
        followUpLog.append("\(stamp) · \(text)")
    }
}

/// A care or follow-up task: appointments, tests, equipment, check-ins.
@Model
final class CareTask {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var due: Date? = nil
    var areaRaw: String = CareArea.general.rawValue
    var done: Bool = false
    var doneAt: Date? = nil
    var createdAt: Date = Date()

    init(title: String, area: CareArea, due: Date? = nil, note: String = "") {
        self.title = title
        self.areaRaw = area.rawValue
        self.due = due
        self.note = note
    }
    var area: CareArea { CareArea(rawValue: areaRaw) ?? .general }
}

/// A saved weekly / phase review with the user's reflection and next-step strategy (需求 9).
@Model
final class ReviewEntry {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var periodStart: Date = Date()
    var periodEnd: Date = Date()
    var kind: String = "weekly"
    var summary: String = ""
    var keep: String = ""
    var change: String = ""
    var nextFocus: String = ""
    var rhrAverage: Double? = nil
    var planCompletion: Double? = nil

    init(periodStart: Date, periodEnd: Date, kind: String = "weekly") {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.kind = kind
    }
}

/// User-confirmed status for an observed association (observed → testing → confirmed).
@Model
final class InsightRecord {
    @Attribute(.unique) var key: String = ""
    var statusRaw: String = InsightStatus.observed.rawValue
    var note: String = ""
    var experimentStart: Date? = nil
    var experimentEnd: Date? = nil
    var updatedAt: Date = Date()

    init(key: String, status: InsightStatus) {
        self.key = key
        self.statusRaw = status.rawValue
    }
    var status: InsightStatus {
        get { InsightStatus(rawValue: statusRaw) ?? .observed }
        set { statusRaw = newValue.rawValue; updatedAt = .app }
    }
}

/// One value from a lab report (化验单).
@Model
final class LabResult {
    var id: UUID = UUID()
    var date: Date = Date()
    var kindRaw: String = LabKind.egfr.rawValue
    var value: Double = 0
    /// eGFR worked out from creatinine rather than printed on the report.
    var estimated: Bool = false
    var note: String = ""

    init(date: Date, kind: LabKind, value: Double, estimated: Bool = false) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.value = value
        self.estimated = estimated
    }
    var kind: LabKind { LabKind(rawValue: kindRaw) ?? .egfr }
    var point: LabPoint { LabPoint(date: date, kind: kind, value: value, estimated: estimated) }
}

enum PulseSchema {
    static let models: [any PersistentModel.Type] = [
        UserProfile.self, DailyRecord.self, MedicationEntry.self, MealLog.self,
        ActivitySession.self, PlanItem.self, VitalReading.self, HealthEvent.self,
        CareTask.self, ReviewEntry.self, InsightRecord.self, LabResult.self,
    ]
}
