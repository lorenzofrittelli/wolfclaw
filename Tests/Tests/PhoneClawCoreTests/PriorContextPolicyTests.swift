import XCTest
@testable import PhoneClawCore

final class PriorContextPolicyTests: XCTestCase {
    private func message(_ role: PriorContextPolicy.Message.Role, _ content: String) -> PriorContextPolicy.Message {
        .init(id: UUID(), role: role, content: content)
    }

    func testShortAcknowledgementRetainsOriginalUserFactsAndExcludesCurrentRequest() {
        let original = message(.user, "Il codice della prenotazione è LUNA-42. Rispondi solo ricevuto.")
        let answer = message(.assistant, "Ricevuto.")
        let current = message(.user, "Qual è il codice della prenotazione?")
        let context = PriorContextPolicy.context(
            from: [original, answer, current], through: answer.id, excluding: current.id
        )

        XCTAssertTrue(context.contains("User request:\n\(original.content)"))
        XCTAssertTrue(context.contains("Assistant answer:\nRicevuto."))
        XCTAssertFalse(context.contains(current.content))
    }

    func testFollowUpKeepsRecentUserAssistantPairsInChronologicalOrder() {
        let first = message(.user, "Visita il museo sabato alle 14.")
        let firstAnswer = message(.assistant, "Aggiunto al programma.")
        let second = message(.user, "Sposta quella visita a domenica.")
        let secondAnswer = message(.assistant, "Programma aggiornato.")
        let current = message(.user, "A che ora e in quale giorno?")
        let context = PriorContextPolicy.context(
            from: [first, firstAnswer, second, secondAnswer, current],
            through: secondAnswer.id, excluding: current.id
        )

        let texts = [first.content, firstAnswer.content, second.content, secondAnswer.content]
        let positions = texts.compactMap { context.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, texts.count)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertFalse(context.contains(current.content))
    }

    func testToolArtifactRetainsItsRequestWithoutInjectingToolInstructions() {
        let instruction = message(.other, "INTERNAL SKILL INSTRUCTION")
        let original = message(.user, "Cerca il meteo per Torino domani.")
        let toolResult = message(.other, "TOOL RESULT supplied in separate artifact detail")
        let laterAnswer = message(.assistant, "Risposta successiva all'artifact.")
        let current = message(.user, "Spiegalo.")
        let context = PriorContextPolicy.context(
            from: [instruction, original, toolResult, laterAnswer, current],
            through: toolResult.id, excluding: current.id
        )

        XCTAssertTrue(context.contains(original.content))
        XCTAssertFalse(context.contains(instruction.content))
        XCTAssertFalse(context.contains(toolResult.content))
        XCTAssertFalse(context.contains(laterAnswer.content))
        XCTAssertFalse(context.contains(current.content))
    }

    func testTurnLimitDropsOldestTurnsWithoutOrphaningTheRetainedRequest() {
        let turns = (1...4).flatMap { index in
            [message(.user, "Richiesta \(index)"), message(.assistant, "Risposta \(index)")]
        }
        let current = message(.user, "Riepiloga.")
        let context = PriorContextPolicy.context(
            from: turns + [current], through: turns.last!.id, excluding: current.id, maxTurns: 2
        )

        XCTAssertFalse(context.contains("Richiesta 2"))
        XCTAssertFalse(context.contains("Risposta 2"))
        for text in ["Richiesta 3", "Risposta 3", "Richiesta 4", "Risposta 4"] {
            XCTAssertTrue(context.contains(text))
        }
    }

    func testBudgetPreservesBothEndsOfOriginAndSomeAnswerWithUnicode() {
        let original = message(.user, "INIZIO " + String(repeating: "猫🌍", count: 800) + " FINE")
        let answer = message(.assistant, "RISPOSTA " + String(repeating: "字", count: 1_000) + " ULTIMA")
        let current = message(.user, "La domanda attuale non va duplicata.")
        let context = PriorContextPolicy.context(
            from: [original, answer, current], through: answer.id, excluding: current.id,
            maxCharacters: 300
        )

        XCTAssertLessThanOrEqual(context.count, 300)
        for text in ["INIZIO", "FINE", "RISPOSTA", "ULTIMA", "[…]"] {
            XCTAssertTrue(context.contains(text))
        }
        XCTAssertFalse(context.contains(current.content))
    }

    func testUnknownSourceAndCurrentOrFutureSourceCannotLeakIntoHistory() {
        let original = message(.user, "Contenuto storico")
        let current = message(.user, "Nuova richiesta")
        let future = message(.assistant, "Placeholder corrente")
        for id in [UUID(), current.id, future.id] {
            XCTAssertEqual(PriorContextPolicy.context(
                from: [original, current, future], through: id, excluding: current.id
            ), "")
        }
    }

    func testClassifierSummaryIncludesSourceRequestAndResultWithinBudget() {
        let original = message(.user, "Il documento si chiama contratto.pdf.")
        let answer = message(.assistant, "OK")
        let context = PriorContextPolicy.context(from: [original, answer], through: answer.id, excluding: nil)
        let summary = PriorContextPolicy.summary(context: context, result: "OK", maxCharacters: 1_200)
        XCTAssertTrue(summary.contains("contratto.pdf"))
        XCTAssertTrue(summary.contains("Result:\nOK"))
        XCTAssertLessThanOrEqual(summary.count, 1_200)
        XCTAssertEqual(PriorContextPolicy.summary(context: "", result: "Risultato", maxCharacters: 1_200), "Risultato")
        for budget in [0, 1, 63, 64, 100] {
            XCTAssertLessThanOrEqual(PriorContextPolicy.summary(
                context: context, result: String(repeating: "R", count: 100), maxCharacters: budget
            ).count, budget)
        }
    }
}
