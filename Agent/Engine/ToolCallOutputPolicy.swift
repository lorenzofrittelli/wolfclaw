import Foundation

enum ToolCallOutputPolicy {
    /// Il contenuto generato è dato non fidato. Una richiesta invalida non deve
    /// diventare una chiamata inventata né sparire dietro una bolla vuota.
    static func hasRejectedRequest(_ text: String, acceptedCallCount: Int) -> Bool {
        guard acceptedCallCount == 0 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un tag citato nel testo o un esempio JSON non sono un protocollo.
        // L'errore riguarda solo l'envelope iniziale, anche se troncato nel JSON.
        return trimmed.range(
            of: #"^<(?:tool_call|function_call)>\s*(?:\{|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
