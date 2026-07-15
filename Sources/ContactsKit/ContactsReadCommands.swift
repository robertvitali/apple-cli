import Foundation
import ArgumentParser
import AppleKit

// Read commands — safe to compare freely against the live MCP oracle. Each maps 1:1
// to an apple-contacts-mcp @ 1cd8789 (v0.3.0) read tool.

private let contactsCap = 200
private let groupsCap = 200
private let containersCap = 10

// MARK: - auth → check_authorization

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Report Contacts TCC authorization status (never prompts). → check_authorization")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: "contacts") {
            let store = ContactsStore()
            let status = store.authorizationStatus()
            let rem = (status == "authorized" || status == "limited") ? nil : ContactsStore.remediation(for: status)
            try emitContacts(global, AuthResult(status: status, remediation: rem))
        }
    }
}

// MARK: - list → list_contacts

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List contacts (paged, 4-field summaries). → list_contacts")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Number of contacts to skip (>= 0).") var offset = 0
    @Option(name: .long, help: "Max contacts to return (default 50, capped at 200).") var limit = 50
    func run() throws {
        try runGuarded(tool: "contacts") {
            if offset < 0 { throw AppleError.validation("offset must be >= 0") }
            if limit < 1 { throw AppleError.validation("limit must be >= 1") }
            let effective = effectiveLimit(limit, cap: contactsCap)
            let store = ContactsStore()
            try store.requireAuthorization()
            let contacts = try store.enumerateContacts(offset: offset, limit: effective)
            try emitContacts(global, ListContactsResult(
                contacts: contacts, count: contacts.count, offset: offset, limit: effective))
        }
    }
}

// MARK: - get → get_contact

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Fetch one contact by identifier (full P1 fields). → get_contact")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    @Flag(name: .long, help: "Also fetch niche families (dates, social_profiles, relations, instant_messages).")
    var niche = false
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            guard let contact = store.unifiedContact(identifier, includeNiche: niche) else {
                throw AppleError.notFound("No contact found with identifier \(identifier)")
            }
            try emitContacts(global, GetContactResult(contact: contact))
        }
    }
}

// MARK: - search → search_contacts (+ Contactor --deep all-field fold-in)

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find contacts by name|phone|email|org (exactly one). → search_contacts")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Substring to match against contact names.") var name: String?
    @Option(name: .long, help: "Phone number to match (any format).") var phone: String?
    @Option(name: .long, help: "Email address to match.") var email: String?
    @Option(name: [.customLong("org"), .customLong("organization")], help: "Substring to match against organization.")
    var organization: String?
    @Flag(name: .long, help: "Extra: match the given value across ALL fields (name/phone/email/org), unioned.")
    var deep = false

    func run() throws {
        try runGuarded(tool: "contacts") {
            let (field, value) = try resolveSearchSelection(
                name: name, phone: phone, email: email, organization: organization)
            let store = ContactsStore()
            try store.requireAuthorization()

            let contacts: [ContactSummary]
            if deep {
                var lists: [[ContactSummary]] = []
                for f in ["name", "phone", "email", "organization"] {
                    lists.append(try store.searchContacts(field: f, value: value, limit: contactsCap))
                }
                contacts = unionSummariesByID(lists, cap: contactsCap)
            } else {
                contacts = try store.searchContacts(field: field, value: value, limit: contactsCap)
            }
            try emitContacts(global, SearchContactsResult(
                contacts: contacts, count: contacts.count, search_field: field,
                search_value: value, limit: contactsCap, deep: deep ? true : nil))
        }
    }
}

// MARK: - containers list → list_containers

struct ContainersListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all contact containers (accounts). → list_containers")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: "contacts") {
            let store = ContactsStore()
            try store.requireAuthorization()
            let all = try store.listContainers()
            let capped = Array(all.prefix(containersCap))
            try emitContacts(global, ListContainersResult(
                containers: capped, count: capped.count, limit: containersCap))
        }
    }
}

// MARK: - groups list → list_groups

struct GroupsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all contact groups across all containers. → list_groups")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: "contacts") {
            let store = ContactsStore()
            try store.requireAuthorization()
            let all = try store.listGroups()
            let capped = Array(all.prefix(groupsCap))
            try emitContacts(global, ListGroupsResult(groups: capped, count: capped.count, limit: groupsCap))
        }
    }
}

// MARK: - groups members → get_contacts_in_group

struct GroupsMembersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List contacts in a group (distinct not_found vs empty). → get_contacts_in_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The group's CN identifier.") var identifier: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            guard try store.fetchGroup(identifier) != nil else {
                throw AppleError.notFound("No group found with identifier \(identifier)")
            }
            let contacts = try store.contactsInGroup(identifier, limit: contactsCap)
            try emitContacts(global, GroupMembersResult(
                group_identifier: identifier, contacts: contacts, count: contacts.count, limit: contactsCap))
        }
    }
}

// MARK: - vcard export → export_vcard

struct VCardExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export contacts as one atomic vCard 3.0 payload. → export_vcard")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "One or more contact CN identifiers.") var identifiers: [String] = []
    @Option(name: .long, help: "Extra: also write the vCard text to this file path.") var out: String?
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifiers.isEmpty {
                throw AppleError.validation("identifiers must be a non-empty list of strings")
            }
            for (i, id) in identifiers.enumerated() where id.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifiers[\(i)] must be a non-empty string")
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            let vcard = try store.exportVCard(identifiers)
            var writtenTo: String?
            if let out {
                do { try vcard.write(toFile: out, atomically: true, encoding: .utf8); writtenTo = out }
                catch { throw AppleError.unknown("failed to write vcard to \(out): \(error.localizedDescription)") }
            }
            try emitContacts(global, ExportVCardResult(
                vcard: vcard, count: identifiers.count,
                notes: [
                    "NOTE field is omitted (entitlement-gated). Use `contacts note get <id>` and merge separately if needed.",
                    "Year-less birthdays use Apple's X-APPLE-OMIT-YEAR=1604 hack; non-Apple consumers see 1604 as the literal year.",
                ],
                written_to: writtenTo))
        }
    }
}

// MARK: - note get → read_note (AppleScript)

struct NoteGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read a contact's note (AppleScript; needs :ABPerson-suffixed id). → read_note")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's full CN identifier including the :ABPerson suffix.") var identifier: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            let note = try store.readNote(identifier)
            try emitContacts(global, ReadNoteResult(identifier: identifier, note: note))
        }
    }
}

// MARK: - photo get → read_photo

struct PhotoGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read a contact's photo (base64 + detected format). → read_photo")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    @Option(name: .long, help: "Extra: write the raw photo bytes to this file path.") var out: String?
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            guard let photo = store.readPhoto(identifier) else {
                throw AppleError.notFound("Contact not found: \(identifier)")
            }
            if !photo.available {
                try emitContacts(global, ReadPhotoResult(
                    identifier: identifier, image_data: nil, format: nil, size_bytes: 0, written_to: nil))
                return
            }
            var writtenTo: String?
            if let out {
                do { try photo.bytes.write(to: URL(fileURLWithPath: out)); writtenTo = out }
                catch { throw AppleError.unknown("failed to write photo to \(out): \(error.localizedDescription)") }
            }
            try emitContacts(global, ReadPhotoResult(
                identifier: identifier,
                image_data: photo.bytes.base64EncodedString(),
                format: detectImageFormat(photo.bytes),
                size_bytes: photo.bytes.count,
                written_to: writtenTo))
        }
    }
}
