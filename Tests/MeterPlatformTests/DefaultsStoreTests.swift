import Foundation
import MeterTestSupport
import Testing

@testable import MeterPlatform

@Suite struct DefaultsStoreTests {
    @Test func theDefaultStoreOfATestProcessKeepsValuesInMemory() {
        #expect(TestProcess.isRunning)
        let store = DefaultsStore()
        #expect(!store.isPersistent)
        let key = "test.\(UUID().uuidString)"
        store.set(Data("value".utf8), forKey: key)
        #expect(store.data(forKey: key) == Data("value".utf8))
        // Another store does not see the value, so it never reached a shared domain.
        #expect(DefaultsStore().data(forKey: key) == nil)
        store.set(nil, forKey: key)
        #expect(store.data(forKey: key) == nil)
    }
}
