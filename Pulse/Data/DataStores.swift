import Foundation
import SwiftData

/// Your own records and the sample users live in separate stores: trying a sample user never touches
/// your data, and 「回到我自己的数据」 brings it back as you left it.
///
/// The first launch after this was added looks at the one store there was (default.store): if it holds
/// sample data it becomes the sample store and your own store starts empty; otherwise it stays yours.
@MainActor
@Observable
final class DataStores {
    enum Mode: String { case own, sample }

    static let shared = DataStores()

    // Plain keys: read from anywhere, not only the main actor.
    nonisolated static let testKey = "data.testingEnabled"
    nonisolated static let modeKey = "data.mode"
    nonisolated static let ownKey = "data.ownStore"
    nonisolated static let sampleKey = "data.sampleStore"

    private(set) var mode: Mode
    private(set) var container: ModelContainer
    private(set) var testingEnabled: Bool
    private var ownCache: ModelContainer?
    private var sampleCache: ModelContainer?
    private let inMemory: Bool
    private let defaults: UserDefaults
    /// Which file is which, held here too: 删除所有数据 clears every preference before the other store goes.
    private let ownName: String
    private let sampleName: String

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        inMemory = arguments.contains("-PulseInMemory")
        if defaults.string(forKey: Self.ownKey) == nil || defaults.string(forKey: Self.sampleKey) == nil {
            let names = Self.firstNames(defaultStoreHoldsSample: Self.defaultStoreHoldsSample())
            defaults.set(names.own, forKey: Self.ownKey)
            defaults.set(names.sample, forKey: Self.sampleKey)
            defaults.set(names.mode.rawValue, forKey: Self.modeKey)
        }
        ownName = defaults.string(forKey: Self.ownKey) ?? "default.store"
        sampleName = defaults.string(forKey: Self.sampleKey) ?? "sample.store"
        // A sample-data launch (-PulseDemo) always opens the sample store.
        var m = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .own
        if arguments.contains("-PulseDemo") { m = .sample }
        testingEnabled = arguments.contains("-PulseDemo") || defaults.bool(forKey: Self.testKey) || m == .sample
        mode = m
        defaults.set(m.rawValue, forKey: Self.modeKey)
        container = Self.make(url: Self.url(m == .own ? ownName : sampleName), inMemory: inMemory)
        if m == .own { ownCache = container } else { sampleCache = container }
    }

    /// Which file is which on the first launch: the old default store keeps its data where it belongs.
    nonisolated static func firstNames(defaultStoreHoldsSample: Bool) -> (own: String, sample: String, mode: Mode) {
        defaultStoreHoldsSample ? ("own.store", "default.store", .sample) : ("default.store", "sample.store", .own)
    }

    /// Switches to the other store (the screens are rebuilt on it).
    func use(_ m: Mode) {
        guard m != mode, m == .own || testingEnabled else { return }
        try? container.mainContext.save()
        AgentConversation.shared.switchStore(from: mode.rawValue, to: m.rawValue)
        HealthKitService.shared.inventory = []
        if m == .own { container = ownContainer() } else {
            if sampleCache == nil { sampleCache = Self.make(url: url(for: .sample), inMemory: inMemory) }
            container = sampleCache!
        }
        mode = m
        defaults.set(m.rawValue, forKey: Self.modeKey)
    }

    /// Your own store, for the background check (it never reads Health into sample data).
    func ownContainer() -> ModelContainer {
        if let ownCache { return ownCache }
        let c = Self.make(url: url(for: .own), inMemory: inMemory)
        ownCache = c
        return c
    }

    func enterTesting() {
        testingEnabled = true
        defaults.set(true, forKey: Self.testKey)
        use(.sample)
    }

    func exitTesting() {
        DemoClock.set(nil)
        HealthKitService.shared.inventory = []
        use(.own)
        testingEnabled = false
        defaults.set(false, forKey: Self.testKey)
    }

    /// 删除所有数据: the other store's files go too, and Pulse starts again on an empty store of your own.
    func eraseOtherStore() {
        let otherMode: Mode = mode == .own ? .sample : .own
        AgentConversation.shared.forgetStore(otherMode.rawValue)
        let other = url(for: otherMode)
        if otherMode == .own { ownCache = nil } else { sampleCache = nil }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: other.path + suffix))
        }
        exitTesting()
        // The preferences were cleared with everything else: which file is which is written again.
        defaults.set(ownName, forKey: Self.ownKey)
        defaults.set(sampleName, forKey: Self.sampleKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(testingEnabled, forKey: Self.testKey)
    }

    func url(for m: Mode) -> URL {
        Self.url(m == .own ? ownName : sampleName)
    }

    static func url(_ name: String) -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
    }

    static func make(url: URL, inMemory: Bool) -> ModelContainer {
        let schema = Schema(PulseSchema.models)
        let config = inMemory ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true) : ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("无法创建数据存储：\(error)")
        }
    }

    /// Whether the store from before (default.store) holds a sample user.
    static func defaultStoreHoldsSample() -> Bool {
        let u = url("default.store")
        guard FileManager.default.fileExists(atPath: u.path) else { return false }
        let c = make(url: u, inMemory: false)
        return ((try? c.mainContext.fetch(FetchDescriptor<UserProfile>())) ?? []).first?.usesDemoData == true
    }
}
