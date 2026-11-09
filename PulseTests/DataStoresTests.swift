import Foundation
import SwiftData
import Testing
@testable import Pulse

/// Your own records and the sample users live apart: a sample user never replaces your data.
@Suite("Own data and sample users in separate stores")
@MainActor
struct DataStoresTests {
    @Test func theOldStoreKeepsWhatItHeld() {
        let sample = DataStores.firstNames(defaultStoreHoldsSample: true)
        #expect(sample.sample == "default.store" && sample.own != "default.store" && sample.mode == .sample,
                "sample data in the old store stays the sample store; your own starts empty")
        let own = DataStores.firstNames(defaultStoreHoldsSample: false)
        #expect(own.own == "default.store" && own.mode == .own, "your data in the old store stays yours")
    }

    @Test func yourRecordsSurviveASampleUser() throws {
        let id = UUID().uuidString
        let suite = "test.datastores.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("test-own-\(id).store", forKey: DataStores.ownKey)
        defaults.set("test-sample-\(id).store", forKey: DataStores.sampleKey)
        defaults.set(DataStores.Mode.own.rawValue, forKey: DataStores.modeKey)
        defer {
            for name in ["test-own-\(id).store", "test-sample-\(id).store"] {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: DataStores.url(name).path + suffix)) }
            }
            UserDefaults().removePersistentDomain(forName: suite)
        }

        let stores = DataStores(defaults: defaults, arguments: [])
        #expect(stores.mode == .own)
        let mine = UserProfile()
        mine.nickname = "我自己"
        mine.onboardingDone = true
        stores.container.mainContext.insert(mine)
        try stores.container.mainContext.save()

        // Load a sample user: it goes to the sample store.
        stores.enterTesting()
        let c = stores.container.mainContext
        DemoDataGenerator.populate(c, persona: .linyue)
        try c.save()
        #expect(DataHub.profile(in: c)?.nickname == "林悦")
        #expect(defaults.string(forKey: DataStores.modeKey) == "sample", "the next launch opens the sample user again")

        // Back to your own data: as you left it, no sample records.
        stores.use(.own)
        let back = stores.container.mainContext
        #expect(DataHub.profile(in: back)?.nickname == "我自己")
        #expect(((try? back.fetch(FetchDescriptor<DailyRecord>())) ?? []).isEmpty)

        // A sample-data launch opens the sample store, whatever was open before.
        #expect(DataStores(defaults: defaults, arguments: ["-PulseDemo"]).mode == .sample)
    }
}
