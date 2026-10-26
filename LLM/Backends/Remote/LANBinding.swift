import Foundation
import Network
import Security

// MARK: - LAN Binding (连接链路 · 第二层)
//
// 绑定 = 手机和某台 Mac 的持久关系。傻瓜化"选一次 → 以后静默自动重连"靠它。
//
// 关键设计:
//   - 绑定只认 Mac 的稳定 id (TXT 里的 macID), **不存 IP** —— 换网/换 IP 由发现层
//     重新 resolve 兜住, 绑定不失效。
//   - 传输无关:现在在同一局域网 → 发现层 resolve 直连;未来不在同网 → 云 relay
//     复用同一条 binding (secret 做鉴权)。所以 binding 里不绑死任何 transport。
//
// secret:配对握手时跟 Mac 换得。持久化时只进 Keychain,UserDefaults 只保留
// macID/name/endpoint 这些非秘密元数据。

/// 绑定持久化。UserDefaults JSON 只保存非秘密元数据;secret/token 存 Keychain。
final class BindingStore {
    struct Snapshot {
        let binding: MacBinding
        fileprivate let revision: UUID
    }

    static let defaultsKey = "PhoneClaw.remote.bindings"
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var revisions: [String: UUID] = [:]
    private var pairingRevision = UUID()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [MacBinding] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([MacBinding].self, from: data) else { return [] }

        var needsScrub = false
        let hydrated = list.map { stored -> MacBinding in
            var binding = stored
            if let secret = RemoteBindingCredentialStore.loadBindingSecret(macID: binding.macID), !secret.isEmpty {
                binding.secret = secret
            } else {
                let legacySecret = binding.secret.trimmingCharacters(in: .whitespacesAndNewlines)
                if !legacySecret.isEmpty && legacySecret != "(pending-handshake)" {
                    RemoteBindingCredentialStore.saveBindingSecret(legacySecret, macID: binding.macID)
                    binding.secret = legacySecret
                    needsScrub = true
                }
            }
            if !stored.secret.isEmpty {
                needsScrub = true
            }
            return binding
        }
        if needsScrub {
            persist(hydrated)
        }
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

    /// Il recupero dell'IP aggiorna solo metadati: non può ricreare un pairing o riscrivere una credenziale.
    func refreshEndpoint(_ endpoint: String, ifCurrent snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isCurrent(snapshot) else { return false }
        var list = all()
        guard let index = list.firstIndex(where: { $0.macID == snapshot.binding.macID }) else { return false }
        if list[index].transport == .tailscale {
            // La verifica non modifica mai l'origine HTTPS fissata durante il pairing.
            return list[index].endpoint.flatMap(LANEndpointPolicy.tailscaleRoot)?.absoluteString == endpoint
        }
        list[index].endpoint = endpoint
        persist(list)
        return true
    }

