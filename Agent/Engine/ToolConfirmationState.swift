import Foundation

/// Una conferma autorizza solo questa operazione, in questa sessione e in questo turno.
struct ToolConfirmationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let turnID: UUID?
    let toolName: String
    let argumentsJSON: String
    let title: String
    let message: String
    let isDestructive: Bool
    let createdAt: Date
    let expiresAt: Date
}

struct ToolConfirmationState {
    private(set) var pending: ToolConfirmationRequest?

    mutating func begin(_ request: ToolConfirmationRequest) -> Bool {
        guard pending == nil else { return false }
        pending = request
        return true
    }

    /// nil indica una risposta obsoleta: non deve consumare una richiesta più recente.
    mutating func resolve(
        id: UUID,
        approved: Bool,
        sessionID: UUID,
        turnID: UUID?,
        now: Date = Date()
    ) -> Bool? {
        guard let request = pending, request.id == id else { return nil }
        pending = nil
        return approved
            && request.sessionID == sessionID
            && request.turnID == turnID
            && now < request.expiresAt
    }

    @discardableResult
    mutating func cancel(id: UUID? = nil) -> ToolConfirmationRequest? {
        guard let request = pending, id == nil || id == request.id else { return nil }
        pending = nil
        return request
    }
}

enum ToolConfirmationPolicy {
    /// La policy modificabile della skill non può declassare le scritture native.
    private static let nativeWrites: Set<String> = [
        "contacts-upsert", "contacts-delete", "calendar-create-event",
        "reminders-create", "clipboard-write"
    ]

    static func isDestructive(toolName: String, declaredLevel: String) -> Bool {
        toolName == "contacts-delete" || declaredLevel == "destructive"
    }

    static func requiresConfirmation(
        toolName: String,
        declaredLevel: String,
        requiresExplicitIntent: Bool,
        confirmation: String
    ) -> Bool {
        nativeWrites.contains(toolName)
            || declaredLevel == "write"
            || declaredLevel == "destructive"
            || requiresExplicitIntent
            || confirmation == "always"
    }
}

/// Registra il task prima dell'esecuzione e non restituisce risultati cancellati.
/// Il planner attraversa attese di consenso TCC: cancellare solo il motore LLM
/// non interrompe quelle attese e non impedisce una successiva scrittura nativa.
enum CancellableToolOperation {
    @MainActor
    static func run<Value: Sendable>(
        register: (Task<Void, Never>) -> Void,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let cancellation = ToolOperationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = Task { @MainActor in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let result = await operation()
                    continuation.resume(returning: Task.isCancelled ? nil : result)
                }
                cancellation.install(task)
                register(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// La cancellazione del chiamante può arrivare anche prima della registrazione.
private final class ToolOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var wasCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let cancelImmediately = wasCancelled
        lock.unlock()
        if cancelImmediately { task.cancel() }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
