import Foundation
import Security

protocol BindingCredentialStorage {
    func loadSecret(macID: String) -> String?
    @discardableResult func saveSecret(_ secret: String, macID: String) -> Bool
    @discardableResult func deleteSecret(macID: String) -> Bool
}

/// I metadati diventano visibili solo dopo il salvataggio riuscito della credenziale.
final class BindingStore {
    struct Snapshot {
        let binding: MacBinding
        fileprivate let revision: UUID
    }

    enum SaveError: Error, Equatable {
        case pairingChanged
        case invalidEndpoint
        case credentialStorage
        case metadataEncoding
    }

    static let defaultsKey = "PhoneClaw.remote.bindings"
    private let defaults: UserDefaults
    private let credentials: BindingCredentialStorage
    private let lock = NSRecursiveLock()
    private var revisions: [String: UUID] = [:]
    private var pairingRevision = UUID()

    init(defaults: UserDefaults = .standard, credentials: BindingCredentialStorage = KeychainBindingCredentialStorage()) {
        self.defaults = defaults
        self.credentials = credentials
    }

    func all() -> [MacBinding] {
        lock.lock(); defer { lock.unlock() }
        let stored = storedBindings()
        var metadata = stored
        var needsScrub = false
        let hydrated = stored.enumerated().map { index, stored -> MacBinding in
            var binding = stored
            binding.secret = ""
            if let secret = credentials.loadSecret(macID: stored.macID).flatMap(LANIdentityProof.usableSecret) {
                binding.secret = secret
                metadata[index].secret = ""
                needsScrub = needsScrub || !stored.secret.isEmpty
            } else if let legacySecret = LANIdentityProof.usableSecret(stored.secret) {
                // Se il Keychain rifiuta la migrazione, conserva l'unica copia per riprovare.
                // Il token legacy non viene usato per richieste finché non è salvato in modo sicuro.
                if credentials.saveSecret(legacySecret, macID: stored.macID) {
                    binding.secret = legacySecret
                    metadata[index].secret = ""
                    needsScrub = true
                }
            } else if !stored.secret.isEmpty {
                metadata[index].secret = ""
                needsScrub = true
            }
            return binding
        }
        if needsScrub { persistMetadata(metadata) }
        return hydrated
    }

    func binding(macID: String) -> MacBinding? { all().first { $0.macID == macID } }

    func snapshot(macID: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let binding = binding(macID: macID) else { return nil }
        let revision = revisions[macID] ?? UUID()
        revisions[macID] = revision
        return Snapshot(binding: binding, revision: revision)
    }

    func snapshot(matching expected: MacBinding) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = snapshot(macID: expected.macID),
              snapshot.binding.boundAt == expected.boundAt,
              snapshot.binding.transport == expected.transport,
              expected.transport != .tailscale || snapshot.binding.endpoint == expected.endpoint,
              LANIdentityProof.usableSecret(snapshot.binding.secret) == LANIdentityProof.usableSecret(expected.secret) else { return nil }
        return snapshot
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revisions[snapshot.binding.macID] == snapshot.revision,
              let current = binding(macID: snapshot.binding.macID) else { return false }
        return current.boundAt == snapshot.binding.boundAt
            && current.transport == snapshot.binding.transport
            && (current.transport != .tailscale || current.endpoint == snapshot.binding.endpoint)
            && LANIdentityProof.usableSecret(current.secret) == LANIdentityProof.usableSecret(snapshot.binding.secret)
    }

    /// Il recupero dell'IP aggiorna solo metadati: non ricrea pairing né riscrive credenziali.
    func refreshEndpoint(_ endpoint: String, ifCurrent snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isCurrent(snapshot) else { return false }
        var list = storedBindings()
        guard let index = list.firstIndex(where: { $0.macID == snapshot.binding.macID }) else { return false }
        if list[index].transport == .tailscale {
            return list[index].endpoint.flatMap(LANEndpointPolicy.tailscaleRoot)?.absoluteString == endpoint
        }
        list[index].endpoint = endpoint
        return persistMetadata(list)
    }

    func revisionForPairing() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return pairingRevision
    }

    @discardableResult
    func save(_ binding: MacBinding, ifRevision expectedRevision: UUID? = nil) -> Bool {
        do {
            try saveChecked(binding, ifRevision: expectedRevision)
            return true
        } catch { return false }
    }

    func saveChecked(_ binding: MacBinding, ifRevision expectedRevision: UUID? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var list = storedBindings()
        guard expectedRevision == nil || expectedRevision == pairingRevision,
              MacBindingTransport.permitsReplacement(existing: list.first { $0.macID == binding.macID }?.transport,
                                                       proposed: binding.transport) else { throw SaveError.pairingChanged }
        if binding.transport == .tailscale {
            guard let endpoint = binding.endpoint,
                  LANEndpointPolicy.tailscaleRoot(endpoint)?.absoluteString == endpoint else { throw SaveError.invalidEndpoint }
        }
        var metadata = binding
        metadata.secret = ""
        list.removeAll { $0.macID == binding.macID }
        list.append(metadata)
        // Prepara prima i metadati: un errore di codifica non deve sostituire il token precedente.
        guard let data = try? JSONEncoder().encode(list) else { throw SaveError.metadataEncoding }
        let persisted: Bool
        if let secret = LANIdentityProof.usableSecret(binding.secret) {
            persisted = credentials.saveSecret(secret, macID: binding.macID)
        } else {
            persisted = credentials.deleteSecret(macID: binding.macID)
        }
        guard persisted else { throw SaveError.credentialStorage }

        defaults.set(data, forKey: Self.defaultsKey)
        pairingRevision = UUID()
        revisions[binding.macID] = UUID()
    }

    func remove(macID: String) {
        lock.lock(); defer { lock.unlock() }
        pairingRevision = UUID()
        revisions[macID] = UUID()
        let remaining = storedBindings().filter { $0.macID != macID }
        credentials.deleteSecret(macID: macID)
        persistMetadata(remaining)
    }

    private func storedBindings() -> [MacBinding] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([MacBinding].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    private func persistMetadata(_ list: [MacBinding]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }
}

struct KeychainBindingCredentialStorage: BindingCredentialStorage {
    private static let service = "ai.phoneclaw.remote.bindings"

    func loadSecret(macID: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(account: macID, returningData: true) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func saveSecret(_ secret: String, macID: String) -> Bool {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return deleteSecret(macID: macID) }
        let data = Data(clean.utf8)
        let query = baseQuery(account: macID, returningData: false)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func deleteSecret(macID: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: macID, returningData: false) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String, returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}
