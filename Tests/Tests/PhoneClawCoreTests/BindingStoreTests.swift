import Foundation
import XCTest
@testable import PhoneClawCore

final class BindingStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var credentials: MemoryBindingCredentials!
    private var store: BindingStore!

    override func setUpWithError() throws {
        suiteName = "WolfClaw.BindingStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        credentials = MemoryBindingCredentials()
        store = BindingStore(defaults: defaults, credentials: credentials)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        credentials = nil
        defaults = nil
        suiteName = nil
    }

    private func binding(
        id: String = "test-mac", secret: String = "test-pairing-secret",
        transport: MacBindingTransport = .tailscale
    ) -> MacBinding {
        MacBinding(macID: id, name: "Test Mac", secret: secret,
                   boundAt: Date(timeIntervalSince1970: 1_700_000_000),
                   endpoint: transport == .tailscale ? "https://test-mac.test-tailnet.ts.net:8446" : "http://127.0.0.1:18080",
                   transport: transport)
    }

    private func storedBindings() throws -> [MacBinding] {
        let data = try XCTUnwrap(defaults.data(forKey: BindingStore.defaultsKey))
        return try JSONDecoder().decode([MacBinding].self, from: data)
    }

    func testNewCredentialFailureLeavesNoBindingOrRevisionChange() {
        let candidate = binding()
        let revision = store.revisionForPairing()
        credentials.failedSaveIDs.insert(candidate.macID)

        XCTAssertThrowsError(try store.saveChecked(candidate, ifRevision: revision)) { error in
            XCTAssertEqual(error as? BindingStore.SaveError, .credentialStorage)
        }
        XCTAssertFalse(store.save(candidate, ifRevision: revision))
        XCTAssertNil(defaults.data(forKey: BindingStore.defaultsKey))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(credentials.values[candidate.macID])
        XCTAssertEqual(store.revisionForPairing(), revision)
    }

    func testFailedRebindPreservesTokenMetadataAndSnapshot() throws {
        let original = binding(secret: "original-secret")
        try store.saveChecked(original)
        let snapshot = try XCTUnwrap(store.snapshot(macID: original.macID))
        let revision = store.revisionForPairing()
        let metadata = defaults.data(forKey: BindingStore.defaultsKey)
        var replacement = binding(secret: "replacement-secret")
        replacement.endpoint = "https://replacement.test-tailnet.ts.net:8446"
        replacement.boundAt = original.boundAt.addingTimeInterval(60)
        credentials.failedSaveIDs.insert(original.macID)

        XCTAssertThrowsError(try store.saveChecked(replacement, ifRevision: revision)) { error in
            XCTAssertEqual(error as? BindingStore.SaveError, .credentialStorage)
        }
        XCTAssertEqual(store.binding(macID: original.macID), original)
        XCTAssertEqual(credentials.values[original.macID], original.secret)
        XCTAssertEqual(defaults.data(forKey: BindingStore.defaultsKey), metadata)
        XCTAssertEqual(store.revisionForPairing(), revision)
        XCTAssertTrue(store.isCurrent(snapshot))
    }

    func testSuccessfulSavePublishesHydratedBindingButNoSecretInMetadata() throws {
        let candidate = binding()
        let revision = store.revisionForPairing()
        try store.saveChecked(candidate, ifRevision: revision)

        XCTAssertEqual(store.binding(macID: candidate.macID), candidate)
        XCTAssertEqual(credentials.values[candidate.macID], candidate.secret)
        let raw = try XCTUnwrap(storedBindings().first)
        XCTAssertEqual(raw.secret, "")
        XCTAssertEqual(raw.transport, .tailscale)
        XCTAssertEqual(raw.endpoint, candidate.endpoint)
        let data = try XCTUnwrap(defaults.data(forKey: BindingStore.defaultsKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(candidate.secret))
        XCTAssertNotEqual(store.revisionForPairing(), revision)
    }

    func testSuccessfulRebindInvalidatesOldSnapshot() throws {
        let original = binding(secret: "original-secret")
        try store.saveChecked(original)
        let snapshot = try XCTUnwrap(store.snapshot(macID: original.macID))
        let replacement = binding(secret: "replacement-secret")

        XCTAssertTrue(store.save(replacement, ifRevision: store.revisionForPairing()))
        XCTAssertEqual(store.binding(macID: original.macID), replacement)
        XCTAssertEqual(credentials.values[original.macID], replacement.secret)
        XCTAssertFalse(store.isCurrent(snapshot))
    }

    func testStalePairingRevisionCannotWriteCredentialOrRestoreRemovedBinding() throws {
        let original = binding()
        try store.saveChecked(original)
        let pendingRevision = store.revisionForPairing()
        store.remove(macID: original.macID)
        let savesBefore = credentials.saveAttempts

        XCTAssertThrowsError(try store.saveChecked(original, ifRevision: pendingRevision)) { error in
            XCTAssertEqual(error as? BindingStore.SaveError, .pairingChanged)
        }
        XCTAssertEqual(credentials.saveAttempts, savesBefore)
        XCTAssertNil(credentials.values[original.macID])
        XCTAssertNil(store.binding(macID: original.macID))
    }

    func testFailedLegacyMigrationPreservesOnlyCopyAndRetryScrubsIt() throws {
        let legacy = binding(secret: "legacy-token-in-old-metadata", transport: .lan)
        let originalData = try JSONEncoder().encode([legacy])
        defaults.set(originalData, forKey: BindingStore.defaultsKey)
        credentials.failedSaveIDs.insert(legacy.macID)

        XCTAssertEqual(store.binding(macID: legacy.macID)?.secret, "")
        XCTAssertNil(credentials.values[legacy.macID])
        XCTAssertEqual(defaults.data(forKey: BindingStore.defaultsKey), originalData)

        credentials.failedSaveIDs.remove(legacy.macID)
        XCTAssertEqual(store.binding(macID: legacy.macID), legacy)
        XCTAssertEqual(credentials.values[legacy.macID], legacy.secret)
        XCTAssertEqual(try storedBindings().first?.secret, "")
    }

    func testUnrelatedSaveRefreshAndRemovalPreserveUnmigratedLegacyCredential() throws {
        let legacy = binding(id: "legacy-mac", secret: "legacy-only-copy", transport: .lan)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: BindingStore.defaultsKey)
        credentials.failedSaveIDs.insert(legacy.macID)
        XCTAssertEqual(store.binding(macID: legacy.macID)?.secret, "")
        let other = binding(id: "other-mac", secret: "other-token", transport: .lan)

        try store.saveChecked(other)
        XCTAssertEqual(try storedBindings().first { $0.macID == legacy.macID }?.secret, legacy.secret)
        let snapshot = try XCTUnwrap(store.snapshot(macID: other.macID))
        XCTAssertTrue(store.refreshEndpoint("http://127.0.0.1:18081", ifCurrent: snapshot))
        XCTAssertEqual(try storedBindings().first { $0.macID == legacy.macID }?.secret, legacy.secret)
        store.remove(macID: other.macID)
        XCTAssertEqual(try storedBindings(), [legacy])
        XCTAssertNil(credentials.values[legacy.macID])
    }

    func testPartialLegacyMigrationScrubsOnlyTheSuccessfullyStoredCredential() throws {
        let migratable = binding(id: "working-mac", secret: "working-legacy-token", transport: .lan)
        let blocked = binding(id: "blocked-mac", secret: "blocked-legacy-only-copy", transport: .lan)
        defaults.set(try JSONEncoder().encode([migratable, blocked]), forKey: BindingStore.defaultsKey)
        credentials.failedSaveIDs.insert(blocked.macID)

        let hydrated = store.all()
        XCTAssertEqual(hydrated.first { $0.macID == migratable.macID }?.secret, migratable.secret)
        XCTAssertEqual(hydrated.first { $0.macID == blocked.macID }?.secret, "")
        XCTAssertEqual(credentials.values[migratable.macID], migratable.secret)
        XCTAssertNil(credentials.values[blocked.macID])
        let raw = try storedBindings()
        XCTAssertEqual(raw.first { $0.macID == migratable.macID }?.secret, "")
        XCTAssertEqual(raw.first { $0.macID == blocked.macID }?.secret, blocked.secret)
    }

    func testEncodingFailureCannotReplaceExistingCredential() throws {
        let original = binding(secret: "original-secret")
        try store.saveChecked(original)
        let metadata = defaults.data(forKey: BindingStore.defaultsKey)
        let snapshot = try XCTUnwrap(store.snapshot(macID: original.macID))
        let savesBefore = credentials.saveAttempts
        var invalid = binding(secret: "replacement-secret")
        invalid.boundAt = Date(timeIntervalSince1970: .infinity)

        XCTAssertThrowsError(try store.saveChecked(invalid)) { error in
            XCTAssertEqual(error as? BindingStore.SaveError, .metadataEncoding)
        }
        XCTAssertEqual(credentials.saveAttempts, savesBefore)
        XCTAssertEqual(credentials.values[original.macID], original.secret)
        XCTAssertEqual(defaults.data(forKey: BindingStore.defaultsKey), metadata)
        XCTAssertTrue(store.isCurrent(snapshot))
    }

    func testInvalidTailscaleOriginCannotChangeExistingBinding() throws {
        let original = binding()
        try store.saveChecked(original)
        let snapshot = try XCTUnwrap(store.snapshot(macID: original.macID))
        let savesBefore = credentials.saveAttempts
        var invalid = binding(secret: "replacement-secret")
        invalid.endpoint = "http://test-mac.test-tailnet.ts.net:8446"

        XCTAssertThrowsError(try store.saveChecked(invalid)) { error in
            XCTAssertEqual(error as? BindingStore.SaveError, .invalidEndpoint)
        }
        XCTAssertEqual(credentials.saveAttempts, savesBefore)
        XCTAssertEqual(store.binding(macID: original.macID), original)
        XCTAssertTrue(store.isCurrent(snapshot))
    }
}

/// Riproduce il contratto atomico delle operazioni Keychain senza credenziali reali.
private final class MemoryBindingCredentials: BindingCredentialStorage {
    var values: [String: String] = [:]
    var failedSaveIDs: Set<String> = []
    private(set) var saveAttempts = 0

    func loadSecret(macID: String) -> String? { values[macID] }

    func saveSecret(_ secret: String, macID: String) -> Bool {
        saveAttempts += 1
        guard !failedSaveIDs.contains(macID) else { return false }
        values[macID] = secret
        return true
    }

    func deleteSecret(macID: String) -> Bool {
        values.removeValue(forKey: macID)
        return true
    }
}
