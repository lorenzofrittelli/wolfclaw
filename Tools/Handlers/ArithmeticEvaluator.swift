import Foundation

/// Aritmetica decimale senza eval, codice eseguibile o dipendenze dal modello.
enum ArithmeticEvaluator {
    static let maximumInputLength = 256
    static let maximumTokenCount = 128

    enum EvaluationError: Error, Equatable {
        case inputTooLong
        case tooManyTokens
        case invalidExpression
        case divisionByZero
        case overflow
        case underflow
        case precisionLoss
    }

    static func evaluate(_ expression: String) throws -> Decimal {
        try parse(expression).value()
    }

    static func formattedResult(_ value: Decimal) -> String {
        if value == 0 { return "0" }
        var number = value
        return NSDecimalString(&number, Locale(identifier: "en_US_POSIX"))
    }

    /// Accetta solo una richiesta isolata con prefisso esplicito e una vera
    /// operazione. L'unica istruzione aggiuntiva ammessa chiede il solo risultato.
    /// La validazione è sintattica: 1/0 arriva all'evaluator e genera un errore,
    /// senza ricadere sul modello per inventare un risultato.
    static func recognizedExpression(in request: String) -> String? {
        guard request.count <= maximumInputLength else { return nil }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes: [(text: String, italian: Bool)] = [
            ("quanto fa ", true), ("quanto è ", true), ("quanto vale ", true),
            ("calcola ", true), ("calcola: ", true),
            ("what is ", false), ("what's ", false),
            ("calculate ", false), ("calculate: ", false)
        ]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0.text) }) else { return nil }
        var expression = String(text.dropFirst(prefix.text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = prefix.italian ? "rispondi solo con il risultato" : "answer only with the result"
        // Il suffisso è una frase separata, mai parte di un numero o di un identificatore.
        let matchedSuffix = [suffix + ".", suffix].first(where: { expression.hasSuffix($0) })
        if let matchedSuffix {
            let preceding = String(expression.dropLast(matchedSuffix.count))
            guard preceding.last?.isWhitespace == true else { return nil }
            expression = preceding.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if expression.hasSuffix("?") || expression.hasSuffix(".") { expression.removeLast() }
        expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)

        let operators: [(String, String)] = prefix.italian
            ? [("diviso", "/"), ("per", "*"), ("più", "+"), ("meno", "-")]
            : [("divided by", "/"), ("times", "*"), ("plus", "+"), ("minus", "-")]
        for (word, symbol) in operators {
            expression = expression.replacingOccurrences(
                of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])",
                with: symbol, options: .regularExpression
            )
        }
        expression = expression.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        if prefix.italian { expression = expression.replacingOccurrences(of: ",", with: ".") }
        // Date possono sembrare sottrazioni o divisioni: non indovinarne il senso.
        let compact = expression.filter { !$0.isWhitespace }
        guard compact.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) == nil,
              compact.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#, options: .regularExpression) == nil else { return nil }
        guard let parsed = try? parse(expression), parsed.hasBinaryOperation else { return nil }
        return expression
    }

    private enum Token: Equatable {
        case number(String)
        case plus, minus, multiply, divide, leftParenthesis, rightParenthesis
    }

    private indirect enum Expression {
        case literal(String)
        case negate(Expression)
        case binary(Token, Expression, Expression)

        var hasBinaryOperation: Bool {
            switch self {
            case .literal: return false
            case .negate(let expression): return expression.hasBinaryOperation
            case .binary: return true
            }
        }

        func value() throws -> Decimal {
            switch self {
            case .literal(let text):
                guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN else { throw EvaluationError.overflow }
                // Decimal(string:) può arrotondare silenziosamente un numero troppo lungo.
                guard normalizedLiteral(text) == normalizedLiteral(formattedResult(number)) else {
                    throw number == 0 ? EvaluationError.underflow : EvaluationError.precisionLoss
                }
                return number
            case .negate(let expression):
                return try calculate(.multiply, expression.value(), Decimal(-1))
            case .binary(let operation, let lhs, let rhs):
                return try calculate(operation, lhs.value(), rhs.value())
            }
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        mutating func expression() throws -> Expression {
            var result = try term()
            while let operation = peek, operation == .plus || operation == .minus {
                index += 1
                result = .binary(operation, result, try term())
            }
            return result
        }

        private mutating func term() throws -> Expression {
            var result = try unary()
            while let operation = peek, operation == .multiply || operation == .divide {
                index += 1
                result = .binary(operation, result, try unary())
            }
            return result
        }

        private mutating func unary() throws -> Expression {
            if peek == .plus { index += 1; return try unary() }
            if peek == .minus { index += 1; return .negate(try unary()) }
            guard let token = peek else { throw EvaluationError.invalidExpression }
            index += 1
            switch token {
            case .number(let number): return .literal(number)
            case .leftParenthesis:
                let result = try expression()
                guard peek == .rightParenthesis else { throw EvaluationError.invalidExpression }
                index += 1
                return result
            default: throw EvaluationError.invalidExpression
            }
        }

        private var peek: Token? { index < tokens.count ? tokens[index] : nil }
    }

    private static func parse(_ text: String) throws -> Expression {
        guard text.count <= maximumInputLength else { throw EvaluationError.inputTooLong }
        let tokens = try tokenize(text)
        var parser = Parser(tokens: tokens)
        let result = try parser.expression()
        guard parser.index == tokens.count else { throw EvaluationError.invalidExpression }
        return result
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        func isDigit(_ character: Character) -> Bool {
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii)
        }
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if isDigit(character) || character == "." {
                let start = index
                while index < characters.count, isDigit(characters[index]) { index += 1 }
                if index < characters.count, characters[index] == "." {
                    index += 1
                    let fractionStart = index
                    while index < characters.count, isDigit(characters[index]) { index += 1 }
                    guard fractionStart < index else { throw EvaluationError.invalidExpression }
                }
                tokens.append(.number(String(characters[start..<index])))
            } else {
                switch character {
                case "+": tokens.append(.plus)
                case "-": tokens.append(.minus)
                case "*": tokens.append(.multiply)
                case "/": tokens.append(.divide)
                case "(": tokens.append(.leftParenthesis)
                case ")": tokens.append(.rightParenthesis)
                default: throw EvaluationError.invalidExpression
                }
                index += 1
            }
            guard tokens.count <= maximumTokenCount else { throw EvaluationError.tooManyTokens }
        }
        return tokens
    }

    private static func calculate(_ operation: Token, _ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var left = lhs
        var right = rhs
        var result = Decimal()
        let status: Decimal.CalculationError
        switch operation {
        case .plus: status = NSDecimalAdd(&result, &left, &right, .plain)
        case .minus: status = NSDecimalSubtract(&result, &left, &right, .plain)
        case .multiply: status = NSDecimalMultiply(&result, &left, &right, .plain)
        case .divide:
            guard right != 0 else { throw EvaluationError.divisionByZero }
            status = NSDecimalDivide(&result, &left, &right, .plain)
        default: throw EvaluationError.invalidExpression
        }
        switch status {
        case .noError:
            guard !result.isNaN else { throw EvaluationError.overflow }
            // NSDecimalDivide può dichiarare noError anche per periodici come 1/3.
            // La moltiplicazione intera su cifre evita un secondo arrotondamento
            // che potrebbe nascondere la differenza durante la verifica inversa.
            if operation == .divide, exactProduct(result, right) != formattedResult(left) {
                throw result == 0 && left != 0 ? EvaluationError.underflow : EvaluationError.precisionLoss
            }
            // Anche l'underflow di un prodotto può arrivare senza codice d'errore.
            if operation == .multiply, exactProduct(left, right) != formattedResult(result) {
                throw result == 0 && left != 0 && right != 0 ? EvaluationError.underflow : EvaluationError.precisionLoss
            }
            return result
        case .lossOfPrecision: throw EvaluationError.precisionLoss
        case .underflow: throw EvaluationError.underflow
        case .overflow: throw EvaluationError.overflow
        case .divideByZero: throw EvaluationError.divisionByZero
        @unknown default: throw EvaluationError.invalidExpression
        }
    }

    private static func exactProduct(_ lhs: Decimal, _ rhs: Decimal) -> String {
        func components(_ number: Decimal) -> (digits: [Int], scale: Int, negative: Bool) {
            let text = formattedResult(number)
            let parts = text.split(separator: ".")
            let digits = text.compactMap { $0.wholeNumberValue }.reversed()
            return (Array(digits), parts.count > 1 ? parts[1].count : 0, text.hasPrefix("-"))
        }
        let left = components(lhs)
        let right = components(rhs)
        var digits = Array(repeating: 0, count: left.digits.count + right.digits.count)
        for (i, a) in left.digits.enumerated() {
            for (j, b) in right.digits.enumerated() { digits[i + j] += a * b }
        }
        for index in 0..<(digits.count - 1) {
            digits[index + 1] += digits[index] / 10
            digits[index] %= 10
        }
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        var text = digits.reversed().map(String.init).joined()
        let scale = left.scale + right.scale
        if scale > 0 {
            if text.count <= scale { text = String(repeating: "0", count: scale + 1 - text.count) + text }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -scale))
        }
        text = normalizedLiteral(text)
        return text != "0" && left.negative != right.negative ? "-" + text : text
    }

    private static func normalizedLiteral(_ literal: String) -> String {
        let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0].drop(while: { $0 == "0" })
        let fraction = parts.count > 1 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let whole = integer.isEmpty ? "0" : String(integer)
        return fraction.isEmpty ? whole : whole + "." + fraction
    }
}
