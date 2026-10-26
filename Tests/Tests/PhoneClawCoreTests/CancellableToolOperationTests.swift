import XCTest
@testable import PhoneClawCore

@MainActor
final class CancellableToolOperationTests: XCTestCase {
    func testStopCancelsTheOwnedTaskDuringSystemPermissionWait() async {
        let permission = SuspendedPermissionWrite()
        var ownedTask: Task<Void, Never>?
        let caller = Task {
            await CancellableToolOperation.run(register: { ownedTask = $0 }) {
                await permission.execute()
            }
        }
        await permission.waitUntilRequested()
        XCTAssertNotNil(ownedTask)
        ownedTask?.cancel()
        // Il consenso del sistema arriva dopo Stop: non deve più causare commit.
        permission.allow()
        let result = await caller.value
        XCTAssertNil(result)
        XCTAssertEqual(permission.commits, 0)
    }

    func testCancellationOfTheCallerAlsoCancelsTheNativeOperation() async {
        let permission = SuspendedPermissionWrite()
        let caller = Task {
            await CancellableToolOperation.run(register: { _ in }) {
                await permission.execute()
            }
        }
        await permission.waitUntilRequested()
        caller.cancel()
        permission.allow()
        let result = await caller.value
        XCTAssertNil(result)
        XCTAssertEqual(permission.commits, 0)
    }

    func testTaskIsRegisteredBeforeTheOperationStarts() async {
        var started = false
        let result = await CancellableToolOperation.run(register: { $0.cancel() }) {
            started = true
            return true
        }
        XCTAssertFalse(started)
        XCTAssertNil(result)
    }

    func testApprovedUncancelledOperationRetainsItsResult() async {
        let permission = SuspendedPermissionWrite()
        let caller = Task {
            await CancellableToolOperation.run(register: { _ in }) {
                await permission.execute()
            }
        }
        await permission.waitUntilRequested()
        permission.allow()
        let result = await caller.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(permission.commits, 1)
    }

    func testMainGenerationRechecksOwnershipAfterPlannerFallbackWithoutAnotherSuspension() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Agent/Engine/ProcessInput.swift"), encoding: .utf8)
        let fallback = try XCTUnwrap(source.range(of: "planner not handled, falling back to single-skill agent path"))
        let generation = try XCTUnwrap(source.range(of: "inference.generate(", range: fallback.upperBound..<source.endIndex))
        let boundary = String(source[fallback.upperBound..<generation.lowerBound])

        // Il risultato potrebbe essere già stato consegnato prima di Stop:
        // il controllo del solo task figlio non protegge questo secondo avvio.
        XCTAssertTrue(boundary.contains("guard !Task.isCancelled,"))
        XCTAssertTrue(boundary.contains("isCurrentTurnOwner(turnContext)"))
        XCTAssertTrue(boundary.contains("!transaction.isTerminal"))
        XCTAssertTrue(boundary.contains("transaction.state != .cancelling else { return }"))
        let guardStart = try XCTUnwrap(boundary.range(of: "guard !Task.isCancelled,"))
        let checkedBoundary = boundary[guardStart.lowerBound...]
        XCTAssertFalse(checkedBoundary.contains("await "), "Una sospensione riaprirebbe la finestra tra verifica e avvio")
        XCTAssertTrue(checkedBoundary.contains("markStreamingStarted(context: turnContext)"))
    }
}

/// Simula una richiesta TCC non cancellabile e il controllo nativo prima del salvataggio.
@MainActor
private final class SuspendedPermissionWrite {
    private var permission: CheckedContinuation<Void, Never>?
    private var requestObserver: CheckedContinuation<Void, Never>?
    private var requested = false
    private(set) var commits = 0

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestObserver = $0 }
    }

    func execute() async -> Bool {
        await withCheckedContinuation { continuation in
            permission = continuation
            requested = true
            requestObserver?.resume()
            requestObserver = nil
        }
        do { try Task.checkCancellation() } catch { return false }
        commits += 1
        return true
    }

    func allow() {
        permission?.resume()
        permission = nil
    }
}
