import SwiftUI
import SwiftData
import Charts

// MARK: - Plan actions

enum PlanActions {
    /// Updates a plan item's status. Without a device, marking it done also records the session so
    /// training load (and tomorrow's readiness) stays accurate.
    @MainActor
    static func setStatus(_ item: PlanItem, _ status: PlanStatus, useHealthKit: Bool, in ctx: ModelContext) {
        item.status = status
        switch status {
        case .done: item.completedMinutes = item.minutes
        case .partial: item.completedMinutes = item.completedMinutes ?? item.minutes / 2
        default: item.completedMinutes = nil
        }
        if !useHealthKit, item.kind.isTraining, status == .done || status == .partial {
            let existing = try? ctx.fetch(FetchDescriptor<ActivitySession>()).first { $0.planItemID == item.id }
            if existing == nil {
                let type: WorkoutType = item.kind == .strength ? .strength : (item.kind == .mobility ? .yoga : .walk)
                let s = ActivitySession(start: .app, type: type, minutes: Double(item.completedMinutes ?? item.minutes))
                s.rpe = [1, 3, 5, 7][item.intensity.order]
                s.planItemID = item.id
                ctx.insert(s)
            }
        }
    }
}
