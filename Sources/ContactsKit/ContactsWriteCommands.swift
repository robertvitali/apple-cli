import Foundation
import ArgumentParser
import AppleKit

// Write commands — each maps 1:1 to an apple-contacts-mcp @ 1cd8789 (v0.3.0) write tool, and
// under write-model v2 (docs/write-model-v2.md) each BEHAVES like that tool: invoking it
// mutates real data, because calling the MCP tool does. `--dry-run` previews; `APPLE_DRY_RUN`
// truthy restores dry-run-by-default.
//
// `resolveWrite` is the single chokepoint: it validates the v2 environment, resolves
// `willExecute`, and resolves `sandboxActive` (`APPLE_TEST_MODE` truthy OR `--test-mode`).
// Inside the sandbox — and ONLY inside it — writes are confined to `apple-cli-test`-labeled
// items, the CLI's analogue of the oracle's `CONTACTS_TEST_GROUP` confinement.
//
// TWO EXCEPTIONS survive outside the sandbox, both oracle-mirrored: `delete` and
// `groups delete` require `APPLE_TEST_MODE=1` in the ENVIRONMENT (not the flag) because the
// oracle's `require_test_mode_for` requires `CONTACTS_TEST_MODE=true` there — see
// `contactsDeleteEnvGranted`.

// MARK: - Flat-flag parsing helpers

/// Parse a repeatable `label:value` option into `[ScalarInput]`. No colon ⇒ empty label.
private func parseLabeledScalars(_ raw: [String]) -> [ScalarInput] {
    raw.map { entry in
        if let idx = entry.firstIndex(of: ":") {
            return ScalarInput(label: String(entry[..<idx]), value: String(entry[entry.index(after: idx)...]))
        }
        return ScalarInput(label: nil, value: entry)
    }
}

/// Parse `YYYY-MM-DD` or `MM-DD` (year-less) into a `BirthdayInput`.
private func parseBirthday(_ s: String) throws -> BirthdayInput {
    let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    func int(_ x: String) throws -> Int {
        guard let n = Int(x) else { throw AppleError.validation("birthday must be YYYY-MM-DD or MM-DD") }
        return n
    }
    switch parts.count {
    case 3: return BirthdayInput(year: try int(parts[0]), month: try int(parts[1]), day: try int(parts[2]))
    case 2: return BirthdayInput(year: nil, month: try int(parts[0]), day: try int(parts[1]))
    default: throw AppleError.validation("birthday must be YYYY-MM-DD or MM-DD")
    }
}

// Computed (not a stored global) so the non-Sendable `WritableKeyPath` map isn't a
// shared-mutable global under Swift 6 strict concurrency.
private var simpleFieldKeyPaths: [String: WritableKeyPath<ContactFields, String?>] {
    ["given_name": \.given_name, "family_name": \.family_name, "middle_name": \.middle_name,
     "name_prefix": \.name_prefix, "name_suffix": \.name_suffix, "nickname": \.nickname,
     "organization": \.organization, "job_title": \.job_title, "department": \.department]
}

/// First non-empty of given/family/org — the "primary name" the create gate label-checks.
/// Delegates to the shared `ContactsLabel` selector so create-label and fetched-target-guard
/// selection stay identical (no drift).
private func primaryName(_ f: ContactFields) -> String {
    ContactsLabel.primaryName(given: f.given_name, family: f.family_name, organization: f.organization)
}

// MARK: - create → create_contact

