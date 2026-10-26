import Foundation
import XCTest
@testable import PhoneClawCore

final class LANEndpointPolicyTests: XCTestCase {
    private let secret = "test-credential-known-only-to-the-paired-devices"
    private let macID = "mac-stable-identity"

    func testProofRequiresCorrectMacAndCredential() throws {
        let challenge = try XCTUnwrap(LANIdentityProof.challenge(secret: secret))
        let response = try XCTUnwrap(LANIdentityProof.response(to: challenge, macID: macID, secret: secret))
        XCTAssertTrue(LANIdentityProof.verifies(response, challenge: challenge, expectedMacID: macID, secret: secret))
        XCTAssertFalse(LANIdentityProof.verifies(response, challenge: challenge, expectedMacID: "another-mac", secret: secret))
        XCTAssertFalse(LANIdentityProof.verifies(response, challenge: challenge, expectedMacID: macID, secret: "another-secret"))
        let forged = LANIdentityProof.Response(macID: macID, proof: Data(repeating: 0, count: 32).base64EncodedString())
        XCTAssertFalse(LANIdentityProof.verifies(forged, challenge: challenge, expectedMacID: macID, secret: secret))
    }

    func testFreshNonceRejectsReplayedProof() throws {
        let first = try XCTUnwrap(LANIdentityProof.challenge(secret: secret))
        let second = try XCTUnwrap(LANIdentityProof.challenge(secret: secret))
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(Data(base64Encoded: first.nonce)?.count, 32)
        let response = try XCTUnwrap(LANIdentityProof.response(to: first, macID: macID, secret: secret))
        XCTAssertFalse(LANIdentityProof.verifies(response, challenge: second, expectedMacID: macID, secret: secret))
    }

    func testRejectsMalformedChallengeAndPlaceholderCredentials() throws {
        let valid = try XCTUnwrap(LANIdentityProof.challenge(secret: secret))
        for nonce in ["", "invalid base64!", Data(repeating: 1, count: 31).base64EncodedString()] {
            let invalid = LANIdentityProof.Challenge(credentialID: valid.credentialID, nonce: nonce)
            XCTAssertFalse(LANIdentityProof.validChallenge(invalid))
            XCTAssertNil(LANIdentityProof.response(to: invalid, macID: macID, secret: secret))
        }
        XCTAssertFalse(LANIdentityProof.validChallenge(.init(credentialID: "bad", nonce: valid.nonce)))
        XCTAssertNil(LANIdentityProof.challenge(secret: " "))
        XCTAssertNil(LANIdentityProof.challenge(secret: "(pending-handshake)"))
        XCTAssertNil(LANIdentityProof.response(to: valid, macID: "bad\0identity", secret: secret))
    }

    func testFreshDiscoveryPrecedesSavedIPAndDeduplicates() {
        let fresh = URL(string: "http://192.168.1.20:8080")!
        let saved = URL(string: "http://192.168.1.10:8080")!
        XCTAssertEqual(LANEndpointPolicy.candidates(discovered: [fresh, fresh], savedEndpoint: saved.absoluteString), [fresh, saved])
        XCTAssertEqual(LANEndpointPolicy.candidates(discovered: [URL(string: "HTTP://MAC.LOCAL:80/")!], savedEndpoint: "http://mac.local"), [URL(string: "http://mac.local")!])
    }

    func testInvalidRootsAndHTTPSDowngradeAreRejected() {
        for url in ["file:///tmp/gateway", "http://user:password@host", "http://host/v1", "http://host?token=x", "http://host/#redirect"] {
            XCTAssertNil(LANEndpointPolicy.root(URL(string: url)!))
        }
        XCTAssertEqual(LANEndpointPolicy.candidates(discovered: [URL(string: "http://new-host")!], savedEndpoint: "https://saved-host"), [URL(string: "https://saved-host")!])
        XCTAssertTrue(LANEndpointPolicy.candidates(discovered: [URL(string: "http://new-host")!], savedEndpoint: "https://saved-host?unexpected=x").isEmpty)
    }