    func revisionForPairing() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return pairingRevision
    }

    @discardableResult
    func save(_ binding: MacBinding, ifRevision expectedRevision: UUID? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard expectedRevision == nil || expectedRevision == pairingRevision,
              MacBindingTransport.permitsReplacement(existing: self.binding(macID: binding.macID)?.transport,
                                                       proposed: binding.transport) else { return false }
        if binding.transport == .tailscale {
            guard let endpoint = binding.endpoint,
                  LANEndpointPolicy.tailscaleRoot(endpoint)?.absoluteString == endpoint else { return false }
        }
        pairingRevision = UUID()
        revisions[binding.macID] = UUID()
        let secret = binding.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty || secret == "(pending-handshake)" {
            RemoteBindingCredentialStore.deleteBindingSecret(macID: binding.macID)
        } else {
            RemoteBindingCredentialStore.saveBindingSecret(secret, macID: binding.macID)
        }
        var list = all().filter { $0.macID != binding.macID }
        list.append(binding)
        persist(list)
        return true
    }

    func remove(macID: String) {
        lock.lock(); defer { lock.unlock() }
        pairingRevision = UUID()
        revisions[macID] = UUID()
        let remaining = all().filter { $0.macID != macID }
        RemoteBindingCredentialStore.deleteBindingSecret(macID: macID)
        persist(remaining)
    }

    private func persist(_ list: [MacBinding]) {
        let scrubbed = list.map { binding -> MacBinding in
            var copy = binding
            copy.secret = ""
            return copy
        }
        if let data = try? JSONEncoder().encode(scrubbed) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

private enum RemoteBindingCredentialStore {
    private static let service = "ai.phoneclaw.remote.bindings"

    static func loadBindingSecret(macID: String) -> String? {
        load(account: macID)
    }

    @discardableResult
    static func saveBindingSecret(_ secret: String, macID: String) -> Bool {
        save(secret, account: macID)
    }

    @discardableResult
    static func deleteBindingSecret(macID: String) -> Bool {
        delete(account: macID)
    }

    private static func load(account: String) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(account: account, returningData: true) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func save(_ value: String, account: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return delete(account: account) }
        let data = Data(clean.utf8)
        let query = baseQuery(account: account, returningData: false)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account, returningData: false) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String, returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

// MARK: - Connection Manager (发现 + 绑定 + 重连)

/// 把发现层和绑定层拼起来:手机侧"列出 Mac → 绑定 → 按 macID 自动重连出 endpoint"。
@Observable
final class LANConnectionManager {
    let discovery = LANDiscoveryService()
    @ObservationIgnored let bindings: BindingStore
    @ObservationIgnored var lastPairError: String?   // 诊断:配对失败卡在哪一步(UI 显示)
    @ObservationIgnored private let pairingLock = NSRecursiveLock()
    @ObservationIgnored private var pairingOperationID: UUID?

    init(bindings: BindingStore = BindingStore()) {
        self.bindings = bindings
    }

    func startDiscovery() { discovery.start() }
    func stopDiscovery() { discovery.stop() }

    /// 配对绑定一台发现到的 Mac (现阶段 secret 占位;真握手待 Mac 网关 /pair)。
    @discardableResult
    func bind(_ mac: DiscoveredMac) -> MacBinding? {
        guard let macID = mac.macID else { return nil }   // 没 TXT id 不能绑 (没稳定身份)
        let binding = MacBinding(
            macID: macID,
            name: mac.name,
            secret: "(pending-handshake)",
            boundAt: Date()
        )
        return bindings.save(binding) ? binding : nil
    }

    /// 按绑定自动重连:当前发现结果里按 macID 找回那台 Mac → resolve → 出 RemoteInferenceService base URL。
    /// 发现结果里没有 (Mac 离线/不在同网) → nil (未来这里接 relay)。
    func resolveEndpoint(for binding: MacBinding) async -> URL? {
        guard let snapshot = bindings.snapshot(matching: binding) else { return nil }
        return await resolveEndpoint(for: snapshot)
    }

    private func resolveEndpoint(for snapshot: BindingStore.Snapshot) async -> URL? {
        let binding = snapshot.binding
        guard LANIdentityProof.usableSecret(binding.secret) != nil else { return nil }
        // Bonjour prima della cache: l'IP assegnato al Mac può cambiare tra due turni.
        var discoveredRoots: [URL] = []
        if binding.transport == .lan,
           let mac = await discovery.findMac(macID: binding.macID),
           let root = await resolveRoot(mac.endpoint) {
            discoveredRoots.append(root)
        }
        guard !Task.isCancelled, bindings.isCurrent(snapshot) else { return nil }
        guard let root = await LANEndpointPolicy.verifiedRoot(
            discovered: discoveredRoots, savedEndpoint: binding.endpoint,
            macID: binding.macID, secret: binding.secret,
            transport: binding.transport,
            isCurrent: { self.bindings.isCurrent(snapshot) },
            probe: Self.probeIdentity
        ) else { return nil }
        guard !Task.isCancelled,
              bindings.refreshEndpoint(root.absoluteString, ifCurrent: snapshot) else { return nil }
        return root.appendingPathComponent("v1")
    }

    // MARK: 远程模型 ↔ 绑定

    /// modelID "remote::<macID>::<modelName>" → (endpoint /v1, token, 模型名)。给 RemoteInferenceService 的 resolver。
    func resolveRemoteModel(_ modelID: String) async -> (url: URL, token: String?, modelName: String)? {
        let parts = modelID.components(separatedBy: "::")
        guard parts.count == 3, parts[0] == "remote" else { return nil }
        guard let snapshot = bindings.snapshot(macID: parts[1]),
              let base = await resolveEndpoint(for: snapshot),
              !Task.isCancelled, bindings.isCurrent(snapshot),
              let token = LANIdentityProof.usableSecret(snapshot.binding.secret) else { return nil }
        return (base, token, parts[2])
    }

    /// 拉一台已绑定 Mac 的 /v1/models, 转成远程 ModelDescriptor (给 catalog 列进选择器)。
    func remoteModels(for binding: MacBinding) async -> [ModelDescriptor] {
        guard let snapshot = bindings.snapshot(matching: binding),
              let base = await resolveEndpoint(for: snapshot),
              !Task.isCancelled, bindings.isCurrent(snapshot),
              let token = LANIdentityProof.usableSecret(snapshot.binding.secret) else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await LANHTTPTransport.session.data(for: req),
              !Task.isCancelled, bindings.isCurrent(snapshot),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> ModelDescriptor? in
            guard let id = item["id"] as? String else { return nil }
            return Self.remoteModelDescriptor(
                macID: binding.macID,
                macName: binding.name,
                modelName: id,
                displayName: item["display_name"] as? String
            )
        }
    }

    /// 远程模型描述符:artifactKind=.remoteEndpoint → BackendDispatcher 路由到 RemoteInferenceService。
    static func remoteModelDescriptor(
        macID: String,
        macName: String,
        modelName: String,
        displayName: String? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: "remote::\(macID)::\(modelName)",
            displayName: "\(macName) · \(remoteDisplayTitle(for: modelName, displayName: displayName))",
            family: .gemma4,                 // 走 <|turn> 模板, RemoteInferenceService 反解析成 messages
            artifactKind: .remoteEndpoint,
            downloadURLs: [],
            fileName: "",
            expectedFileSize: 0,
            capabilities: ModelCapabilities(
                supportsVision: false, supportsAudio: false, supportsLive: false,
                supportsStructuredPlanning: false, supportsThinking: false,
                supportsPersistentSession: false, supportsSessionSnapshot: false,
                safeContextBudgetTokens: 3500, defaultReservedOutputTokens: 700
            ),
            runtimeProfile: MLXModelProfiles.gemma4_e2b
        )
    }

    static func remoteDisplayTitle(for modelName: String, displayName: String? = nil) -> String {
        let parts = remoteDisplayParts(for: modelName, displayName: displayName)
        if let subtitle = parts.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(parts.title)"
        }
        return parts.title
    }

    static func remoteDisplayParts(for model: ModelDescriptor) -> (title: String, subtitle: String?) {
        let displayParts = model.displayName
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if displayParts.count >= 3 {
            return (displayParts.dropFirst(2).joined(separator: " · "), displayParts[1])
        }
        let idParts = model.id.components(separatedBy: "::")
        guard idParts.count >= 3 else { return (model.displayName, nil) }
        return remoteDisplayParts(for: idParts[2])
    }

    static func remoteDisplayParts(for modelName: String, displayName: String? = nil) -> (title: String, subtitle: String?) {
        let parts = modelName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (displayName ?? modelName, nil) }
        let provider = parts[0]
        let model = parts[1]
        switch provider.lowercased() {
        case "codex":
            return (displayName ?? model, "Codex CLI")
        case "antigravity":
            return (displayName ?? model, "Antigravity CLI")
        case "ollama":
            return (displayName ?? model, "Ollama")
        default:
            return (displayName ?? model, provider)
        }
    }

    /// 解析一台发现到的 Mac 的网关根地址 http://host:port (去掉 IPv4 的 %scope)。
    func resolveRoot(_ endpoint: NWEndpoint) async -> URL? {
        guard let hp = await discovery.resolve(endpoint) else { return nil }
        return URL(string: "http://\(Self.urlHost(hp.host)):\(hp.port)")
    }

    /// resolve 出来的 host 整成能塞进 URL 的形式:IPv6 加方括号(%scope→%25),IPv4 去掉 %scope。
    static func urlHost(_ raw: String) -> String {
        if raw.contains(":") {   // IPv6
            return "[\(raw.replacingOccurrences(of: "%", with: "%25"))]"
        }
        return raw.contains("%") ? String(raw.prefix { $0 != "%" }) : raw
    }

    /// 配对握手:resolve → POST /pair 拿 token → 存绑定 (secret=token)。需要 Mac 网关在跑。
    static let defaultDeviceName = ProcessInfo.processInfo.hostName   // 跨平台 (iOS 无 Host/NSHost);UI 会传真实 UIDevice.current.name 覆盖

    @discardableResult
    func pair(_ mac: DiscoveredMac, deviceName: String = LANConnectionManager.defaultDeviceName) async -> MacBinding? {
        let operation = beginPairing()
        defer { finishPairing(operation.id) }
        if let macID = mac.macID, bindings.binding(macID: macID)?.transport == .tailscale {
            failPairing(operation.id, key: "remote.error.downgradeBlocked",
                        message: "Rimuovi prima l’associazione Tailscale per collegare questo Mac via LAN.")
            return nil
        }
        guard let root = await resolveRoot(mac.endpoint) else {
            failPairing(operation.id, key: "remote.error.lanResolutionFailed", message: "Impossibile risolvere l’indirizzo LAN del Mac.")
            return nil
        }
        guard pairingIsCurrent(operation.id) else { return nil }
        guard let pair = await requestPairToken(root, deviceName: deviceName),
              mac.macID == nil || mac.macID == pair.macID else {
            failPairing(operation.id, key: "remote.error.lanPairingFailed", message: "Pairing non riuscito: verifica la rete e l’approvazione sul Mac.")
            return nil
        }
        guard pairingIsCurrent(operation.id) else { return nil }
        if bindings.binding(macID: pair.macID)?.transport == .tailscale {
            failPairing(operation.id, key: "remote.error.downgradeBlocked",
                        message: "Rimuovi prima l’associazione Tailscale per collegare questo Mac via LAN.")
            return nil
        }
        let binding = MacBinding(macID: pair.macID, name: mac.name, secret: pair.token, boundAt: Date(), endpoint: root.absoluteString)
        return savePairing(binding, operation: operation) ? binding : nil
    }

    /// Pairing manuale via Serve: HTTPS verifica il nome, la prova HMAC verifica il nuovo token.
    @discardableResult
    func pairTailscale(endpoint: String, name: String, deviceName: String = LANConnectionManager.defaultDeviceName) async -> MacBinding? {
        let operation = beginPairing()
        defer { finishPairing(operation.id) }
        guard let root = LANEndpointPolicy.tailscaleRoot(endpoint) else {
            failPairing(operation.id, key: "remote.error.invalidTailscaleEndpoint",
                        message: "Inserisci un indirizzo HTTPS .ts.net senza percorso, utente, query o frammento.")
            return nil
        }
        guard pairingIsCurrent(operation.id),
              let pair = await requestPairToken(root, deviceName: deviceName) else {
            failPairing(operation.id, key: "remote.error.tailscalePairingFailed",
                        message: "Pairing non riuscito: verifica Tailscale, Serve e l’approvazione sul Mac.")
            return nil
        }
        guard let verified = await LANEndpointPolicy.verifiedRoot(
            discovered: [], savedEndpoint: root.absoluteString, macID: pair.macID, secret: pair.token,
            transport: .tailscale,
            isCurrent: { self.pairingIsCurrent(operation.id) && self.bindings.revisionForPairing() == operation.storeRevision },
            probe: Self.probeIdentity
        ), verified == root else {
            failPairing(operation.id, key: "remote.error.identityFailed", message: "Il Mac non ha superato la verifica d’identità.")
            return nil
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let binding = MacBinding(macID: pair.macID, name: cleanName.isEmpty ? root.host! : cleanName,
                                 secret: pair.token, boundAt: Date(), endpoint: root.absoluteString, transport: .tailscale)
        return savePairing(binding, operation: operation) ? binding : nil
    }

    /// Chiamata dalla UI quando cambia modalità o chiude la schermata; una risposta tardiva non salva nulla.
    func cancelPairing() {
        pairingLock.lock(); defer { pairingLock.unlock() }
        pairingOperationID = nil
        lastPairError = nil
    }

    private struct PairingOperation {
        let id: UUID
        let storeRevision: UUID
    }

    private func beginPairing() -> PairingOperation {
        pairingLock.lock(); defer { pairingLock.unlock() }
        let operation = PairingOperation(id: UUID(), storeRevision: bindings.revisionForPairing())
        pairingOperationID = operation.id
        lastPairError = nil
        return operation
    }

    private func pairingIsCurrent(_ id: UUID) -> Bool {
        pairingLock.lock(); defer { pairingLock.unlock() }
        return !Task.isCancelled && pairingOperationID == id
    }

    private func finishPairing(_ id: UUID) {
        pairingLock.lock(); defer { pairingLock.unlock() }
        if pairingOperationID == id { pairingOperationID = nil }
    }

    private func failPairing(_ id: UUID, key: String, message: String) {
        pairingLock.lock(); defer { pairingLock.unlock() }
        guard pairingIsCurrent(id) else { return }
        lastPairError = NSLocalizedString(key, value: message, comment: "Errore del collegamento Mac")
    }

    private func savePairing(_ binding: MacBinding, operation: PairingOperation) -> Bool {
        pairingLock.lock(); defer { pairingLock.unlock() }
        guard pairingIsCurrent(operation.id) else { return false }
        guard bindings.save(binding, ifRevision: operation.storeRevision) else {
            failPairing(operation.id, key: "remote.error.pairingChanged", message: "Associazione annullata o modificata. Riprova.")
            return false
        }
        lastPairError = nil
        return true
    }

    private static func probeIdentity(root: URL, challenge: LANIdentityProof.Challenge) async -> LANIdentityProof.Response? {
        guard let request = LANEndpointPolicy.identityRequest(root: root, challenge: challenge) else { return nil }
        // Nessun Authorization: la risposta deve provare la conoscenza del token.
        guard let (data, response) = try? await LANHTTPTransport.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LANIdentityProof.Response.self, from: data)
    }

    private func requestPairToken(_ root: URL, deviceName: String) async -> (token: String, macID: String)? {
        var req = URLRequest(url: root.appendingPathComponent("pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // 给 Mac 端点「允许」留足时间
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": deviceName])
        do {
            let (data, resp) = try await LANHTTPTransport.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String,
                  LANIdentityProof.usableSecret(token) != nil,
                  let macID = json["macID"] as? String, !macID.isEmpty,
                  !macID.contains("\0"), !macID.contains("::") else { return nil }
            return (token, macID)
        } catch { return nil }
    }
}
