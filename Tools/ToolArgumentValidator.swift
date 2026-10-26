import CoreFoundation
import Foundation

/// Validazione condivisa prima dell'esecuzione. Non interpreta le descrizioni
/// localizzate: usa lo schema JSON dichiarato o i tipi dei parametri nativi.
enum ToolArgumentValidator {
    /// Converte senza trap e senza il bridge NSNumber→Int, che può arrotondare
    /// Double(Int.max) a Int.max. Gli interi originali mantengono tutti i bit.
    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        if number is NSDecimalNumber {
            return Int(number.stringValue)
        }
        switch String(cString: number.objCType) {
        case "f", "d":
            return Int(exactly: number.doubleValue)
        default:
            return Int(number.stringValue)
        }
    }

    static func validates(
        _ arguments: [String: Any],
        toolName: String,
        parameters: String,
        required: [String],
        requiredAnyOf: [String],
        isParameterless: Bool
    ) -> Bool {
        if isParameterless { return arguments.isEmpty }
        let schema = jsonSchema(parameters) ?? nativeSchema(toolName)
        let schemaRequired = schema?.compactMap { $0.value["required"] as? Bool == true ? $0.key : nil } ?? []
        guard (required + schemaRequired).allSatisfy({ hasMeaningfulValue(arguments[$0]) }) else { return false }
        if !requiredAnyOf.isEmpty, !requiredAnyOf.contains(where: { hasMeaningfulValue(arguments[$0]) }) {
            return false
        }
        for (key, value) in arguments {
            guard !(value is NSNull) else { return false }
            if let schema {
                guard let rule = schema[key], accepts(value, rule: rule) else { return false }
            }
        }
        return true
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }

    private static func jsonSchema(_ description: String) -> [String: [String: Any]]? {
        guard let data = description.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if var properties = object["properties"] as? [String: [String: Any]] {
            for key in object["required"] as? [String] ?? [] {
                properties[key, default: [:]]["required"] = true
            }
            return properties
        }
        return object as? [String: [String: Any]]
    }

    private static func accepts(_ value: Any, rule: [String: Any]) -> Bool {
        guard !(value is NSNull) else { return false }
        let isBoolean = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch rule["type"] as? String {
        case "string":
            guard value is String else { return false }
        case "integer", "number":
            guard let number = value as? NSNumber, !isBoolean, number.doubleValue.isFinite else { return false }
            if rule["type"] as? String == "integer", exactInteger(value) == nil { return false }
        case "boolean":
            guard isBoolean else { return false }
        case "array":
            guard let array = value as? [Any] else { return false }
            if let itemRule = rule["items"] as? [String: Any], !array.allSatisfy({ accepts($0, rule: itemRule) }) { return false }
        case "object":
            guard value is [String: Any] else { return false }
        case nil:
            break
        default:
            return false
        }
        if let choices = rule["enum"] as? [Any], !choices.contains(where: { choice in
            guard let lhs = value as? NSObject, let rhs = choice as? NSObject else { return false }
            return lhs.isEqual(rhs)
        }) { return false }
        return true
    }

    private static func nativeSchema(_ name: String) -> [String: [String: Any]]? {
        let text: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer"]
        var strings: [String]
        var extra: [String: [String: Any]] = [:]
        switch name {
        case "contacts-upsert": strings = ["name", "identifier", "phone", "company", "email", "notes"]
        case "contacts-search", "contacts-delete": strings = ["query", "identifier", "name", "phone", "email"]
        case "clipboard-write": strings = ["text"]
        case "calendar-create-event": strings = ["title", "start", "end", "location", "notes"]
        case "reminders-create": strings = ["title", "due", "notes"]
        case "calendar-query-events":
            strings = ["period", "start", "end", "calendar"]
            extra = ["days": integer, "limit": integer, "include_notes": ["type": "boolean"], "includeNotes": ["type": "boolean"]]
        case "web-search":
            strings = ["query", "question"]
            extra = ["max_results": integer, "planned_queries": ["type": "array", "items": text]]
        case "web-fetch":
            strings = ["url"]
            extra = ["max_characters": integer]
        default:
            return nil
        }
        return Dictionary(uniqueKeysWithValues: strings.map { ($0, text) }).merging(extra) { _, new in new }
    }
}
