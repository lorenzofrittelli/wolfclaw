import XCTest
@testable import PhoneClawCore

final class ToolArgumentValidatorTests: XCTestCase {
    private func validate(_ args: [String: Any], tool: String = "contacts-upsert", required: [String] = ["name"], anyOf: [String] = [], schema: String = "", parameterless: Bool = false) -> Bool {
        ToolArgumentValidator.validates(args, toolName: tool, parameters: schema, required: required, requiredAnyOf: anyOf, isParameterless: parameterless)
    }

    func testContactRequiresNonemptyStringName() {
        for value: Any in [NSNull(), "", " \n", 42, true, ["Ada"], ["name": "Ada"]] {
            XCTAssertFalse(validate(["name": value]), "Accettato nome non valido: \(value)")
        }
        XCTAssertFalse(validate([:]))
        XCTAssertTrue(validate(["name": "Ada", "identifier": "contact-id", "phone": "+39 3331234567"]))
    }

    func testOptionalContactFieldsStillRequireTheirDeclaredTypes() {
        XCTAssertFalse(validate(["name": "Ada", "email": ["ada@example.org"]]))
        XCTAssertFalse(validate(["name": "Ada", "phone": 3331234567]))
        XCTAssertFalse(validate(["name": "Ada", "notes": NSNull()]))
        XCTAssertFalse(validate(["name": "Ada", "all": true]))
        XCTAssertTrue(validate(["name": "Ada", "notes": ""]))
    }

    func testAnyOfCannotBeSatisfiedByNullOrWhitespace() {
        let anyOf = ["identifier", "name", "phone"]
        XCTAssertFalse(validate(["name": " ", "phone": NSNull()], tool: "contacts-delete", required: [], anyOf: anyOf))
        XCTAssertFalse(validate(["phone": true], tool: "contacts-delete", required: [], anyOf: anyOf))
        XCTAssertTrue(validate(["identifier": "id"], tool: "contacts-delete", required: [], anyOf: anyOf))
    }

    func testIntegerSchemaRejectsBooleanFractionAndNumericString() throws {
        let schema = #"{"days":{"type":"integer","required":true}}"#
        for value: Any in [true, 2.5, "7", NSNull(), Double.infinity] {
            XCTAssertFalse(validate(["days": value], tool: "health-report", required: ["days"], schema: schema))
        }
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"days":7}"#.utf8)) as? [String: Any])
        XCTAssertTrue(validate(decoded, tool: "health-report", required: ["days"], schema: schema))
    }

    func testBooleanSchemaRejectsNumbersAndText() throws {
        for value: Any in [1, "true", NSNull()] {
            XCTAssertFalse(validate(["include_notes": value], tool: "calendar-query-events", required: []))
        }
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"include_notes":false}"#.utf8)) as? [String: Any])
        XCTAssertTrue(validate(decoded, tool: "calendar-query-events", required: []))
    }

    func testIntegerOverflowIsRejectedBeforeCalendarConversion() throws {
        for value: Any in [1e100, -1e100, Double(Int.max), Double(Int.min).nextDown, UInt64.max,
                           NSDecimalNumber(string: "9223372036854775808"),
                           NSDecimalNumber(string: "-9223372036854775809")] {
            XCTAssertNil(ToolArgumentValidator.exactInteger(value))
            XCTAssertFalse(validate(["period": "today", "limit": value], tool: "calendar-query-events", required: []))
        }
        for literal in ["1e100", "-1e100", "9223372036854775808", "-9223372036854775809"] {
            let json = "{\"period\":\"today\",\"limit\":\(literal)}"
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertFalse(validate(decoded, tool: "calendar-query-events", required: []), literal)
        }
    }

    func testExactIntegerLimitsRemainAcceptedWithoutDoubleRounding() throws {
        for value in [Int.min, -1, 0, 1, Int.max] {
            XCTAssertEqual(ToolArgumentValidator.exactInteger(value), value)
            XCTAssertTrue(validate(["limit": value], tool: "calendar-query-events", required: []))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"limit\":\(value)}".utf8)) as? [String: Any])
            XCTAssertEqual(ToolArgumentValidator.exactInteger(decoded["limit"]), value)
            XCTAssertTrue(validate(decoded, tool: "calendar-query-events", required: []))
        }
        XCTAssertEqual(ToolArgumentValidator.exactInteger(Double(Int.min)), Int.min)
        XCTAssertEqual(ToolArgumentValidator.exactInteger(7.0), 7)
        XCTAssertNil(ToolArgumentValidator.exactInteger(7.5))
        XCTAssertNil(ToolArgumentValidator.exactInteger(true))
        XCTAssertNil(ToolArgumentValidator.exactInteger(Double.nan))
    }

    func testArrayItemsAreValidated() {
        XCTAssertTrue(validate(["query": "swift", "planned_queries": ["swift guide", "swift reference"]], tool: "web-search", required: ["query"]))
        XCTAssertFalse(validate(["query": "swift", "planned_queries": ["swift guide", 1]], tool: "web-search", required: ["query"]))
        XCTAssertFalse(validate(["query": "swift", "planned_queries": "swift guide"], tool: "web-search", required: ["query"]))
    }

    func testDeclaredEnumAndSchemaRequiredFieldsAreEnforced() {
        let schema = #"{"type":"object","required":["mode"],"properties":{"mode":{"type":"string","enum":["read","write"]}}}"#
        XCTAssertTrue(validate(["mode": "read"], tool: "custom", required: [], schema: schema))
        XCTAssertFalse(validate([:], tool: "custom", required: [], schema: schema))
        XCTAssertFalse(validate(["mode": "delete"], tool: "custom", required: [], schema: schema))
        XCTAssertFalse(validate(["mode": 1], tool: "custom", required: [], schema: schema))
        XCTAssertFalse(validate(["mode": "read", "extra": true], tool: "custom", required: [], schema: schema))
    }

    func testParameterlessToolsRejectAnyArguments() {
        XCTAssertTrue(validate([:], required: [], parameterless: true))
        XCTAssertFalse(validate(["unused": NSNull()], required: [], parameterless: true))
    }
}
