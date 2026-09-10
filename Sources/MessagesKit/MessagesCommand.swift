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

/// The I/O edges of `apple messages`, bound once per invocation. Production has exactly ONE
/// value — `.live` — and no flag or environment variable can select another; the seam exists so
/// the logic tier can drive every command against synthetic SQLite fixtures and fake senders
/// instead of the real chat.db, AddressBook and `osascript`.
struct MessagesCommandDependencies: Sendable {
    var loadAddressBook: @Sendable () -> AddressBook
    var makeChatDB: @Sendable (AddressBook) throws -> ChatDB
    /// One send, whole: body and every attachment in a single osascript run. The argument is a
    /// `Send.Request` rather than five positionals because handle/message and groupChat/service
    /// are otherwise adjacent same-typed parameters on the one surface that reaches a real human.
    var performSend: @Sendable (Send.Request) throws -> Send.Outcome
    var dbDiagnostic: @Sendable () -> ChatDB.DBCheck
    var addressBookDiagnostic: @Sendable () -> AddressBook.Diagnostic
    var hasFullDiskAccess: @Sendable () -> Bool
    /// Resolves the write posture (execute-vs-preview, sandbox, sandbox recipient allowlist) for
    /// `send`. Injected for the same reason `TestMode.sandboxActive(flag:envVar:)` and
    /// `GlobalOptions.willExecute(defaultDryRun:envVar:)` carry `envVar:` seams: the resolution
    /// reads THREE process-wide variables (`APPLE_TEST_MODE`, `APPLE_DRY_RUN`,
    /// `APPLE_TEST_RECIPIENTS`), swift-testing runs suites in parallel, and a send test that
    /// `setenv`-ed any of them would race every other reader. Production always uses
    /// `MessagesWriteGuard.resolve` via `.live`.
    var resolveGate: @Sendable (GlobalOptions) throws -> MessagesWriteGuard.Gate

    static let live = MessagesCommandDependencies(
        loadAddressBook: AddressBook.load,
        makeChatDB: { try ChatDB(book: $0) },
        performSend: Send.perform,
        dbDiagnostic: { ChatDB.diagnose() },
        addressBookDiagnostic: AddressBook.diagnose,
        hasFullDiskAccess: Permissions.hasFullDiskAccess,
        // Wrapped rather than referenced directly: `resolve` carries a default argument (the
        // allowlist-reader seam), and a Swift function reference cannot elide one.
        resolveGate: { try MessagesWriteGuard.resolve($0) }
    )
}

/// Emit JSON (default) or a human text rendering (`--text`) on stdout.
private func emit<T: Encodable>(_ global: GlobalOptions, _ data: T, text: () -> String) throws {
    if global.json {
        try Output.emit(tool: tool, data: data)
    } else {
        Output.printText(text())
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
        Output.printText(line)
    }
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md)

enum MessagesWriteGuard {
    /// The resolved write posture for one messages command. Bound ONCE at the top of the write
    /// `run()` and threaded from there — never re-derived mid-command.
    /// `Equatable` so a test can pin the `.live` binding by comparing what
    /// `MessagesCommandDependencies.live.resolveGate` returns against `resolve`'s own result for
    /// the same options — proving the binding without reading or mutating any environment
    /// variable of its own.
    struct Gate: Sendable, Equatable {
        let willExecute: Bool
        let sandboxActive: Bool
        /// The sandbox recipient allowlist (`APPLE_TEST_RECIPIENTS`), captured HERE rather than
        /// re-read at the guard, so the whole write posture is bound once — and so the logic tier
        /// can exercise the sandbox refusal branch without mutating a process-wide variable.
        let allowedRecipients: [String]
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
    /// The process-wide allowlist reader this gate captures. Named here so `resolve`'s seam has a
    /// production default that is one identifier long and visibly the real thing.
    static let processAllowedRecipients: @Sendable () -> [String] = { TestMode.allowedRecipients }

