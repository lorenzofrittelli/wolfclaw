import Foundation
import CryptoKit

enum MacBindingTransport: String, Codable, Sendable {
    case lan
    case tailscale

    static func permitsReplacement(existing: MacBindingTransport?, proposed: MacBindingTransport) -> Bool {
        existing != .tailscale || proposed == .tailscale
    }
}

/// I dati del binding sono indipendenti dalla rete; le credenziali persistenti restano nel Keychain.
struct MacBinding: Codable, Equatable, Sendable {
    let macID: String
    var name: String
    var secret: String
    var boundAt: Date
    var endpoint: String? = nil
    var transport: MacBindingTransport = .lan

    private enum CodingKeys: String, CodingKey {
        case macID, name, secret, boundAt, endpoint, transport
    }
}

extension MacBinding {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        macID = try values.decode(String.self, forKey: .macID)
        name = try values.decode(String.self, forKey: .name)
        secret = try values.decode(String.self, forKey: .secret)
        boundAt = try values.decode(Date.self, forKey: .boundAt)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint)
        // Solo i documenti precedenti senza il campo usano LAN; un valore sconosciuto fallisce.
        transport = values.contains(.transport)
            ? try values.decode(MacBindingTransport.self, forKey: .transport) : .lan
    }
}

/// Verifica il possesso della credenziale prima di inviarla a un indirizzo LAN.
/// Non cifra HTTP e non sostituisce TLS: un relay attivo resta fuori da questa garanzia.
enum LANIdentityProof {
    struct Challenge: Codable, Equatable, Sendable {
        let credentialID: String
        let nonce: String
    }

    struct Response: Codable, Equatable, Sendable {
        let macID: String
        let proof: String
    }

    static func usableSecret(_ secret: String) -> String? {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "(pending-handshake)" ? nil : value
    }

    static func credentialID(secret: String) -> String {
        SHA256.hash(data: Data(("phoneclaw.identity.credential.v1\0" + secret).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func challenge(secret: String) -> Challenge? {
        guard let secret = usableSecret(secret) else { return nil }
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        return Challenge(credentialID: credentialID(secret: secret), nonce: nonce)
    }

    static func validChallenge(_ challenge: Challenge) -> Bool {
        challenge.credentialID.count == 64
            && challenge.credentialID.allSatisfy { "0123456789abcdef".contains($0) }
            && Data(base64Encoded: challenge.nonce)?.count == 32
    }

    static func response(to challenge: Challenge, macID: String, secret: String) -> Response? {
        guard !macID.isEmpty, !macID.contains("\0"), validChallenge(challenge),
              let secret = usableSecret(secret),
              challenge.credentialID == credentialID(secret: secret) else { return nil }
        let authentication = HMAC<SHA256>.authenticationCode(
            for: message(macID: macID, nonce: challenge.nonce),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return Response(macID: macID, proof: Data(authentication).base64EncodedString())
    }

    static func verifies(_ response: Response, challenge: Challenge, expectedMacID: String, secret: String) -> Bool {
        guard response.macID == expectedMacID, !expectedMacID.isEmpty,
              !expectedMacID.contains("\0"), validChallenge(challenge),
              let secret = usableSecret(secret),
              challenge.credentialID == credentialID(secret: secret),
              let proof = Data(base64Encoded: response.proof) else { return false }
        // CryptoKit verifica il codice senza confronto String dipendente dal prefisso.
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: message(macID: expectedMacID, nonce: challenge.nonce),
            using: SymmetricKey(data: Data(secret.utf8))
        )
    }

    private static func message(macID: String, nonce: String) -> Data {
        Data(("phoneclaw.gateway.identity.v1\0" + macID + "\0" + nonce).utf8)
    }
}

enum LANEndpointPolicy {
    /// Serve usa un'origine HTTPS esplicita; niente credenziali URL, percorsi API o host simili.
    static func tailscaleRoot(_ endpoint: String) -> URL? {
        let clean = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains("%"), let url = URL(string: clean), let root = root(url),
              root.scheme == "https", let host = root.host,
              host.hasSuffix(".ts.net"), host.count <= 253,
              let parts = URLComponents(url: root, resolvingAgainstBaseURL: false),
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return root
    }

    static func root(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url
    }

    static func candidates(discovered: [URL], savedEndpoint: String?, transport: MacBindingTransport = .lan) -> [URL] {
        if transport == .tailscale {
            // L'endpoint Tailscale è fissato dall'utente: nessun risultato Bonjour entra nei candidati.
            return savedEndpoint.flatMap(tailscaleRoot).map { [$0] } ?? []
        }
        let savedURL = savedEndpoint.flatMap(URL.init(string:))
        let saved = savedURL.flatMap(root)
        // Una futura configurazione HTTPS non deve tornare a HTTP tramite Bonjour.
        let requiresHTTPS = savedURL?.scheme?.lowercased() == "https"
        var seen = Set<URL>()
        return (discovered + [saved].compactMap { $0 }).compactMap { candidate in
            guard let root = root(candidate), !requiresHTTPS || root.scheme == "https",
                  seen.insert(root).inserted else { return nil }
            return root
        }
    }

    static func identityRequest(root: URL, challenge: LANIdentityProof.Challenge) -> URLRequest? {
        guard let root = self.root(root), LANIdentityProof.validChallenge(challenge),
              let body = try? JSONEncoder().encode(challenge) else { return nil }
        var request = URLRequest(url: root.appendingPathComponent("identity"))
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Il probe riceve solo sfida e URL, mai la credenziale Bearer.
    static func verifiedRoot(
        discovered: [URL], savedEndpoint: String?, macID: String, secret: String,
        transport: MacBindingTransport = .lan,
        isCurrent: () -> Bool = { true },
        probe: (URL, LANIdentityProof.Challenge) async -> LANIdentityProof.Response?
    ) async -> URL? {
        guard isCurrent(), LANIdentityProof.usableSecret(secret) != nil else { return nil }
        for root in candidates(discovered: discovered, savedEndpoint: savedEndpoint, transport: transport) {
            guard !Task.isCancelled, isCurrent(),
                  let challenge = LANIdentityProof.challenge(secret: secret) else { return nil }
            let response = await probe(root, challenge)
            // Unpair o nuova associazione durante il probe invalidano anche una prova HMAC autentica.
            guard !Task.isCancelled, isCurrent() else { return nil }
            guard let response,
                  LANIdentityProof.verifies(response, challenge: challenge, expectedMacID: macID, secret: secret) else { continue }
            return root
        }
        return nil
    }
}

/// Nessuna richiesta LAN viene ripetuta verso un redirect, neppure sullo stesso host.
/// Evita sia il downgrade HTTPS sia l'inoltro di credenziali o prompt a un altro servizio.
final class LANNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LANHTTPTransport {
    static let session = makeSession()

    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: LANNoRedirectDelegate(), delegateQueue: nil)
    }
}