struct CreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a contact (EXECUTES by default; --dry-run previews). → create_contact")
    @OptionGroup var global: GlobalOptions
    @Option(name: [.customLong("first"), .customLong("given")], help: "Given name.") var first: String?
    @Option(name: [.customLong("last"), .customLong("family")], help: "Family name.") var last: String?
    @Option(name: .long, help: "Middle name.") var middle: String?
    @Option(name: .long, help: "Name prefix.") var prefix: String?
    @Option(name: .long, help: "Name suffix.") var suffix: String?
    @Option(name: .long, help: "Nickname.") var nickname: String?
    @Option(name: [.customLong("org"), .customLong("organization")], help: "Organization.") var organization: String?
    @Option(name: [.customLong("title"), .customLong("job-title")], help: "Job title.") var title: String?
    @Option(name: .long, help: "Department.") var department: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Phone as label:value (repeatable).") var phone: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Email as label:value (repeatable).") var email: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "URL as label:value (repeatable).") var url: [String] = []
    @Option(name: .long, help: "Birthday as YYYY-MM-DD or MM-DD.") var birthday: String?
    @Option(name: .long, help: "Full contact object as a JSON blob (overrides flat flags).") var json: String?
    @Option(name: .long, help: "Add the new contact to this group id.") var group: String?
    @Option(name: .long, help: "Create in this container id (default: the default container).") var container: String?

    func run() throws {
        try runGuarded(tool: "contacts") {
            var fields: ContactFields
            if let json {
                fields = try ContactFields.fromJSON(json)
            } else {
                fields = ContactFields()
                fields.given_name = first; fields.family_name = last; fields.middle_name = middle
                fields.name_prefix = prefix; fields.name_suffix = suffix; fields.nickname = nickname
                fields.organization = organization; fields.job_title = title; fields.department = department
                if !phone.isEmpty { fields.phones = parseLabeledScalars(phone) }
                if !email.isEmpty { fields.emails = parseLabeledScalars(email) }
                if !url.isEmpty { fields.urls = parseLabeledScalars(url) }
                if let birthday { fields.birthday = try parseBirthday(birthday) }
            }
            try validateCreateInput(fields)

            let gate = try resolveWrite(global, labeledName: primaryName(fields))
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "create_contact", group_id: group, container_id: container, fields: fields,
                    // --group targets an EXISTING group, so the sandbox's label check on it needs
                    // a store read the preview does not take.
                    gate_note: gate.sandboxActive && group != nil
                        ? sandboxTargetUncheckedNote("the --group target") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive, let group { try store.requireLabeledGroupTarget(group, prefix: TestMode.sandboxPrefix) }
            let id = try store.createContact(fields: fields, groupIdentifier: group, containerIdentifier: container)
            try emitContactsWrite(global, CreateContactResult(identifier: id, group_id: group, container_id: container),
                                  sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - update → update_contact

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a contact, None=skip/\"\"=clear/value=set (EXECUTES; --dry-run previews). → update_contact")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    @Option(name: .long, parsing: .upToNextOption, help: "Set a simple field: key=value (repeatable).") var set: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Clear a field to empty (repeatable).") var clear: [String] = []
    @Option(name: .long, help: "Full field set as a JSON blob (presence = touch; \"\"/[] = clear).") var json: String?

    func run() throws {
        try runGuarded(tool: "contacts") {
            let fields = try buildUpdateFields()
            try validateUpdateInput(identifier: identifier, fields)

            let gate = try resolveWrite(global)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "update_contact", identifier: identifier, fields: fields,
                    gate_note: gate.sandboxActive ? sandboxTargetUncheckedNote("the target contact") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledContactTarget(identifier, prefix: TestMode.sandboxPrefix) }
            let id = try store.updateContact(identifier: identifier, fields: fields)
            try emitContactsWrite(global, IdentifierResult(identifier: id), sandboxActive: gate.sandboxActive)
        }
    }

    private func buildUpdateFields() throws -> ContactFields {
        if let json { return try ContactFields.fromJSON(json) }
        var fields = ContactFields()
        for entry in set {
            guard let idx = entry.firstIndex(of: "=") else {
                throw AppleError.validation("--set expects key=value, got '\(entry)'")
            }
            let key = String(entry[..<idx]); let value = String(entry[entry.index(after: idx)...])
            guard let kp = simpleFieldKeyPaths[key] else {
                throw AppleError.validation("--set only supports simple string fields; use --json for '\(key)'")
            }
            fields[keyPath: kp] = value
        }
        for key in clear {
            if let kp = simpleFieldKeyPaths[key] { fields[keyPath: kp] = ""; continue }
            switch key {
            case "phones": fields.phones = []
            case "emails": fields.emails = []
            case "urls": fields.urls = []
            case "postal_addresses": fields.postal_addresses = []
            case "dates": fields.dates = []
            case "social_profiles": fields.social_profiles = []
            case "relations": fields.relations = []
            case "instant_messages": fields.instant_messages = []
            case "birthday": fields.birthday = BirthdayInput()
            default: throw AppleError.validation("unknown field to clear: '\(key)'")
            }
        }
        return fields
    }
}

