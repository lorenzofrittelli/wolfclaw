import Foundation

/// Conserva la richiesta che ha prodotto un risultato e i turni recenti che la spiegano.
/// I messaggi sono dati storici: la richiesta attuale viene esclusa per identità.
enum PriorContextPolicy {
    struct Message {
        enum Role { case user, assistant, other }
        let id: UUID
        let role: Role
        let content: String
    }

    private struct Turn {
        let user: String
        var answers: [String] = []
    }

    static func context(
        from messages: [Message],
        through sourceMessageID: UUID,
        excluding currentUserID: UUID?,
        maxTurns: Int = 3,
        maxCharacters: Int = 2_200
    ) -> String {
        guard maxTurns > 0, maxCharacters > 0,
              let sourceIndex = messages.firstIndex(where: { $0.id == sourceMessageID }) else { return "" }
        if let currentUserID,
           let currentIndex = messages.firstIndex(where: { $0.id == currentUserID }),
           sourceIndex >= currentIndex { return "" }

        var turns: [Turn] = []
        for message in messages[...sourceIndex] {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case .user:
                turns.append(Turn(user: content))
            case .assistant:
                if !turns.isEmpty, !content.isEmpty { turns[turns.count - 1].answers.append(content) }
            case .other:
                break
            }
        }

        var selected: [String] = []
        var remaining = maxCharacters
        // Prima si riserva spazio alla richiesta d'origine; i turni più vecchi usano il residuo.
        for turn in turns.suffix(maxTurns).reversed() {
            let separatorCost = selected.isEmpty ? 0 : 2
            let available = remaining - separatorCost
            guard available >= 64 else { break }
            let rendered = render(turn, maxCharacters: available)
            guard !rendered.isEmpty else { break }
            selected.append(rendered)
            remaining -= rendered.count + separatorCost
        }
        return selected.reversed().joined(separator: "\n\n")
    }

    static func summary(context: String, result: String, maxCharacters: Int) -> String {
        guard !context.isEmpty else { return clipped(result, maxCharacters: maxCharacters) }
        guard maxCharacters >= 64 else { return clipped(context, maxCharacters: maxCharacters) }
        let contextBudget = max(0, maxCharacters * 2 / 3)
        let contextText = clipped(context, maxCharacters: contextBudget)
        let resultLabel = "\n\nResult:\n"
        return contextText + resultLabel
            + clipped(result, maxCharacters: max(0, maxCharacters - contextText.count - resultLabel.count))
    }

    private static func render(_ turn: Turn, maxCharacters: Int) -> String {
        let userLabel = "User request:\n"
        let answerLabel = "\nAssistant answer:\n"
        let answer = turn.answers.joined(separator: "\n")
        guard !answer.isEmpty else {
            return userLabel + clipped(turn.user, maxCharacters: maxCharacters - userLabel.count)
        }
        let contentBudget = max(0, maxCharacters - userLabel.count - answerLabel.count)
        // Una risposta molto lunga non deve espellere la domanda alla quale rispondeva.
        let userBudget = min(turn.user.count, max(contentBudget * 2 / 3, contentBudget - answer.count))
        let user = clipped(turn.user, maxCharacters: userBudget)
        return userLabel + user + answerLabel
            + clipped(answer, maxCharacters: contentBudget - user.count)
    }

    private static func clipped(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        let marker = "\n[…]\n"
        guard maxCharacters > marker.count else { return String(text.prefix(maxCharacters)) }
        let available = maxCharacters - marker.count
        let prefixCount = (available + 1) / 2
        return String(text.prefix(prefixCount)) + marker + String(text.suffix(available - prefixCount))
    }
}
