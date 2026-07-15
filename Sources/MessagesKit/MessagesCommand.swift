import ArgumentParser
import AppleKit
import Foundation

/// `apple messages …` — iMessage / SMS.
///
/// Ports `mac_messages_mcp` (@ 99388d2, 9 tools + 2 resources) to a strict superset.
/// Mechanism: `SQLiteReader` over chat.db (WAL-aware, copyToTemp) for ALL reads +
/// AddressBook `*.abcddb` for contacts (FDA, no Contacts prompt) + `AppleScriptRunner`
/// (argv, injection-proof) for sends. The MCP's stateful `"contact:N"` selector is
/// replaced by stateless ranked JSON candidates + an explicit `--handle`.
///
/// Asana: feat/asana-GID-REDACTED-messages
public struct MessagesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "iMessage / SMS — send, read, search (ports mac_messages_mcp).",
        subcommands: [
            Recent.self, Send_.self, FindContact.self, Chats.self, Search.self,
            CheckAvailability.self, CheckDB.self, CheckContacts.self, CheckAddressBook.self,
            Doctor.self,
        ]
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}

    /// Bare `apple messages` (no subcommand) → JSON error envelope (keeps the shared
    /// smoke test's ok=false contract, and gives agents a machine-readable nudge).
    public func run() throws {
        try runGuarded(tool: "messages") {
            throw AppleError.validation("specify a subcommand: recent, send, find-contact, chats, search, check-availability, check-db, check-contacts, check-addressbook, doctor")
        }
    }
}

// MARK: - Shared output helper

private let tool = "messages"

/// Emit JSON (default) or a human text rendering (`--text`) on stdout.
private func emit<T: Encodable>(_ global: GlobalOptions, _ data: T, text: () -> String) throws {
    if global.json {
        try Output.emit(tool: tool, data: data)
    } else {
        FileHandle.standardOutput.write(Data((text() + "\n").utf8))
    }
}

private func candidateData(_ m: AddressBook.Match) -> ContactCandidateData {
    ContactCandidateData(name: m.name, phone: m.phone, score: m.score, matched_on: m.matchedOn)
}

// MARK: - recent (tool_get_recent_messages)

struct Recent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recent",
        abstract: "Recent messages across ALL chats in the last N hours (optionally by contact).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Hours to look back (default 24).") var hours: Int = 24
    @Option(name: .long, help: "Max messages (default 100).") var limit: Int = 100
    @Option(name: .long, help: "Filter by contact name, phone, or email.") var contact: String?
    @Option(name: .long, help: "Explicit handle (phone/email) — stateless replacement for the MCP's contact:N.") var handle: String?

    func run() throws {
        try runGuarded(tool: tool) {
            guard hours >= 0 else { throw AppleError.validation("hours cannot be negative") }
            guard hours <= MessageTime.maxHours else {
                throw AppleError.validation("hours too large (max \(MessageTime.maxHours) = 10 years)")
            }
            let book = AddressBook.load()
            var db = try ChatDB(book: book)

            var rowIds: [Int64]? = nil
            var candidates: [ContactCandidateData]? = nil
            var note: String? = nil
            let filter = handle ?? contact

            if let filter, !filter.isEmpty {
                // Phone/email-shaped (only [0-9 +-()@.]) → resolve directly; else fuzzy name.
                let isDirect = filter.allSatisfy { $0.isNumber || "+- ()@.".contains($0) }
                if handle != nil || isDirect {
                    rowIds = filter.contains("@") ? db.handleRowIds(forEmail: filter)
                                                  : db.handleRowIds(forPhone: filter)
                    if rowIds?.isEmpty == true { note = "No message history found with '\(filter)'." }
                } else {
                    let matches = book.findByName(filter)
                    if matches.isEmpty {
                        note = "No contacts found matching '\(filter)'."
                        try emit(global, RecentData(hours: hours, limit: limit, contact: filter,
                            resolved_handle_rowids: nil, ambiguous: false, candidates: nil,
                            note: note, count: 0, messages: [])) { note! }
                        return
                    } else if matches.count == 1 {
                        // A single fuzzy match may resolve to an email handle, not a
                        // phone — branch like the MCP does (get_recent_messages).
                        let h = matches[0].phone
                        rowIds = h.contains("@") ? db.handleRowIds(forEmail: h)
                                                 : db.handleRowIds(forPhone: h)
                    } else {
                        candidates = matches.map(candidateData)
                        try emit(global, RecentData(hours: hours, limit: limit, contact: filter,
                            resolved_handle_rowids: nil, ambiguous: true, candidates: candidates,
                            note: "Multiple contacts matched; re-run with --handle <phone/email>.",
                            count: 0, messages: [])) {
                                "Multiple contacts found matching '\(filter)':\n" +
                                matches.enumerated().prefix(10)
                                    .map { "\($0.offset + 1). \($0.element.name) (\($0.element.phone)) - confidence \(String(format: "%.2f", $0.element.score))" }
                                    .joined(separator: "\n")
                            }
                        return
                    }
                }
            }

            let messages = db.recent(hours: hours, handleRowIds: rowIds, limit: limit)
            try emit(global, RecentData(hours: hours, limit: limit, contact: contact,
                resolved_handle_rowids: rowIds, ambiguous: false, candidates: nil,
                note: messages.isEmpty ? (note ?? "No messages found in the specified time period.") : note,
                count: messages.count, messages: messages)) {
                    messages.isEmpty ? "No messages found in the specified time period."
                                     : messages.map(renderMessage).joined(separator: "\n")
                }
        }
    }
}

