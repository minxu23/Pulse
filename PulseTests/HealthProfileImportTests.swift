import Foundation
import Testing
@testable import Pulse

@Suite("Apple 健康档案填充")
@MainActor
struct HealthProfileImportTests {
    @Test func partialImportPreservesOtherEntries() {
        let p = UserProfile()
        p.birthYear = 1980
        p.sex = .female
        p.heightCm = 165
        p.nickname = "已有称呼"
        p.conditions = [.hypertension]
        p.goalNote = "保留目标"
        HealthProfileImport(weightKg: 62.5).apply(to: p)
        #expect(p.weightKg == 62.5)
        #expect(p.birthYear == 1980 && p.sex == .female && p.heightCm == 165)
        #expect(p.nickname == "已有称呼" && p.conditions == [.hypertension] && p.goalNote == "保留目标")
        #expect(!p.useHealthKit)
    }

    @Test func invalidOrUnavailableValuesDoNotReplaceEntries() {
        let values = HealthProfileImport(birthYear: 9999, sex: .unspecified, heightCm: .nan, heightDate: .app,
                                         weightKg: -1, weightDate: .app)
        #expect(values.isEmpty)
        #expect(values.heightDate == nil && values.weightDate == nil)
        let p = UserProfile()
        p.weightKg = 72
        values.apply(to: p)
        #expect(p.weightKg == 72)
        #expect(HealthProfileImport(heightCm: .infinity, weightKg: 999).isEmpty)
    }

    @Test func validImportRequiresExplicitApplyAndDoesNotChangeSampleUsers() {
        let p = UserProfile()
        let originalWeight = p.weightKg
        let values = HealthProfileImport(birthYear: 1975, sex: .male, heightCm: 181.5, weightKg: 82.3)
        #expect(p.weightKg == originalWeight)
        values.apply(to: p)
        #expect(p.birthYear == 1975 && p.sex == .male && p.heightCm == 181.5 && p.weightKg == 82.3)
        p.usesDemoData = true
        HealthProfileImport(weightKg: 65).apply(to: p)
        #expect(p.weightKg == 82.3)
    }
}
