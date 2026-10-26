import XCTest
@testable import PhoneClawCore

final class ToolConfirmationStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func request(sessionID: UUID = UUID(), turnID: UUID = UUID()) -> ToolConfirmationRequest {
        ToolConfirmationRequest(
            id: UUID(), sessionID: sessionID, turnID: turnID,
            toolName: "contacts-delete", argumentsJSON: #"{"identifier":"synthetic-contact"}"#,
            title: "Confirm", message: "Delete synthetic contact", isDestructive: true,
            createdAt: now, expiresAt: now.addingTimeInterval(120)
        )
    }

    func testApprovalIsConsumedOnceAndKeepsTheReviewedArguments() {
        var state = ToolConfirmationState()
        let operation = request()
        XCTAssertTrue(state.begin(operation))
        XCTAssertEqual(state.pending?.argumentsJSON, operation.argumentsJSON)
        XCTAssertEqual(state.resolve(id: operation.id, approved: true, sessionID: operation.sessionID, turnID: operation.turnID, now: now), true)
        XCTAssertNil(state.resolve(id: operation.id, approved: true, sessionID: operation.sessionID, turnID: operation.turnID, now: now))
        XCTAssertNil(state.pending)
    }

    func testApprovalCannotMoveToAnotherConversationOrTurn() {
        let operation = request()
        var changedSession = ToolConfirmationState()
        XCTAssertTrue(changedSession.begin(operation))
        XCTAssertEqual(changedSession.resolve(id: operation.id, approved: true, sessionID: UUID(), turnID: operation.turnID, now: now), false)
        var changedTurn = ToolConfirmationState()
        XCTAssertTrue(changedTurn.begin(operation))
        XCTAssertEqual(changedTurn.resolve(id: operation.id, approved: true, sessionID: operation.sessionID, turnID: UUID(), now: now), false)
    }

    func testExpiredApprovalCannotExecute() {
        let operation = request()
        var state = ToolConfirmationState()
        XCTAssertTrue(state.begin(operation))
        XCTAssertEqual(state.resolve(id: operation.id, approved: true, sessionID: operation.sessionID, turnID: operation.turnID, now: operation.expiresAt), false)
        XCTAssertNil(state.pending)
    }

    func testStaleDialogAndTimeoutCannotConsumeANewerRequest() {
        let old = request()
        let current = request()
        var state = ToolConfirmationState()
        XCTAssertTrue(state.begin(old))
        XCTAssertEqual(state.cancel()?.id, old.id)
        XCTAssertTrue(state.begin(current))
        XCTAssertNil(state.resolve(id: old.id, approved: true, sessionID: current.sessionID, turnID: current.turnID, now: now))
        XCTAssertNil(state.cancel(id: old.id))
        XCTAssertEqual(state.pending, current)
    }

    func testCancellationAndRejectionNeverGrantPermission() {
        let operation = request()
        var state = ToolConfirmationState()
        XCTAssertTrue(state.begin(operation))
        XCTAssertEqual(state.resolve(id: operation.id, approved: false, sessionID: operation.sessionID, turnID: operation.turnID, now: now), false)
        XCTAssertTrue(state.begin(operation))
        state.cancel()
        XCTAssertNil(state.resolve(id: operation.id, approved: true, sessionID: operation.sessionID, turnID: operation.turnID, now: now))
    }

    func testConcurrentOperationCannotReplaceTheVisibleConfirmation() {
        let first = request()
        var state = ToolConfirmationState()
        XCTAssertTrue(state.begin(first))
        XCTAssertFalse(state.begin(request()))
        XCTAssertEqual(state.pending, first)
    }

    func testNativeWritesCannotBeDowngradedBySkillMetadata() {
        for name in ["contacts-delete", "contacts-upsert", "calendar-create-event", "reminders-create", "clipboard-write"] {
            XCTAssertTrue(ToolConfirmationPolicy.requiresConfirmation(toolName: name, declaredLevel: "read", requiresExplicitIntent: false, confirmation: "never"), name)
        }
        XCTAssertTrue(ToolConfirmationPolicy.isDestructive(toolName: "contacts-delete", declaredLevel: "read"))
    }

    func testReadOnlyToolsRemainUsableWithoutConfirmation() {
        for name in ["contacts-search", "calendar-query-events", "clipboard-read", "health-query", "web-search"] {
            XCTAssertFalse(ToolConfirmationPolicy.requiresConfirmation(toolName: name, declaredLevel: "read", requiresExplicitIntent: false, confirmation: "never"), name)
        }
        XCTAssertTrue(ToolConfirmationPolicy.requiresConfirmation(toolName: "future-tool", declaredLevel: "read", requiresExplicitIntent: true, confirmation: "never"))
        XCTAssertTrue(ToolConfirmationPolicy.requiresConfirmation(toolName: "future-tool", declaredLevel: "write", requiresExplicitIntent: false, confirmation: "never"))
    }
}
