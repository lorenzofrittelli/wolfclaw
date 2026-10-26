import XCTest
import Foundation
import Darwin
@testable import PhoneClawGateway

final class GatewayLoopbackIntegrationTests: XCTestCase {
    func testRealLoopbackListenerDeniesRequestsWithoutCredentialsOrApproval() async throws {
        let port = try unusedLoopbackPort()
        let ready = expectation(description: "Listener locale pronto")
        let gateway = makeGateway(port: port, ready: ready)
        try gateway.start()
        defer { gateway.stop() }
        await fulfillment(of: [ready], timeout: 5)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let models = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        let (modelData, modelResponse) = try await session.data(for: models)
        XCTAssertEqual((modelResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(try errorBody(modelData), "Unauthorized")

        let (pairData, pairResponse) = try await session.data(for: pairRequest(port: port, name: "iPhone test senza approvazione"))
        XCTAssertEqual((pairResponse as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(try errorBody(pairData), "Pairing denied")
        XCTAssertTrue(gateway.pairedDevicesSnapshot().isEmpty)
    }

    func testURLSessionBodyReachesApprovalAndExplicitDenialCreatesNoToken() async throws {
        let port = try unusedLoopbackPort()
        let ready = expectation(description: "Listener locale pronto")
        let bodyReceived = expectation(description: "Nome JSON ricevuto senza alterazioni")
        let deviceName = "iPhone prova è · \"locale\""
        let gateway = makeGateway(port: port, ready: ready) { name in
            XCTAssertEqual(name, deviceName)
            bodyReceived.fulfill()
            return false
        }
        try gateway.start()
        defer { gateway.stop() }
        await fulfillment(of: [ready], timeout: 5)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: pairRequest(port: port, name: deviceName))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertEqual(try errorBody(data), "Pairing denied")
        await fulfillment(of: [bodyReceived], timeout: 2)
        XCTAssertTrue(gateway.pairedDevicesSnapshot().isEmpty)
    }

    private func makeGateway(
        port: UInt16,
        ready: XCTestExpectation,
        approval: (@Sendable (String) async -> Bool)? = nil
    ) -> MacGateway {
        MacGateway(
            port: port, macID: "integration-\(UUID().uuidString)", name: "Gateway test locale",
            providers: [], defaultProviderID: "unused", listenMode: .loopbackOnly,
            onPairRequest: approval,
            onRuntimeEvent: { event in
                if event == "Tailscale · locale 127.0.0.1:\(port)" {
                    ready.fulfill()
                } else if event.hasPrefix("启动失败") {
                    XCTFail("Listener non disponibile: \(event)")
                    ready.fulfill()
                }
            }
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }

    private func pairRequest(port: UInt16, name: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        return request
    }

    private func errorBody(_ data: Data) throws -> String? {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(body["token"])
        return body["error"] as? String
    }

    /// Il sistema sceglie una porta effimera; il test non usa mai la porta del gateway reale.
    private func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EIO) }
        let port = UInt16(bigEndian: address.sin_port)
        guard port != 0, port != 18080 else { throw POSIXError(.EADDRINUSE) }
        return port
    }
}