// MARK: - delete → delete_contact (env-gated, mirroring the MCP's require_test_mode_for)

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a contact (requires APPLE_TEST_MODE=1, like the MCP). → delete_contact")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    // Accepted and echoed, NOT enforced — a deliberate divergence, documented in
    // docs/port-specs/contacts.md. The oracle's group_identifier is a shibboleth: it is
    // compared to CONTACTS_TEST_GROUP and never checked against the target contact
    // (check_test_mode_safety, security.py:83-101), so honoring it literally would add no
    // target scoping. This CLI confines the TARGET itself instead, which the oracle never does.
    @Option(name: .long, help: "Group assertion; accepted and echoed for MCP parity, not enforced.")
    var group: String?
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let gate = try resolveWrite(global)
            // Read the operator affordance BEFORE any store work, so the preview and the
            // execute path decide from the same value.
            let envGranted = contactsDeleteEnvGranted
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "delete_contact", identifier: identifier, group_id: group,
                    gate_note: joinedGateNote([
                        envGranted ? nil : contactsDeleteGateMessage("delete_contact"),
                        gate.sandboxActive ? sandboxTargetUncheckedNote("the target contact") : nil,
                    ])), sandboxActive: gate.sandboxActive)
                return
            }
            guard envGranted else { throw AppleError.safetyViolation(contactsDeleteGateMessage("delete_contact")) }
            let store = ContactsStore()
            try store.requireAuthorization()
            // The env gate above implies the sandbox is engaged (sandboxActive = flag || env),
            // so this label check always runs here; the condition documents the dependency
            // rather than relying on it.
            if gate.sandboxActive { try store.requireLabeledContactTarget(identifier, prefix: TestMode.sandboxPrefix) }
            let id = try store.deleteContact(identifier: identifier)
            try emitContactsWrite(global, IdentifierResult(identifier: id), sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - note set → write_note (AppleScript)

struct NoteSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Write/replace a contact's note, --clear empties it (EXECUTES; --dry-run previews). → write_note")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    // `--note`, not `--text`: `--text` is the repo-wide human-output global (GlobalOptions).
    @Option(name: .long, help: "The note text.") var note: String?
    @Option(name: .long, help: "Read the note text from this file.") var file: String?
    @Flag(name: .long, help: "Clear the note (empty string).") var clear = false
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let noteText = try resolveNoteText()
            let gate = try resolveWrite(global)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "write_note", identifier: identifier, note: noteText,
                    gate_note: gate.sandboxActive ? sandboxTargetUncheckedNote("the target contact") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledContactTarget(identifier, prefix: TestMode.sandboxPrefix) }
            try store.writeNote(identifier, note: noteText)
            try emitContactsWrite(global, IdentifierResult(identifier: identifier), sandboxActive: gate.sandboxActive)
        }
    }
    private func resolveNoteText() throws -> String {
        let provided = [note != nil, file != nil, clear].filter { $0 }.count
        guard provided == 1 else {
            throw AppleError.validation("exactly one of --note, --file, or --clear is required")
        }
        if clear { return "" }
        if let note { return note }
        return String(decoding: try readBoundedFile(file!, "note"), as: UTF8.self)
    }
}

// MARK: - photo set → write_photo

struct PhotoSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set/clear a contact's photo, --file|--base64|--clear (EXECUTES; --dry-run previews). → write_photo")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var identifier: String
    @Option(name: .long, help: "Read image bytes from this file.") var file: String?
    @Option(name: .long, help: "Image bytes as a base64 string.") var base64: String?
    @Flag(name: .long, help: "Clear the existing photo.") var clear = false
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let imageData = try resolveImageData()
            let gate = try resolveWrite(global)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "write_photo", identifier: identifier, clears_photo: imageData == nil,
                    gate_note: gate.sandboxActive ? sandboxTargetUncheckedNote("the target contact") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledContactTarget(identifier, prefix: TestMode.sandboxPrefix) }
            let id = try store.writePhoto(identifier: identifier, imageData: imageData)
            try emitContactsWrite(global, IdentifierResult(identifier: id), sandboxActive: gate.sandboxActive)
        }
    }
    private func resolveImageData() throws -> Data? {
        let provided = [file != nil, base64 != nil, clear].filter { $0 }.count
        guard provided == 1 else {
            throw AppleError.validation("exactly one of --file, --base64, or --clear is required")
        }
        if clear { return nil }
        if let base64 {
            try checkBoundedInput(base64, "--base64")
            guard let d = Data(base64Encoded: base64, options: []) else {
                throw AppleError.validation("image_data is not valid base64")
            }
            return d
        }
        return try readBoundedFile(file!, "image")
    }
}