    func testPreflightContainsNoBearerOrSecretInURLOrBody() throws {
        let challenge = try XCTUnwrap(LANIdentityProof.challenge(secret: secret))
        let request = try XCTUnwrap(LANEndpointPolicy.identityRequest(root: URL(string: "http://mac.local:8080")!, challenge: challenge))
        XCTAssertEqual(request.url?.absoluteString, "http://mac.local:8080/identity")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains(secret))
        XCTAssertEqual(try JSONDecoder().decode(LANIdentityProof.Challenge.self, from: XCTUnwrap(request.httpBody)), challenge)
    }

    func testValidFreshMacNeverContactsSavedAddress() async throws {
        let fresh = URL(string: "http://new-address:8080")!
        var visited: [URL] = []
        let root = await LANEndpointPolicy.verifiedRoot(discovered: [fresh], savedEndpoint: "http://old-address:8080", macID: macID, secret: secret) { url, challenge in
            visited.append(url)
            return LANIdentityProof.response(to: challenge, macID: self.macID, secret: self.secret)
        }
        XCTAssertEqual(root, fresh)
        XCTAssertEqual(visited, [fresh])
    }

    func testUnreachableDiscoveryCanUseOnlyVerifiedSavedEndpoint() async {
        let saved = URL(string: "http://saved-address:8080")!
        var visited: [URL] = []
        let result = await LANEndpointPolicy.verifiedRoot(discovered: [URL(string: "http://offline-address:8080")!], savedEndpoint: saved.absoluteString, macID: macID, secret: secret) { url, challenge in
            visited.append(url)
            guard url == saved else { return nil }
            return LANIdentityProof.response(to: challenge, macID: self.macID, secret: self.secret)
        }
        XCTAssertEqual(result, saved)
        XCTAssertEqual(visited.count, 2)
    }

    func testWrongHostNeverPassesAuthorizationGate() async {
        var probeCount = 0
        var authenticatedRequestCount = 0
        let result = await LANEndpointPolicy.verifiedRoot(discovered: [URL(string: "http://new-address")!], savedEndpoint: "http://reassigned-old-address", macID: macID, secret: secret) { _, challenge in
            probeCount += 1
            // Anche una prova autentica di un altro Mac non autorizza il binding.
            return LANIdentityProof.response(to: challenge, macID: "other-mac", secret: self.secret)
        }
        if result != nil { authenticatedRequestCount += 1 }
        XCTAssertNil(result)
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(authenticatedRequestCount, 0)
    }

    func testMissingCredentialDoesNotProbeNetwork() async {
        var called = false
        let result = await LANEndpointPolicy.verifiedRoot(discovered: [URL(string: "http://mac")!], savedEndpoint: nil, macID: macID, secret: "(pending-handshake)") { _, _ in
            called = true
            return nil
        }
        XCTAssertNil(result)
        XCTAssertFalse(called)
    }

    func testUnpairDuringProbeRejectsEvenAnAuthenticProofAndStopsFallback() async {
        var stillPaired = true
        var probeCount = 0
        let result = await LANEndpointPolicy.verifiedRoot(
            discovered: [URL(string: "http://new-address")!], savedEndpoint: "http://saved-address",
            macID: macID, secret: secret, isCurrent: { stillPaired }
        ) { _, challenge in
            probeCount += 1
            // Simula la risposta sospesa mentre l'utente rimuove l'associazione.
            await Task.yield()
            stillPaired = false
            return LANIdentityProof.response(to: challenge, macID: self.macID, secret: self.secret)
        }
        XCTAssertNil(result)
        XCTAssertEqual(probeCount, 1)
    }

    func testNewPairingRevisionInvalidatesAnOlderSuccessfulProbe() async {
        let originalRevision = UUID()
        var currentRevision = originalRevision
        let result = await LANEndpointPolicy.verifiedRoot(
            discovered: [URL(string: "http://mac-address")!], savedEndpoint: nil,
            macID: macID, secret: secret, isCurrent: { currentRevision == originalRevision }
        ) { _, challenge in
            await Task.yield()
            currentRevision = UUID()
            return LANIdentityProof.response(to: challenge, macID: self.macID, secret: self.secret)
        }
        XCTAssertNil(result)
    }

    func testStaleBindingDoesNotStartIdentityProbe() async {
        var probed = false
        let result = await LANEndpointPolicy.verifiedRoot(
            discovered: [URL(string: "http://mac-address")!], savedEndpoint: nil,
            macID: macID, secret: secret, isCurrent: { false }
        ) { _, _ in
            probed = true
            return nil
        }
        XCTAssertNil(result)
        XCTAssertFalse(probed)
    }

    func testRedirectDelegateRejectsCrossHostAndDowngrade() {
        let delegate = LANNoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://mac.local/models")!)
        let response = HTTPURLResponse(url: URL(string: "https://mac.local/models")!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        for target in ["https://other-host/models", "http://mac.local/models", "https://mac.local/new-path"] {
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { redirected in
                called = true
                XCTAssertNil(redirected)
            }
            XCTAssertTrue(called)
        }
    }
}
