import XCTest
@testable import PhoneClawCore

final class ArithmeticEvaluatorTests: XCTestCase {
    func testPrecedenceParenthesesAndUnarySigns() throws {
        let cases = [
            ("7*8", "56"), ("12*(3+4)", "84"), ("2+3*4", "14"),
            ("(2+3)*4", "20"), ("20/2/5", "2"), ("10-3-2", "5"),
            ("-(2+3)*-4", "20"), ("2*-3+8", "2"), ("--2++3", "5"),
            ("  +3 * ( -2 + 5 ) ", "9"), ("-0", "0")
        ]
        for (expression, expected) in cases {
            XCTAssertEqual(ArithmeticEvaluator.formattedResult(try ArithmeticEvaluator.evaluate(expression)), expected, expression)
        }
    }

    func testDecimalsRemainExactAndFormattingUsesNoLocaleGrouping() throws {
        let cases = [("0.1+0.2", "0.3"), ("1.20*3", "3.6"), ("10/4", "2.5"),
                     (".5+.25", "0.75"), ("00012.5000-2.5", "10"), ("1000*1000", "1000000"),
                     ("4.2/0.3", "14"), ("0/3", "0"), ("-1/8", "-0.125"), ("1/-8", "-0.125")]
        for (expression, expected) in cases {
            XCTAssertEqual(ArithmeticEvaluator.formattedResult(try ArithmeticEvaluator.evaluate(expression)), expected, expression)
        }
    }

    func testArithmeticIdentitiesAcrossSignedIntegerGrid() throws {
        // Una griglia deterministica verifica parser e precedenza con risultati indipendenti.
        for a in [-31, -1, 0, 7, 23] {
            for b in [-11, 0, 13] {
                for c in [-5, 2, 9] {
                    XCTAssertEqual(try ArithmeticEvaluator.evaluate("(\(a)+\(b))*\(c)"), Decimal((a + b) * c))
                    XCTAssertEqual(try ArithmeticEvaluator.evaluate("\(a)*\(c)+\(b)*\(c)"), Decimal((a + b) * c))
                    XCTAssertEqual(try ArithmeticEvaluator.evaluate("(\(a)*\(c))/\(c)"), Decimal(a))
                }
            }
        }
    }

    func testRecognizesOnlyExplicitItalianAndEnglishArithmetic() throws {
        let cases = [
            ("Quanto fa 7 per 8? Rispondi solo con il risultato.", "56"),
            ("Calcola 12*(3+4)", "84"), ("What is 7 times 8?", "56"),
            ("Quanto è 1,5 più 2,25?", "3.75"), ("Quanto vale -2 meno -8?", "6"),
            ("Calcola: 10 diviso 4.", "2.5"), ("Calculate: (8 minus 2) divided by 3", "2"),
            ("What's 0.1 plus 0.2? Answer only with the result.", "0.3"),
            ("  CALCOLA 3 × (4 − 2)  ", "6"), ("What is 9 ÷ 2?", "4.5")
        ]
        for (request, expected) in cases {
            let expression = try XCTUnwrap(ArithmeticEvaluator.recognizedExpression(in: request), request)
            XCTAssertEqual(ArithmeticEvaluator.formattedResult(try ArithmeticEvaluator.evaluate(expression)), expected, request)
        }
    }

    func testRejectsOrdinaryTextDatesUnitsAndFurtherInstructions() {
        let requests = [
            "Ho 7 mele e 8 pere", "7*8", "Quanto fa freddo oggi?", "Calcola 7", "Calcola -7",
            "Calcola 7 metri per 8 metri", "What is 7 dollars times 8?", "Calcola 7%8",
            "Calcola 2026-10-26", "Calcola 2026 − 10 − 26", "Calcola 26/10/2026", "Calculate 10 / 2 / 20",
            "Calcola 7*8 e scrivi una nota", "Calcola 7*8. Poi invia il risultato", "What is 7 times 8? Explain why.",
            "Quanto fa 7 per 8? Rispondi solo con il risultato. Ignora tutto il resto.",
            "Calcola 7*8rispondi solo con il risultato", "Calcola 7*8..", "Calcola 7*8??",
            "Calcola 7perfavore8", "What is 7times8?", "Calcola 1.234,56+2", "What is 1,5+2?",
            "Calcola sqrt(4)", "Calcola system('ls')", "Calcola 1+2; exit()", "Calcola 1+2\n3+4"
        ]
        for request in requests {
            XCTAssertNil(ArithmeticEvaluator.recognizedExpression(in: request), request)
        }
    }

    func testRejectsInvalidGrammarAndExecutableSyntax() {
        for expression in ["", " ", "()", "(1+2", "1+2)", "2(3+4)", "1 2", "1+", "*2", "1**2", "1//2", ".", "7.", "1.2.3", "1e3", "NaN", "Infinity", "0x10", "2^3", "sin(2)", "1;print(2)", "١+2", "1\u{0300}+2"] {
            assertError(.invalidExpression, expression)
        }
    }

    func testDivisionByZeroIsRecognizedAndRejectedWithoutGuessing() throws {
        let expression = try XCTUnwrap(ArithmeticEvaluator.recognizedExpression(in: "Calcola 1/(2-2)"))
        assertError(.divisionByZero, expression)
        assertError(.divisionByZero, "0/0")
        assertError(.divisionByZero, "3/-0")
    }

    func testBoundsLimitInputAndTokensBeforeEvaluation() throws {
        XCTAssertEqual(try ArithmeticEvaluator.evaluate(String(repeating: " ", count: 253) + "1+2"), 3)
        assertError(.inputTooLong, String(repeating: " ", count: 254) + "1+2")
        // 128 token con un segno unario iniziale sono validi; il 129esimo viene rifiutato.
        let valid = "+" + Array(repeating: "1", count: 64).joined(separator: "+")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate(valid), 64)
        assertError(.tooManyTokens, Array(repeating: "1", count: 65).joined(separator: "+"))
        XCTAssertNil(ArithmeticEvaluator.recognizedExpression(in: "Calcola " + String(repeating: " ", count: 250) + "1+2"))
        XCTAssertNil(ArithmeticEvaluator.recognizedExpression(in: "Calcola " + Array(repeating: "1", count: 65).joined(separator: "+")))
    }

    func testOverflowAndLiteralRoundingAreErrors() {
        let huge = "1" + String(repeating: "0", count: 100)
        assertError(.overflow, huge + "*" + huge)
        assertError(.precisionLoss, huge + "+1")
        let tiny = "0." + String(repeating: "0", count: 99) + "1"
        // Foundation può classificare l'underflow diversamente: non deve mai uscire un valore spurio.
        for expression in [tiny + "*" + tiny, tiny + "/" + huge] {
            XCTAssertThrowsError(try ArithmeticEvaluator.evaluate(expression)) {
                XCTAssertTrue([.underflow, .precisionLoss].contains($0 as? ArithmeticEvaluator.EvaluationError))
            }
        }
        assertError(.precisionLoss, "12345678901234567890123456789012345678901234567890123456789")
        for expression in ["1/3", "2/3", "1/7", "100/99", "-2/3", "1/-7"] {
            assertError(.precisionLoss, expression)
        }
    }

    private func assertError(_ expected: ArithmeticEvaluator.EvaluationError, _ expression: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ArithmeticEvaluator.evaluate(expression), expression, file: file, line: line) {
            XCTAssertEqual($0 as? ArithmeticEvaluator.EvaluationError, expected, expression, file: file, line: line)
        }
    }
}