// MARK: - vcard import → import_vcard

struct VCardImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import contacts from vCard 3.0/4.0 text, atomic (EXECUTES; --dry-run previews). → import_vcard")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Read vCard text from this file.") var file: String?
    // `--vcard`, not `--text`: `--text` is the repo-wide human-output global (GlobalOptions).
    @Option(name: .long, help: "vCard text inline.") var vcard: String?
    @Option(name: .long, help: "Add every imported contact to this group id.") var group: String?
    func run() throws {
        try runGuarded(tool: "contacts") {
            let vcardText = try resolveVCardText()
            if vcardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppleError.validation("vcard_text must be a non-empty string")
            }
            let gate = try resolveWrite(global)
            // Sandbox card-label check: every imported card must be labeled test data, or the
            // WHOLE atomic import is refused — never leave unlabeled real-looking contacts that
            // prefix-based cleanup would then miss. `vcardPrimaryNames` is a static parse that
            // never touches the store, so this runs on BOTH paths: a sandboxed preview refuses
            // exactly what the execute path refuses, at the same exit code.
            if gate.sandboxActive {
                for name in try ContactsStore.vcardPrimaryNames(text: vcardText) {
                    guard ContactsLabel.isLabeled(name, prefix: TestMode.sandboxPrefix) else {
                        throw AppleError.safetyViolation(
                            "refusing to import the unlabeled contact '\(name)': in the sandbox every "
                            + "imported card's name must start with '\(TestMode.sandboxPrefix)'.")
                    }
                }
            }
            guard gate.willExecute else {
                // Validate the payload parses (TCC-free) so a dry-run catches malformed
                // vCard exactly as the execute path would — the MCP always parses.
                let count = try ContactsStore.validateVCard(text: vcardText)
                try emitContactsWrite(global, DryRunPreview(
                    operation: "import_vcard", group_id: group, parsed_count: count,
                    gate_note: gate.sandboxActive && group != nil
                        ? sandboxTargetUncheckedNote("the --group target") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            // A --group target must itself be a labeled test group: never add to a real one.
            if gate.sandboxActive, let group { try store.requireLabeledGroupTarget(group, prefix: TestMode.sandboxPrefix) }
            let ids = try store.importVCard(text: vcardText, groupIdentifier: group)
            try emitContactsWrite(global, ImportVCardResult(identifiers: ids, count: ids.count, group_id: group),
                                  sandboxActive: gate.sandboxActive)
        }
    }
    private func resolveVCardText() throws -> String {
        let provided = [file != nil, vcard != nil].filter { $0 }.count
        guard provided == 1 else {
            throw AppleError.validation("exactly one of --file or --vcard is required")
        }
        if let vcard { return vcard }
        return String(decoding: try readBoundedFile(file!, "vcard"), as: UTF8.self)
    }
}

// MARK: - groups create → create_group

struct GroupsCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a contact group (EXECUTES by default; --dry-run previews). → create_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The new group's name.") var name: String
    @Option(name: .long, help: "Create in this container id (default: the default container).") var container: String?
    func run() throws {
        try runGuarded(tool: "contacts") {
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("name must be a non-empty string")
            }
            let gate = try resolveWrite(global, labeledName: name)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "create_group", container_id: container, name: name),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            let g = try store.createGroup(name: name, containerIdentifier: container)
            try emitContactsWrite(global, GroupResult(group: g), sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - groups rename → rename_group

struct GroupsRenameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a contact group (EXECUTES by default; --dry-run previews). → rename_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The group's CN identifier.") var identifier: String
    @Argument(help: "The new name.") var newName: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            if newName.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("new_name must be a non-empty string")
            }
            let gate = try resolveWrite(global)
            // Result must STAY labeled — a sandbox rename to an unlabeled name would create
            // real-looking data that prefix-based cleanup then misses. Pure string check, so it
            // runs on BOTH paths: the preview refuses exactly what the execute path refuses.
            if gate.sandboxActive {
                guard ContactsLabel.isLabeled(newName, prefix: TestMode.sandboxPrefix) else {
                    throw AppleError.safetyViolation(
                        "refusing to rename a test group to the unlabeled name '\(newName)': in the "
                        + "sandbox it must stay prefixed with '\(TestMode.sandboxPrefix)'.")
                }
            }
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "rename_group", identifier: identifier, new_name: newName,
                    gate_note: gate.sandboxActive ? sandboxTargetUncheckedNote("the target group") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledGroupTarget(identifier, prefix: TestMode.sandboxPrefix) }
            let g = try store.renameGroup(identifier: identifier, newName: newName)
            try emitContactsWrite(global, GroupResult(group: g), sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - groups delete → delete_group (env-gated, mirroring the MCP's require_test_mode_for)

struct GroupsDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a group, members persist (requires APPLE_TEST_MODE=1, like the MCP). → delete_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The group's CN identifier.") var identifier: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("identifier must be a non-empty string")
            }
            let gate = try resolveWrite(global)
            let envGranted = contactsDeleteEnvGranted
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "delete_group", identifier: identifier,
                    gate_note: joinedGateNote([
                        envGranted ? nil : contactsDeleteGateMessage("delete_group"),
                        gate.sandboxActive ? sandboxTargetUncheckedNote("the target group") : nil,
                    ])), sandboxActive: gate.sandboxActive)
                return
            }
            guard envGranted else { throw AppleError.safetyViolation(contactsDeleteGateMessage("delete_group")) }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledGroupTarget(identifier, prefix: TestMode.sandboxPrefix) }
            let id = try store.deleteGroup(identifier: identifier)
            try emitContactsWrite(global, IdentifierResult(identifier: id), sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - groups add → add_contact_to_group

struct GroupsAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a contact to a group, additive (EXECUTES; --dry-run previews). → add_contact_to_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var contactId: String
    @Argument(help: "The group's CN identifier.") var groupId: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            try requireNonEmptyPair(contactId, groupId)
            let gate = try resolveWrite(global)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "add_contact_to_group", contact_identifier: contactId, group_identifier: groupId,
                    gate_note: gate.sandboxActive
                        ? sandboxTargetUncheckedNote("both the target contact and the target group") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive {
                try store.requireLabeledGroupTarget(groupId, prefix: TestMode.sandboxPrefix)
                // Both sides labeled: add only a test contact to a test group (remove needs only
                // the group check — it just detaches from an already-verified test group).
                try store.requireLabeledContactTarget(contactId, prefix: TestMode.sandboxPrefix)
            }
            try store.addContactToGroup(contactIdentifier: contactId, groupIdentifier: groupId)
            try emitContactsWrite(global, MembershipResult(contact_identifier: contactId, group_identifier: groupId),
                                  sandboxActive: gate.sandboxActive)
        }
    }
}