private func renderMessage(_ m: ChatDB.Message) -> String {
    var prefix = "[\(m.date_local)]"
    if let g = m.group_name { prefix += " [\(g)]" }
    return "\(prefix) \(m.sender): \(m.body)"
}

// MARK: - send (tool_send_message) — GUARDED

struct Send_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send an iMessage/SMS (dry-run by default; --execute + test-mode guard to send).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Recipient: phone, email, contact name, or (with --group) a chat id.") var recipient: String
    @Option(name: [.short, .long], help: "Message body.") var message: String
    @Flag(name: [.short, .long], help: "Treat the recipient as a group chat id.") var group = false

    func run() throws {
        try runGuarded(tool: tool) {
            let book = AddressBook.load()
            switch Send.resolve(recipient: recipient, groupChat: group, book: book) {
            case .notFound(let r):
                throw AppleError.notFound("Could not find any contact matching '\(r)'")
            case .ambiguous(let matches):
                let data = SendAmbiguousData(action: "send", executed: false, ambiguous: true,
                    recipient: recipient, note: "Multiple contacts matched; re-run with an explicit phone/email.",
                    candidates: matches.map(candidateData))
                try emit(global, data) {
                    "Multiple contacts found matching '\(recipient)':\n" +
                    matches.enumerated().prefix(10)
                        .map { "\($0.offset + 1). \($0.element.name) (\($0.element.phone))" }
                        .joined(separator: "\n")
                }
            case .resolved(let handle, let displayName):
                let plan = group ? "group chat" : "iMessage→SMS auto"
                if !global.willExecute {
                    let preview = SendPreview(action: "send", executed: false, dry_run: !global.execute,
                        group_chat: group, recipient: recipient, resolved_handle: handle,
                        display_name: displayName, service_plan: plan, message: message,
                        note: "Dry run — nothing sent. Re-run with --execute (and APPLE_TEST_MODE=1 + an allowlisted recipient) to send.")
                    try emit(global, preview) {
                        "[dry-run] would send to \(displayName ?? handle) (\(handle)) via \(plan): \(message)"
                    }
                    return
                }
                // Live send path — fail-closed guard. AGENTS.md gates writes behind
                // BOTH `--test-mode` AND `APPLE_TEST_MODE=1` + an allowlisted recipient.
                guard global.testMode else {
                    throw AppleError.validation("refusing live send: --test-mode is required for a live send (together with APPLE_TEST_MODE=1 and an allowlisted recipient in APPLE_TEST_RECIPIENTS)")
                }
                do {
                    try TestMode.requireAllowedRecipient(handle)
                } catch {
                    throw AppleError.validation("refusing live send: \(String(describing: error))")
                }
                let result = try Send.perform(handle: handle, message: message, groupChat: group)
                guard result.ok else {
                    throw AppleError.upstream("send failed: \(result.error ?? "unknown error")")
                }
                let data = SendResult(action: "send", executed: true, ok: true, group_chat: group,
                    recipient: recipient, resolved_handle: handle, display_name: displayName,
                    service_used: result.service, message: message)
                try emit(global, data) {
                    "Message sent successfully via \(result.service ?? "Messages") to \(displayName ?? handle)"
                }
            }
        }
    }
}

