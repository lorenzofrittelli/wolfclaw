import Contacts
import XCTest
@testable import PhoneClawCore

final class ContactUpdatePolicyTests: XCTestCase {
    private func existingContact() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.middleName = "Maria"
        contact.familyName = "Rossi"
        contact.nickname = "A"
        contact.organizationName = "Studio"
        contact.note = "Nota da conservare"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+39 333 111 2222")),
            CNLabeledValue(label: "Segreteria", value: CNPhoneNumber(stringValue: "02 123456"))
        ]
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "Ada@Example.org" as NSString),
            CNLabeledValue(label: "Associazione", value: "ada@club.example" as NSString)
        ]
        return contact
    }

    func testAppendPreservesAllExistingValuesLabelsAndIdentifiers() {
        let contact = existingContact()
        let phones = contact.phoneNumbers
        let emails = contact.emailAddresses

        ContactUpdatePolicy.apply(
            .init(name: "Ada", phone: "+39 333 555 6666", email: "ada@work.example"),
            to: contact, isExisting: true
        )

        XCTAssertEqual(contact.phoneNumbers.count, 3)
        XCTAssertEqual(contact.emailAddresses.count, 3)
        XCTAssertEqual(Array(contact.phoneNumbers.prefix(2)), phones)
        XCTAssertEqual(Array(contact.emailAddresses.prefix(2)), emails)
        XCTAssertEqual(contact.phoneNumbers.prefix(2).map(\.identifier), phones.map(\.identifier))
        XCTAssertEqual(contact.emailAddresses.prefix(2).map(\.identifier), emails.map(\.identifier))
        XCTAssertEqual(contact.phoneNumbers.last?.value.stringValue, "+39 333 555 6666")
        XCTAssertEqual(contact.emailAddresses.last?.value, "ada@work.example")
    }

    func testEquivalentValuesDoNotDuplicateOrRelabelExistingEntries() {
        let contact = existingContact()
        let phones = contact.phoneNumbers
        let emails = contact.emailAddresses

        ContactUpdatePolicy.apply(
            .init(name: "Un altro nome", phone: "0039 (333) 111-2222", email: " ada@EXAMPLE.ORG "),
            to: contact, isExisting: true
        )

        XCTAssertEqual(contact.phoneNumbers, phones)
        XCTAssertEqual(contact.emailAddresses, emails)
        XCTAssertEqual(contact.givenName, "Ada")
        XCTAssertEqual(contact.middleName, "Maria")
        XCTAssertEqual(contact.familyName, "Rossi")
        XCTAssertEqual(contact.nickname, "A")
    }

    func testOmittedAndEmptyFieldsNeverEraseData() {
        let contact = existingContact()
        let before = contact.copy() as! CNContact
        ContactUpdatePolicy.apply(.init(name: "Ada"), to: contact, isExisting: true)
        ContactUpdatePolicy.apply(
            .init(name: "Ada", phone: " ", company: "\n", email: "", notes: " "),
            to: contact, isExisting: true
        )
        XCTAssertEqual(contact, before)
    }

    func testExplicitScalarChangesPreserveOtherFields() {
        let contact = existingContact()
        let phones = contact.phoneNumbers
        ContactUpdatePolicy.apply(
            .init(name: "Alias", company: "Nuova società", notes: "Nuova nota"),
            to: contact, isExisting: true
        )
        XCTAssertEqual(contact.organizationName, "Nuova società")
        XCTAssertEqual(contact.note, "Nuova nota")
        XCTAssertEqual(contact.familyName, "Rossi")
        XCTAssertEqual(contact.phoneNumbers, phones)
    }

    func testNewContactGetsRequestedFields() {
        let contact = CNMutableContact()
        ContactUpdatePolicy.apply(
            .init(name: "Ada Rossi", phone: "+39 333 111 2222", company: "Studio", email: "ada@example.org"),
            to: contact, isExisting: false
        )
        XCTAssertEqual(contact.givenName, "Ada Rossi")
        XCTAssertEqual(contact.phoneNumbers.count, 1)
        XCTAssertEqual(contact.emailAddresses.count, 1)
        XCTAssertEqual(contact.organizationName, "Studio")
    }

    func testExactMatchUsesNormalizedFullPhoneAndEmail() {
        let contact = existingContact()
        XCTAssertEqual(ContactUpdatePolicy.matchingContacts(
            in: [contact], phone: "0039 3331112222"
        ).map(\.identifier), [contact.identifier])
        XCTAssertEqual(ContactUpdatePolicy.matchingContacts(
            in: [contact], email: " ADA@example.ORG "
        ).map(\.identifier), [contact.identifier])
        XCTAssertTrue(ContactUpdatePolicy.matchingContacts(in: [contact], phone: "2222").isEmpty)
        XCTAssertTrue(ContactUpdatePolicy.matchingContacts(in: [contact], email: "example.org").isEmpty)
        XCTAssertTrue(ContactUpdatePolicy.matchingContacts(in: [contact]).isEmpty)
    }

    func testMultipleMatchesRemainAmbiguousRegardlessOfEnumerationOrder() {
        let first = existingContact()
        let second = existingContact()
        let forward = ContactUpdatePolicy.matchingContacts(in: [first, second], phone: "+39 3331112222")
        let reversed = ContactUpdatePolicy.matchingContacts(in: [second, first], phone: "+39 3331112222")
        XCTAssertEqual(forward.count, 2)
        XCTAssertEqual(forward.map(\.identifier), reversed.map(\.identifier))
    }

    func testConflictingPhoneAndEmailMatchesRequireDisambiguation() {
        let first = existingContact()
        let second = CNMutableContact()
        second.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "other@example.org" as NSString)]
        XCTAssertEqual(ContactUpdatePolicy.matchingContacts(
            in: [first, second], phone: "+39 3331112222", email: "other@example.org"
        ).count, 2)
    }

    func testIdentifierSelectsExactContactAndNeverFallsBackWhenMissing() {
        let first = existingContact()
        let second = existingContact()
        XCTAssertEqual(ContactUpdatePolicy.matchingContacts(
            in: [first, second], identifier: second.identifier, phone: "new number"
        ).map(\.identifier), [second.identifier])
        XCTAssertTrue(ContactUpdatePolicy.matchingContacts(
            in: [first, second], identifier: "missing", phone: "+39 3331112222"
        ).isEmpty)
        XCTAssertEqual(ContactUpdatePolicy.matchingContacts(
            in: [first, first], identifier: first.identifier
        ).count, 1)
    }

    func testNormalizationDoesNotGuessCountryOrMergeExtensions() {
        XCTAssertNotEqual(ContactUpdatePolicy.normalizedPhone("3331112222"), ContactUpdatePolicy.normalizedPhone("+39 3331112222"))
        XCTAssertNotEqual(ContactUpdatePolicy.normalizedPhone("+1 234 x56"), ContactUpdatePolicy.normalizedPhone("+1 23456"))
        XCTAssertEqual(ContactUpdatePolicy.normalizedPhone("００３９ (３３３) １１１-２２２２"), "+393331112222")
        XCTAssertEqual(ContactUpdatePolicy.normalizedPhone("invalid"), "")
    }
}
