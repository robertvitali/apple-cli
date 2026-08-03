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

/// Emit a messages WRITE result, tagging the envelope when the sandbox is engaged so a caller can
/// tell a restricted send from a normal one without re-reading the environment.
private func emitWrite<T: Encodable>(_ global: GlobalOptions, _ data: T, sandboxActive: Bool,
                                     text: () -> String) throws {
    if global.json {
        try Output.emit(tool: tool, data: data, sandboxActive: sandboxActive)
    } else {
        let line = (sandboxActive ? "[sandbox] " : "") + text()
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md)

enum MessagesWriteGuard {
    /// The resolved write posture for one messages command. Bound ONCE at the top of the write
    /// `run()` and threaded from there — never re-derived mid-command.
    struct Gate {
        let willExecute: Bool
        let sandboxActive: Bool
    }

    /// Resolve a messages write under write-model v2: **it sends when invoked**, exactly as calling
    /// `mac_messages_mcp`'s `tool_send_message` does. `--dry-run` previews; `APPLE_DRY_RUN` truthy
    /// restores dry-run-by-default; `APPLE_TEST_MODE` truthy or `--test-mode` engages the opt-in
    /// sandbox, which confines recipients to `APPLE_TEST_RECIPIENTS`.
    ///
    /// ORACLE EVIDENCE (`mac_messages_mcp` @ 99388d2, source read on disk at
    /// ~/.cache/uv/git-v0/checkouts/08d6af4000976dfd/99388d2, both `mac_messages_mcp/` and
    /// `main.py` confirmed non-empty before believing any negative): `tool_send_message`
    /// (server.py:58-77) calls `send_message(recipient, message, group_chat)` and returns — no
    /// gate, no confirmation, no elicitation. `send_message` (messages.py:602) does
    /// `str(recipient).strip()` and dispatches; it imposes NO length cap, charset rule or
    /// recipient allowlist, so unlike Notes there is no oracle input-bound being dropped here. The
    /// ONLY `os.environ` read in the entire non-test source is `USE_TEST_DATA` (messages.py:375),
    /// a test-fixture switch — there is no env-keyed gate to mirror (contrast Contacts'
    /// `CONTACTS_TEST_MODE`, which IS mirrored and stays). Bucket 3.
    ///
    /// NO `defaultDryRun` PARAMETER, deliberately — `GlobalOptions.willExecute(defaultDryRun:)`
    /// leaves it non-defaulted on purpose and `send` is the only write surface in this domain, so
    /// the signature offers no choice to get wrong. (Same reasoning as CalendarWriteGuard.)
    static func resolve(_ global: GlobalOptions) throws -> Gate {
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)
        return Gate(willExecute: willExecute, sandboxActive: sandboxActive)
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
            guard (1...10_000).contains(limit) else {
                throw AppleError.validation("limit must be between 1 and 10000")
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
            // Echo the effective filter (contact OR handle) so a `--handle`-only
            // invocation yields a self-describing envelope instead of contact:null.
            try emit(global, RecentData(hours: hours, limit: limit, contact: filter,
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
        abstract: "Send an iMessage/SMS (sends on call, like the MCP; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Recipient: phone, email, contact name, or (with --group) a chat id.") var recipient: String
    @Option(name: [.short, .long], help: "Message body.") var message: String
    @Flag(name: [.short, .long], help: "Treat the recipient as a group chat id.") var group = false

    func run() throws {
        try runGuarded(tool: tool) {
            // Bound ONCE, before any resolution work, and threaded from here.
            let gate = try MessagesWriteGuard.resolve(global)
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
                // The recipient is argv-derived and already resolved, so the sandbox allowlist is
                // computable on BOTH paths — run it BEFORE the preview branch so a dry-run refuses
                // exactly what an execute would. A preview that reported "would send" for a
                // recipient the execute path will refuse is a lie, and on a SEND surface that lie
                // is the one most likely to be acted on.
                do {
                    try Send.assertAllowedRecipient(handle, sandboxActive: gate.sandboxActive)
                } catch {
                    throw AppleError.validation("refusing send: \(String(describing: error))")
                }

                guard gate.willExecute else {
                    let preview = SendPreview(action: "send", executed: false, dry_run: true,
                        group_chat: group, recipient: recipient, resolved_handle: handle,
                        display_name: displayName, service_plan: plan, message: message,
                        note: "Dry run — nothing sent. Re-run without --dry-run to send.")
                    try emitWrite(global, preview, sandboxActive: gate.sandboxActive) {
                        "[dry-run] would send to \(displayName ?? handle) (\(handle)) via \(plan): \(message)"
                    }
                    return
                }
                let result = try Send.perform(handle: handle, message: message, groupChat: group)
                guard result.ok else {
                    // Keep the raw osascript error text OFF the JSON envelope (unstable +
                    // potential info-leak); surface it on stderr (the human channel) only.
                    if let raw = result.error {
                        FileHandle.standardError.write(Data(("osascript: " + raw + "\n").utf8))
                    }
                    throw AppleError.upstream("send failed (Messages returned an error)")
                }
                let data = SendResult(action: "send", executed: true, ok: true, group_chat: group,
                    recipient: recipient, resolved_handle: handle, display_name: displayName,
                    service_used: result.service, message: message)
                try emitWrite(global, data, sandboxActive: gate.sandboxActive) {
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
            // Same bound, same unit, as `search` — `matchContacts` runs difflib's O(n*m)
            // matcher per token AND once per full name, for EVERY candidate, so an unbounded
            // query is worse here than on search. Measured post-Q5d against 200 candidates:
            // a 500,000-scalar conjoining-jamo query takes 9.95s, and a real address book is
            // an order of magnitude larger. (Combining marks do NOT amplify — `cleanName`
            // deletes them, taking 500,001 scalars to 1 in 0.025s — but Unicode LETTERS
            // survive cleaning, so the bound cannot rely on the cleaner.)
            guard name.unicodeScalars.count <= 1024 else {
                throw AppleError.validation("name too long (max 1024 code points)")
            }
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
            // Cap term length: an unbounded term drives O(term·window) WRatio work over
            // up to 10k rows (a ~40KB term measured ~30s CPU) — a local DoS.
            // COUNT SCALARS, not Characters — this must be the same unit the scorer uses.
            // `Fuzzy` counts code points (Q5c), and a single grapheme cluster can hold
            // unboundedly many of them: "a" + 999 combining acutes is ONE Character and 1000
            // code points, so a 1024-Character term can carry 1,024,000 scalars into an
            // O(term x body) LCS — a 1000x amplification straight through this guard.
            guard term.unicodeScalars.count <= 1024 else {
                throw AppleError.validation("search term too long (max 1024 code points)")
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
            // Order samples by (last name, first name) to match the oracle's SQL
            // `ORDER BY ZLASTNAME, ZFIRSTNAME`. `count` is the contract; this aligns the
            // illustrative "first 10" sample set with the MCP's too (handle-key tiebreak).
            let samples = book.contacts.keys.sorted { a, b in
                let la = (book.details[a]?.lastName ?? "").lowercased()
                let lb = (book.details[b]?.lastName ?? "").lowercased()
                if la != lb { return la < lb }
                let fa = (book.details[a]?.firstName ?? "").lowercased()
                let fb = (book.details[b]?.firstName ?? "").lowercased()
                if fa != fb { return fa < fb }
                return a < b
            }.prefix(10).map { ContactsCheckData.Sample(number: $0, name: book.contacts[$0] ?? "") }
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
