import XCTest
import Network
@testable import PhoneClawGateway

final class GatewayListenModeTests: XCTestCase {
    func testLoopbackBindsOnlyIPv4LocalhostAndDisablesBonjour() throws {
        let mode = GatewayListenMode.loopbackOnly
        let parameters = try mode.listenerParameters(port: 18080)
        guard case .hostPort(let host, let port) = parameters.requiredLocalEndpoint else {
            return XCTFail("La modalità Tailscale deve fissare un endpoint locale")
        }
        XCTAssertEqual(host, NWEndpoint.Host("127.0.0.1"))
        XCTAssertEqual(port.rawValue, 18080)
        XCTAssertFalse(mode.advertisesBonjour)
    }

    func testLegacyLANModePreservesDiscovery() throws {
        XCTAssertNil(try GatewayListenMode.lan.listenerParameters(port: 18080).requiredLocalEndpoint)
        XCTAssertTrue(GatewayListenMode.lan.advertisesBonjour)
        XCTAssertEqual(GatewayListenMode.stored(nil), .lan)
    }

    func testStoredModeRoundTripsAndUnknownValueFailsClosed() {
        XCTAssertEqual(GatewayListenMode.stored("loopbackOnly"), .loopbackOnly)
        XCTAssertEqual(GatewayListenMode.stored("lan"), .lan)
        XCTAssertEqual(GatewayListenMode.stored("invalid"), .loopbackOnly)
        XCTAssertEqual(GatewayListenMode.stored(""), .loopbackOnly)
    }

    func testPortZeroIsRejectedInBothModes() {
        for mode in GatewayListenMode.allCases {
            XCTAssertThrowsError(try mode.listenerParameters(port: 0))
        }
    }

    func testPairingRequiresAnExplicitApprovalCallback() async {
        let result = await GatewayPairApprovalPolicy.approve(deviceName: "iPhone", using: nil)
        XCTAssertFalse(result)
    }

    func testPairingPreservesApprovalAndDenial() async {
        let approved = await GatewayPairApprovalPolicy.approve(deviceName: "iPhone") { $0 == "iPhone" }
        let denied = await GatewayPairApprovalPolicy.approve(deviceName: "iPhone") { _ in false }
        XCTAssertTrue(approved)
        XCTAssertFalse(denied)
    }
}
