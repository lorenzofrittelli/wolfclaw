import XCTest
@testable import PhoneClawCore

final class ToolCallOutputPolicyTests: XCTestCase {
    func testRejectedLoadSkillAndTruncatedEnvelopeSurfaceFailure() {
        XCTAssertTrue(ToolCallOutputPolicy.hasRejectedRequest("<tool_call>{\"name\":\"load_skill\",\"arguments\":{\"skill\":\"load_skill\"}}</tool_call>", acceptedCallCount: 0))
        XCTAssertTrue(ToolCallOutputPolicy.hasRejectedRequest("<tool_call>{\"name\":", acceptedCallCount: 0))
    }

    func testAcceptedToolStillUsesValidatedExecutionPath() {
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("<tool_call>{}</tool_call>", acceptedCallCount: 1))
    }

    func testPlainTextAndOrdinaryJSONAreNotToolRequests() {
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("Good morning!", acceptedCallCount: 0))
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("{\"name\":\"Alice\",\"age\":42}", acceptedCallCount: 0))
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("```json\n{\"name\":\"Alice\",\"arguments\":[]}\n```", acceptedCallCount: 0))
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("Il tag <tool_call> contiene una richiesta.", acceptedCallCount: 0))
        XCTAssertFalse(ToolCallOutputPolicy.hasRejectedRequest("`<tool_call>{}</tool_call>` è un esempio.", acceptedCallCount: 0))
    }
}
