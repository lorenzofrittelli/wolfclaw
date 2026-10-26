import Contacts
import Foundation

/// Regole sui soli dati del contatto: nessun accesso alla rubrica o salvataggio.
enum ContactUpdatePolicy {
    struct Fields {
        let name: String
        var phone: String? = nil
        var company: String? = nil
        var email: String? = nil
        var notes: String? = nil
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedPhone(_ value: String) -> String {
        guard value.contains(where: { $0.wholeNumberValue != nil }) else { return "" }
        let normalized = value.lowercased().compactMap { character -> String? in
            if let digit = character.wholeNumberValue { return String(digit) }
            if character.isWhitespace || "()-./".contains(character) { return nil }
            return String(character)
        }.joined()
        // Equivalenza del prefisso internazionale; mai inferire il paese o
        // confondere un interno (x, #, pausa) con le cifre del numero principale.
        return normalized.hasPrefix("00") ? "+" + normalized.dropFirst(2) : normalized
    }

    static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Un identificatore esplicito prevale. In sua assenza i dati esatti possono
    /// selezionare più persone: il chiamante deve rifiutare il salvataggio ambiguo.
    static func matchingContacts(
        in contacts: [CNContact],
        identifier: String? = nil,
        phone: String? = nil,
        email: String? = nil
    ) -> [CNContact] {
        let identifier = nonempty(identifier)
        let phoneKey = phone.map(normalizedPhone) ?? ""
        let emailKey = email.map(normalizedEmail) ?? ""
        var unique: [String: CNContact] = [:]
        for contact in contacts {
            let matches: Bool
            if let identifier {
                matches = contact.identifier == identifier
            } else {
                matches = (!phoneKey.isEmpty && contact.phoneNumbers.contains {
                    normalizedPhone($0.value.stringValue) == phoneKey
                }) || (!emailKey.isEmpty && contact.emailAddresses.contains {
                    normalizedEmail(String($0.value)) == emailKey
                })
            }
            if matches { unique[contact.identifier] = contact }
        }
        return unique.values.sorted { $0.identifier < $1.identifier }
    }

    static func apply(_ fields: Fields, to contact: CNMutableContact, isExisting: Bool) {
        // Il nome identifica la richiesta, non autorizza a rinominare una persona
        // già trovata tramite identificatore, telefono o email.
        if !isExisting { contact.givenName = fields.name }

        if let phone = nonempty(fields.phone) {
            let key = normalizedPhone(phone)
            if !key.isEmpty, !contact.phoneNumbers.contains(where: {
                normalizedPhone($0.value.stringValue) == key
            }) {
                contact.phoneNumbers.append(CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: phone)
                ))
            }
        }
        if let email = nonempty(fields.email), !contact.emailAddresses.contains(where: {
            normalizedEmail(String($0.value)) == normalizedEmail(email)
        }) {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelWork, value: email as NSString))
        }
        // Assenza o stringa vuota non sono istruzioni di cancellazione.
        if let company = nonempty(fields.company) { contact.organizationName = company }
        if let notes = nonempty(fields.notes) { contact.note = notes }
    }
}