// MARK: - groups remove → remove_contact_from_group (AppleScript)

struct GroupsRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a contact from a group (EXECUTES; --dry-run previews). → remove_contact_from_group")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The contact's CN identifier.") var contactId: String
    @Argument(help: "The group's CN identifier.") var groupId: String
    func run() throws {
        try runGuarded(tool: "contacts") {
            try requireNonEmptyPair(contactId, groupId)
            let gate = try resolveWrite(global)
            guard gate.willExecute else {
                try emitContactsWrite(global, DryRunPreview(
                    operation: "remove_contact_from_group", contact_identifier: contactId, group_identifier: groupId,
                    gate_note: gate.sandboxActive ? sandboxTargetUncheckedNote("the target group") : nil),
                    sandboxActive: gate.sandboxActive)
                return
            }
            let store = ContactsStore()
            try store.requireAuthorization()
            if gate.sandboxActive { try store.requireLabeledGroupTarget(groupId, prefix: TestMode.sandboxPrefix) }
            try store.removeContactFromGroup(contactIdentifier: contactId, groupIdentifier: groupId)
            try emitContactsWrite(global, MembershipResult(contact_identifier: contactId, group_identifier: groupId),
                                  sandboxActive: gate.sandboxActive)
        }
    }
}

private func requireNonEmptyPair(_ contactId: String, _ groupId: String) throws {
    if contactId.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AppleError.validation("contact_identifier must be a non-empty string")
    }
    if groupId.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AppleError.validation("group_identifier must be a non-empty string")
    }
}