// MARK: - find-contact (tool_find_contact)

struct FindContact: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-contact",
        abstract: "Fuzzy-search contacts by name/nickname; ranked candidates with confidence scores.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Name to search for.") var name: String

    func run() throws {
        try runGuarded(tool: tool) {
            let book = AddressBook.load()
            let matches = book.findByName(name)
            let data = FindContactData(query: name, count: matches.count, contacts: matches.map(candidateData))
            try emit(global, data) {
                if matches.isEmpty { return "No contacts found matching '\(name)'." }
                return "Found \(matches.count) contacts matching '\(name)':\n" +
                    matches.enumerated().prefix(10)
                        .map { "\($0.offset + 1). \($0.element.name) (\($0.element.phone)) - confidence \(String(format: "%.2f", $0.element.score))" }
                        .joined(separator: "\n")
            }
        }
    }
}

// MARK: - chats (tool_get_chats)

struct Chats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List named group chats (chat_identifier + display_name).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            let book = AddressBook.load()
            let db = try ChatDB(book: book)
            let chats = db.namedChats()
            try emit(global, ChatsData(count: chats.count, chats: chats)) {
                if chats.isEmpty { return "No named group chats found." }
                return "Available group chats:\n" +
                    chats.enumerated()
                        .map { "\($0.offset + 1). \($0.element.display_name) (ID: \($0.element.chat_identifier))" }
                        .joined(separator: "\n")
            }
        }
    }
}

// MARK: - search (tool_fuzzy_search_messages)

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages: fuzzy (WRatio) + threshold + time window (or contains/exact).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Search term.") var term: String
    @Option(name: .long, help: "Hours to look back (default 720 = 30 days; 0 = all time).") var hours: Int = 720
    @Option(name: .long, help: "Fuzzy threshold 0.0–1.0 (default 0.6).") var threshold: Double = 0.6
    @Option(name: .long, help: "Match mode: fuzzy (default) | contains | exact.") var match: String = "fuzzy"

    func run() throws {
        try runGuarded(tool: tool) {
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppleError.validation("search term cannot be empty")
            }
            guard hours >= 0 else { throw AppleError.validation("hours cannot be negative") }
            guard hours <= MessageTime.maxHours else {
                throw AppleError.validation("hours too large (max \(MessageTime.maxHours) = 10 years)")
            }
            guard (0.0...1.0).contains(threshold) else {
                throw AppleError.validation("threshold must be between 0.0 and 1.0")
            }
            guard let mode = ChatDB.SearchMatch(rawValue: match) else {
                throw AppleError.validation("match must be fuzzy, contains, or exact")
            }
            let book = AddressBook.load()
            var db = try ChatDB(book: book)
            let result = db.search(term: term, hours: hours, threshold: threshold, match: mode)
            let data = SearchData(search_term: term, hours: hours, threshold: threshold, match: match,
                count: result.matches.count, scanned: result.scanned, truncated: result.truncated,
                messages: result.matches)
            try emit(global, data) {
                if result.matches.isEmpty { return "No messages found matching '\(term)'." }
                var header = "Found \(result.matches.count) messages matching '\(term)':\n"
                if result.truncated { header += "(Results capped at \(ChatDB.fuzzySoftCap) messages.)\n" }
                return header + result.matches.map {
                    var prefix = "[\($0.date_local)] (Score: \(String(format: "%.2f", $0.score)))"
                    if let g = $0.group_name { prefix += " [\(g)]" }
                    return "\(prefix) \($0.sender): \($0.body)"
                }.joined(separator: "\n")
            }
        }
    }
}

