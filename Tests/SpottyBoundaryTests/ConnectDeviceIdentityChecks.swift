import Testing
import Foundation
@testable import SpottyCore
@testable import SpottyEngineAdapter
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Connect Device Identity")
struct ConnectDeviceIdentityTests {
    @Test
    @MainActor
    func testConnectDeviceIdentity() {
        do {
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "Studio Mac")) == ("Studio Mac (Spotty)"),
                "Computer Name is followed by the app name")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "  Studio Mac\n")) == ("Studio Mac (Spotty)"),
                "Computer Name is trimmed")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: nil)) == ("Mac (Spotty)"),
                "missing Computer Name has a natural fallback")
        }

    }
}

@Suite("Connect installation identity")
@MainActor
struct ConnectInstallationIDTests {
    @Test
    func survivesStoreRecreationAndNameChangesWithoutTouchingClientTokenID() throws {
        let suite = "dev.spotty.tests.connect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("client-token-sentinel", forKey: UserDefaultsDeviceIdStore.storageKey)
        let first = ConnectInstallationIDStore(defaults: defaults).deviceId()
        #expect(ConnectInstallationIDStore.isValid(first))
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ConnectInstallationIDStore(defaults: reopened).deviceId() == first)
        #expect(ConnectDeviceIdentity.advertisedName(computerName: "Renamed Mac") == "Renamed Mac (Spotty)")
        #expect(ConnectInstallationIDStore(defaults: reopened).deviceId() == first)
        #expect(defaults.string(forKey: UserDefaultsDeviceIdStore.storageKey) == "client-token-sentinel")
    }

    @Test
    func isolatesFreshInstallationsAndRepairsInvalidIdentity() throws {
        let suite = "dev.spotty.tests.connect.\(UUID().uuidString)"
        let otherSuite = "dev.spotty.tests.connect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        defaults.set("spotty_123", forKey: ConnectInstallationIDStore.storageKey)
        let first = ConnectInstallationIDStore(defaults: defaults).deviceId()
        let second = ConnectInstallationIDStore(defaults: otherDefaults).deviceId()
        #expect(first != second)
        #expect(ConnectInstallationIDStore.isValid(first) && ConnectInstallationIDStore.isValid(second))
        #expect(!ConnectInstallationIDStore.isValid(String(repeating: "é", count: 20)))
        #expect(!ConnectInstallationIDStore.isValid(String(repeating: "g", count: 40)))
    }

    @Test
    func concurrentCreationUsesOneIdentity() async throws {
        let suite = "dev.spotty.tests.connect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectInstallationIDStore(defaults: defaults)
        let identifiers = await withTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { store.deviceId() } }
            var result: Set<String> = []
            for await identifier in group { result.insert(identifier) }
            return result
        }
        #expect(identifiers.count == 1)
    }
}

@Suite("Client token installation identity")
@MainActor
struct ClientTokenInstallationIDTests {
    @Test(arguments: [String(repeating: "a", count: 40), String(repeating: "A", count: 40)])
    func preservesValidIdentityExactly(_ identity: String) throws {
        let suite = "dev.spotty.tests.client-token.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(identity, forKey: UserDefaultsDeviceIdStore.storageKey)
        #expect(UserDefaultsDeviceIdStore(defaults: defaults).deviceId() == identity)
        #expect(defaults.string(forKey: UserDefaultsDeviceIdStore.storageKey) == identity)
    }

    @Test(arguments: [
        String(repeating: "Ｆ", count: 40),
        String(repeating: "１", count: 40),
        "Ａ" + String(repeating: "1", count: 39),
        String(repeating: "a", count: 39),
        String(repeating: "g", count: 40),
    ])
    func repairsInvalidIdentityWithoutChangingConnectIdentity(_ invalid: String) throws {
        let suite = "dev.spotty.tests.client-token.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(invalid, forKey: UserDefaultsDeviceIdStore.storageKey)
        defaults.set("connect-sentinel", forKey: ConnectInstallationIDStore.storageKey)
        let identity = UserDefaultsDeviceIdStore(defaults: defaults).deviceId()
        #expect(identity != invalid)
        #expect(identity.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(UserDefaultsDeviceIdStore(defaults: reopened).deviceId() == identity)
        #expect(defaults.string(forKey: ConnectInstallationIDStore.storageKey) == "connect-sentinel")
    }

    @Test
    func concurrentStoresShareOnePersistedIdentity() async throws {
        let suite = "dev.spotty.tests.client-token.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = try (0..<20).map { _ in
            UserDefaultsDeviceIdStore(defaults: try #require(UserDefaults(suiteName: suite)))
        }
        let identifiers = await withTaskGroup(of: String.self) { group in
            for store in stores { group.addTask { store.deviceId() } }
            var result: Set<String> = []
            for await identifier in group { result.insert(identifier) }
            return result
        }
        #expect(identifiers.count == 1)
        #expect(identifiers.first == defaults.string(forKey: UserDefaultsDeviceIdStore.storageKey))
    }
}