    /// `allowedRecipients` is a seam in the same family as `TestMode.sandboxActive(flag:envVar:)`
    /// and `GlobalOptions.willExecute(defaultDryRun:envVar:)`, but it injects the READER rather
    /// than a variable NAME: `TestMode.allowedRecipients` is a fixed-name property in AppleKit, so
    /// a name-parameterized seam would have to fork its comma-split/trim parsing into this target
    /// — two implementations of one recipient allowlist on a send surface. Production passes
    /// nothing and goes through `TestMode.allowedRecipients` unchanged; the logic tier injects a
    /// known list, so the capture is covered without `setenv`-ing `APPLE_TEST_RECIPIENTS`, which
    /// swift-testing's parallel suites all share.
    static func resolve(_ global: GlobalOptions,
                        allowedRecipients: @Sendable () -> [String] = processAllowedRecipients) throws -> Gate {
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)
        return Gate(willExecute: willExecute, sandboxActive: sandboxActive,
                    allowedRecipients: allowedRecipients())
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            guard hours >= 0 else { throw AppleError.validation("hours cannot be negative") }
            guard hours <= MessageTime.maxHours else {
                throw AppleError.validation("hours too large (max \(MessageTime.maxHours) = 10 years)")
            }
            guard (1...10_000).contains(limit) else {
                throw AppleError.validation("limit must be between 1 and 10000")
            }
            let book = dependencies.loadAddressBook()
            // EAGER, deliberately. An inaccessible chat.db must produce its upstream error before
            // any contact-filter branch can return success — making this lazy would let an
            // unmatched or ambiguous `--contact` exit 0 on a machine where the database cannot be
            // opened at all, which is a behavior change from the oracle-parity contract.
            var db = try dependencies.makeChatDB(book)

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
        + attachmentSuffix(m.attachments, hasAttachments: m.has_attachments, body: m.body)
}

/// Human-view annotation for attached files. An attachment-only message has an EMPTY body,
/// so without this `--text` prints a bare "Sender: " and the human loses the only content the
/// message had. Kept out of the JSON path entirely — `--text` is not the versioned contract.
func attachmentSuffix(_ atts: [ChatDB.Attachment], hasAttachments: Bool, body: String) -> String {
    let lead = body.isEmpty ? "" : " "
    if !atts.isEmpty {
        let names = atts.map { attachmentName($0.transfer_name) ?? attachmentBasename($0.filename) ?? "attachment" }
        return "\(lead)[\(names.count) attachment\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))]"
    }
    // `cache_has_attachments` set but the join gave nothing (pruned row, unreadable table):
    // still say so rather than render a message that looks empty for no stated reason.
    return hasAttachments ? "\(lead)[attachment]" : ""
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func attachmentName(_ value: String?) -> String? {
    guard let value else { return nil }
    let scalars = value.unicodeScalars.map { scalar in
        isUnsafeAttachmentDisplayScalar(scalar)
            ? " "
            : String(scalar)
    }.joined()
    let collapsed = scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return nonEmpty(collapsed)
}

private func isUnsafeAttachmentDisplayScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.controlCharacters.contains(scalar)
        // Unicode format controls include bidi overrides/isolates and zero-width joiners.
        // They are legal filename text, but unsafe in human terminal output because they
        // can visually hide or reorder the displayed transfer name/extension.
        || scalar.properties.generalCategory == .format
}

private func attachmentBasename(_ value: String?) -> String? {
    guard let cleaned = attachmentName(value) else { return nil }
    return nonEmpty(URL(fileURLWithPath: cleaned).lastPathComponent)
}

/// The `--text` rendering of what a send carries: the body, then the attachment count and paths.
/// Both halves are optional, so a file-only send reads as `[2 file(s): …]` rather than as a blank.
private func sendBodyDescription(message: String?, files: [String]) -> String {
    var parts: [String] = []
    if let message { parts.append(message) }
    if !files.isEmpty {
        parts.append("[\(files.count) file(s): \(files.joined(separator: ", "))]")
    }
    return parts.joined(separator: " ")
}

/// Turn a failed send into the `upstream_error` a caller can act on.
///
/// A multi-part send is not atomic: Messages accepts the body and each attachment as separate
/// transfers, so a failure at attachment 3 leaves the body and attachments 1–2 DELIVERED. The
/// error therefore names which attachment failed, how many went out before it, and — in
/// `error.applied`, the same field a partial bulk Mail mutation uses — the exact paths already
/// delivered, because a retry that includes them sends them a second time rather than updating
/// anything.
///
/// When the failure was not during a file send (the body failed, or the recipient could not be
/// resolved on the requested service) nothing was delivered and the generic message stands.
private func sendFailure(_ outcome: Send.Outcome, files: [String]) -> AppleError {
    guard let failed = outcome.failedFile, files.indices.contains(failed - 1) else {
        return AppleError.upstream("send failed (Messages returned an error)")
    }
    let delivered = Array(files.prefix(outcome.filesSent))
    return AppleError(
        type: AppleErrorType.upstream,
        message: "send failed on attachment \(failed) of \(files.count) ('\(files[failed - 1])') — "
            + "files_sent=\(outcome.filesSent). Anything already delivered is listed in `applied`; "
            + "EXCLUDE it from a retry, because a resend is a second message, not an update.",
        exitCode: AppleExit.upstream,
        applied: delivered.isEmpty ? nil : delivered)
}

// MARK: - send (tool_send_message) — GUARDED

struct Send_: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send an iMessage/SMS (sends on call, like the MCP; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Recipient: phone, email, contact name, or (with --group) a chat id.") var recipient: String
    @Option(name: [.short, .long],
            help: "Message body. Optional when --file is given; a send needs a body, a file, or both.")
    var message: String?
    @Flag(name: [.short, .long], help: "Treat the recipient as a group chat id.") var group = false
    @Option(name: .long,
            help: "Which service a one-to-one send may use: auto (default — iMessage first, then SMS for a phone number), imessage (iMessage only, no fallback), or sms (SMS only). Accepted but ignored with --group: a chat id already names the chat's own service.")
    var service: String = Send.Service.auto.rawValue
    @Option(name: .long,
            help: "Path to a file to send as an attachment. Repeat to send several; each is sent after the message body, in the order given.")
    var file: [String] = []

    func run() throws {
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            // Bound ONCE, before any resolution work, and threaded from here.
            let gate = try dependencies.resolveGate(global)
            guard let serviceMode = Send.Service(rawValue: service) else {
                throw AppleError.validation("service must be one of: \(Send.Service.allNames)")
            }
            // `--message` is optional now, so a send with NEITHER a body nor a file would
            // otherwise dispatch an osascript run that delivers nothing and reports success.
            // The test is on PRESENCE, not emptiness: `--message ""` still means "send this
            // (empty) body", exactly as it did when `--message` was mandatory.
            guard message != nil || !file.isEmpty else {
                throw AppleError.validation("nothing to send: pass --message, --file, or both")
            }
            // EVERY attachment is validated before ANY of them is dispatched. Validating lazily
            // would let a typo in the third path surface only after the body and two files had
            // already been delivered — an unrecoverable half-send for a free-to-catch mistake.
            let files = try file.map { try Send.resolveAttachment($0) }
            let book = dependencies.loadAddressBook()
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
                // A group send's service is the chat's own; `--service` is accepted there (so one
                // flag set works for both shapes) and has no effect.
                let plan = group ? "group chat" : serviceMode.plan
                // The recipient is argv-derived and already resolved, so the sandbox restriction is
                // computable on BOTH paths — run it BEFORE the preview branch so a dry-run refuses
                // exactly what an execute would. A preview that reported "would send" for a
                // recipient the execute path will refuse is a lie, and on a SEND surface that lie
                // is the one most likely to be acted on. `groupChat:` is threaded in because the
                // sandbox refuses group send OUTRIGHT (no self-addressed shape) rather than
                // trusting the allowlist compare to miss a chat id.
                do {
                    try Send.assertAllowedRecipient(handle, groupChat: group,
                                                    sandboxActive: gate.sandboxActive,
                                                    allowedRecipients: gate.allowedRecipients)
                } catch {
                    // assertAllowedRecipient only throws under the sandbox — either the structural
                    // group-chat refusal or the self-only allowlist miss — so this is a sandbox
                    // refusal (Q14): carries error.sandbox, keeps exit 64. `String(describing:)`
                    // renders the AllowError case, so the two refusals stay distinguishable to the
                    // caller instead of collapsing into one message.
                    throw AppleError(type: AppleErrorType.validation,
                        message: "refusing send: \(String(describing: error))",
                        exitCode: AppleExit.usage, sandbox: true)
                }

                guard gate.willExecute else {
                    let preview = SendPreview(action: "send", executed: false, dry_run: true,
                        group_chat: group, recipient: recipient, resolved_handle: handle,
                        display_name: displayName, service_plan: plan,
                        service_requested: serviceMode.rawValue, message: message, files: files,
                        note: "Dry run — nothing sent. Re-run without --dry-run to send.")
                    try emitWrite(global, preview, sandboxActive: gate.sandboxActive) {
                        "[dry-run] would send to \(displayName ?? handle) (\(handle)) via \(plan): "
                            + sendBodyDescription(message: message, files: files)
                    }
                    return
                }
                let result = try dependencies.performSend(
                    Send.Request(handle: handle, message: message, files: files,
                                 groupChat: group, service: serviceMode))
                guard result.ok else {
                    // Keep the raw osascript error text OFF the JSON envelope (unstable +
                    // potential info-leak); surface it on stderr (the human channel) only.
                    if let raw = result.error {
                        Output.writeError(Data(("osascript: " + raw + "\n").utf8))
                    }
                    throw sendFailure(result, files: files)
                }
                let data = SendResult(action: "send", executed: true, ok: true, group_chat: group,
                    recipient: recipient, resolved_handle: handle, display_name: displayName,
                    service_used: result.service, service_requested: serviceMode.rawValue,
                    message: message, files: files, files_sent: result.filesSent)
                // Q12: the execute envelope carries the v2 `dry_run: false` discriminator like
                // every other domain (SendPreview already carries dry_run: true).
                try emitWrite(global, ExecutedWrite(data), sandboxActive: gate.sandboxActive) {
                    "Message sent successfully via \(result.service ?? "Messages") to \(displayName ?? handle)"
                        + (files.isEmpty ? "" : " (\(result.filesSent) of \(files.count) file(s) sent)")
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
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
            let book = dependencies.loadAddressBook()
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let book = dependencies.loadAddressBook()
            let db = try dependencies.makeChatDB(book)
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppleError.validation("search term cannot be empty")
            }
            // Cap term length: an unbounded term drives O(term·window) WRatio work over
            // up to 10k rows (a ~40KB term measured ~30s CPU) — a local DoS.
            // KEPT, always — `write-model-v2.md` bucket 1: "refusing an attack path the oracle
            // is merely vulnerable to is not a capability drop." MSG-5 called this a bucket-3
            // CLI-only gate that should be sandbox-scoped, but bucket 3 is about CONSENT gates
            // (label guards, recipient allowlists); a resource bound is bucket 1. The oracle has
            // no length limit and simply hangs on the input this rejects.
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
            let book = dependencies.loadAddressBook()
            var db = try dependencies.makeChatDB(book)
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
                        + attachmentSuffix($0.attachments, hasAttachments: $0.has_attachments,
                                           body: $0.body)
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let book = dependencies.loadAddressBook()
            let db = try dependencies.makeChatDB(book)
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let c = dependencies.dbDiagnostic()
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let book = dependencies.loadAddressBook()
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let d = dependencies.addressBookDiagnostic()
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
        try run(dependencies: .live)
    }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let fda = dependencies.hasFullDiskAccess()
            let dbCheck = dependencies.dbDiagnostic()
            let abCheck = dependencies.addressBookDiagnostic()
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
