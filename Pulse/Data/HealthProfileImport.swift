import Foundation

/// Only readable, valid values are offered; absent Health values never replace the user's entries.
struct HealthProfileImport: Identifiable {
    let id = UUID()
    var birthYear: Int?
    var sex: Sex?
    var heightCm: Double?
    var heightDate: Date?
    var weightKg: Double?
    var weightDate: Date?

    init(birthYear: Int? = nil, sex: Sex? = nil, heightCm: Double? = nil, heightDate: Date? = nil,
         weightKg: Double? = nil, weightDate: Date? = nil, now: Date = .app) {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        self.birthYear = birthYear.flatMap { (1900...year).contains($0) ? $0 : nil }
        self.sex = sex == .unspecified ? nil : sex
        self.heightCm = heightCm.flatMap { $0.isFinite && (130...220).contains($0) ? $0 : nil }
        self.weightKg = weightKg.flatMap { $0.isFinite && (30...200).contains($0) ? $0 : nil }
        self.heightDate = self.heightCm == nil ? nil : heightDate
        self.weightDate = self.weightKg == nil ? nil : weightDate
    }

    var isEmpty: Bool { birthYear == nil && sex == nil && heightCm == nil && weightKg == nil }

    @MainActor
    func apply(to profile: UserProfile) {
        guard !profile.usesDemoData else { return }
        if let birthYear { profile.birthYear = birthYear }
        if let sex { profile.sex = sex }
        if let heightCm { profile.heightCm = heightCm }
        if let weightKg { profile.weightKg = weightKg }
    }
}
