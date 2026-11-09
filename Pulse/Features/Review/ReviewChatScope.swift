import Foundation

/// Dates are carried as context, not silently submitted as a question to a cloud model.
struct ReviewChatScope: Equatable {
    let weekStart: Date
    var referenceDate: Date { min(Date.app, weekStart.adding(days: 7).addingTimeInterval(-1)) }
    var label: String {
        weekStart.formatted(.dateTime.month().day()) + "—" + weekStart.adding(days: 6).formatted(.dateTime.month().day()) + " · 复盘"
    }
}