// MARK: - check-availability (tool_check_imessage_availability)

struct CheckAvailability: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-availability",
        abstract: "Check (history-based) whether a recipient has iMessage, else SMS fallback.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Phone or email to check.") var recipient: String

    func run() throws {
        try runGuarded(tool: tool) {
            let book = AddressBook.load()
            let db = try ChatDB(book: book)
            let a = db.availability(recipient: recipient)
            try emit(global, a) { a.recommendation }
        }
    }
}

// MARK: - check-db (tool_check_db_access)

struct CheckDB: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-db",
        abstract: "Diagnose Messages chat.db access + required tables.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            let c = ChatDB.diagnose()
            try emit(global, c) {
                """
                path: \(c.path)
                exists: \(c.exists) · readable: \(c.readable) · connected: \(c.connected)
                tables: \(c.table_count.map(String.init) ?? "?") · message=\(c.has_message_table) handle=\(c.has_handle_table) chat=\(c.has_chat_table)
                messages: \(c.message_count.map(String.init) ?? "?")
                """
            }
        }
    }
}

// MARK: - check-contacts (tool_check_contacts)

struct CheckContacts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-contacts",
        abstract: "Enumerate AddressBook contacts (count + sample number→name entries).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            let book = AddressBook.load()
            let samples = book.contacts.sorted { $0.key < $1.key }.prefix(10)
                .map { ContactsCheckData.Sample(number: $0.key, name: $0.value) }
            let data = ContactsCheckData(count: book.contacts.count, samples: samples)
            try emit(global, data) {
                if book.contacts.isEmpty { return "No contacts found in AddressBook." }
                return "Found \(book.contacts.count) contacts in AddressBook.\nSample entries (first 10):\n" +
                    samples.map { "\($0.number) -> \($0.name)" }.joined(separator: "\n")
            }
        }
    }
}

// MARK: - check-addressbook (tool_check_addressbook)

struct CheckAddressBook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-addressbook",
        abstract: "Diagnose AddressBook *.abcddb access + required tables + contact counts.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            let d = AddressBook.diagnose()
            try emit(global, d) {
                var lines = ["sources dir: \(d.sources_dir) (exists: \(d.sources_dir_exists))",
                             "databases: \(d.database_count)"]
                for db in d.databases {
                    lines.append(" - \(db.path) readable=\(db.readable) connected=\(db.connected) contacts=\(db.contact_count.map(String.init) ?? "?")")
                }
                lines.append("contacts with handles: \(d.contacts_with_handles)")
                return lines.joined(separator: "\n")
            }
        }
    }
}

// MARK: - doctor (EXTRA — combines the 3 diagnostics + FDA preflight)

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "One-shot health check: FDA + chat.db + AddressBook diagnostics.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            let fda = Permissions.hasFullDiskAccess()
            let dbCheck = ChatDB.diagnose()
            let abCheck = AddressBook.diagnose()
            var notes: [String] = []
            if !fda { notes.append("Full Disk Access not detected — grant it to your terminal in System Settings › Privacy & Security › Full Disk Access.") }
            if !dbCheck.connected { notes.append("Messages chat.db not accessible.") }
            if abCheck.contacts_with_handles == 0 { notes.append("No AddressBook contacts with phone/email found.") }
            let data = DoctorData(full_disk_access: fda, messages_db: dbCheck, addressbook: abCheck,
                contacts_with_handles: abCheck.contacts_with_handles, notes: notes)
            try emit(global, data) {
                """
                Full Disk Access: \(fda)
                chat.db: connected=\(dbCheck.connected) messages=\(dbCheck.message_count.map(String.init) ?? "?")
                AddressBook: databases=\(abCheck.database_count) contacts=\(abCheck.contacts_with_handles)
                \(notes.isEmpty ? "All checks passed." : notes.joined(separator: "\n"))
                """
            }
        }
    }
}
