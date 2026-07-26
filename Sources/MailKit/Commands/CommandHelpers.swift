import Foundation
import AppleKit

// Shared helpers for the Mail command tree — kept small + pure where possible.

extension AppleError {
    /// Mail-side safety refusal (mirrors Contacts' `safetyViolation`): a live mutation blocked
    /// by the test-mode / subject-label / recipient guard. Exit 77 (permission-denied) — a
    /// deliberate refusal, not a bug — so callers can distinguish it from a real failure.
    static func mailSafety(_ m: String) -> AppleError {
        .init(type: "safety_violation", message: m, exitCode: AppleExit.permissionDenied)
    }
}

/// Gate a live mutation on an EXISTING message. Requires the two-factor test gate AND that the
/// target's subject is a labeled `apple-cli-test…` item — so an autonomous run can only mutate
/// test data it created, never real mail (AGENTS.md: "modifying any EXISTING real data the run
/// did not create" is a dangerous action). Returns the RFC Message-ID to operate on.
///
/// NOTE (defense-in-depth boundary): the label key is the message SUBJECT, which anyone can set
/// by emailing the operator a message titled `apple-cli-test …`. That is acceptable ONLY because
/// every op gated by this function is REVERSIBLE (mark/flag/move/trash-to-Trash) and the blast
/// radius of a spoofed subject is that one attacker-authored message. This subject-prefix check
/// must NEVER become the sole gate for an irreversible operation — those stay hard-refused.
func requireLiveMessageMutation(_ m: MailMessage, testMode: Bool) throws -> String {
    guard testMode && TestMode.isEnabled else {
        throw AppleError.mailSafety("live mutation requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
    }
    guard m.subject.hasPrefix(TestMode.sandboxPrefix) else {
        throw AppleError.mailSafety("target message '\(m.id)' (subject: \"\(m.subject)\") is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate real mail.")
    }
    guard let imid = m.internet_message_id, !imid.isEmpty else {
        throw AppleError.upstream("message '\(m.id)' has no RFC Message-ID; cannot mutate it via Mail.app.")
    }
    return imid
}

/// Every target must carry the CANONICAL test-label prefix, checked against
/// `TestMode.canonicalSandboxPrefix` rather than the caller-redefinable `TestMode.sandboxPrefix`.
/// Used ONLY by irreversible operations: widening `APPLE_TEST_SANDBOX` must not be able to widen
/// what an erase is allowed to destroy. Pure (no Mail, no I/O) so it is unit-testable.
func requireCanonicalLabels(_ msgs: [MailMessage]) throws {
    if let bad = msgs.first(where: { !$0.subject.hasPrefix(TestMode.canonicalSandboxPrefix) }) {
        throw AppleError.mailSafety("target '\(bad.id)' (subject: \"\(bad.subject)\") is not a canonically-labeled test item (must start with \"\(TestMode.canonicalSandboxPrefix)\") — refusing to permanently erase it.")
    }
}

/// Execute a per-message mutation over resolved targets, ALL-OR-NOTHING on the label gate.
/// Phase 1 validates EVERY target's gate (`requireLiveMessageMutation`) before ANY mutation runs,
/// so a mixed batch containing one unlabeled/real message mutates nothing AND the throw can't
/// leave already-applied ids unreported. Phase 2 then mutates; a target Mail can't locate is
/// collected into `not_found` (not a throw). `op` returns true when the change applied. Returns
/// (applied ids, not-found ids).
func executeMessageMutation(_ msgs: [MailMessage], testMode: Bool,
                            _ op: (_ internetMessageID: String, _ account: String?) throws -> Bool) throws
    -> (applied: [String], notFound: [String]) {
    // Phase 1 — gate every target up front; the first unlabeled/ungated one throws before any op.
    let validated: [(id: String, imid: String, account: String?)] = try msgs.map { m in
        (m.id, try requireLiveMessageMutation(m, testMode: testMode), m.account.isEmpty ? nil : m.account)
    }
    // Phase 2 — mutate the fully-validated set; op failures mean "not locatable", not a gate breach.
    var applied: [String] = [], notFound: [String] = []
    for t in validated {
        if try op(t.imid, t.account) { applied.append(t.id) } else { notFound.append(t.id) }
    }
    return (applied, notFound)
}

/// Collapse two mutually-exclusive boolean flags into an optional tri-state (nil = any).
func triState(_ positive: Bool, _ negative: Bool, _ posName: String, _ negName: String) throws -> Bool? {
    if positive && negative { throw AppleError.validation("--\(posName) and --\(negName) are mutually exclusive.") }
    if positive { return true }
    if negative { return false }
    return nil
}

/// Parse a required `YYYY-MM-DD` option to a Unix epoch, or throw a clear validation error.
func requireISODate(_ iso: String, name: String, endOfDay: Bool = false) throws -> Int {
    guard let unix = MailFormat.unix(fromISODate: iso, endOfDay: endOfDay) else {
        throw AppleError.validation("--\(name) must be an ISO date (YYYY-MM-DD); got '\(iso)'.")
    }
    return unix
}

// MARK: Attachment save selection (pure, testable — see Tests/MailKitTests/AttachmentSelectionTests.swift)
//
// `attachments save` selects POSITIONALLY (matches MCP A's own `items {i} of mail attachments of
// msg`), never by name — a message with two identically-named attachments must not let an
// `--indices 0` request silently also grab index 2 (or a --name request silently save both when
// only one was meant). Index resolution, the --dir/--out mode choice, and de-collision of
// same-basename outputs all happen HERE in Swift (pure, unit-testable) BEFORE any AppleScript
// runs; MailScript.saveAttachments only does positional `save` calls against caller-supplied
// (index, exact destination path) pairs — no name-matching, no path composition.

/// Validate --name/--indices are mutually exclusive. Chaining them (filter by name, then re-index
/// the ALREADY-filtered list) was the prior, confusing/buggy behavior. Pure/store-independent.
func requireNameXorIndices(name: String?, indices: String?) throws {
    guard name != nil, indices != nil else { return }
    throw AppleError.validation("--name and --indices are mutually exclusive.")
}

/// Validate --dir/--out: exactly one save mode must be chosen. Pure/store-independent.
func requireDirXorOut(dir: String?, out: String?) throws {
    switch (dir, out) {
    case (nil, nil):
        throw AppleError.validation("provide --dir (save multiple attachments into a directory) or --out (save one attachment to an exact path).")
    case (.some, .some):
        throw AppleError.validation("--dir and --out are mutually exclusive.")
    default:
        return
    }
}

/// When --out is given, the selection MUST resolve to exactly one attachment — an exact
/// destination path is a rename of ONE file (MCP B `save_email_attachment`), not a fan-out.
func requireSingleForOut(out: String?, selectedCount: Int) throws {
    guard out != nil else { return }
    guard selectedCount == 1 else {
        throw AppleError.validation("--out requires exactly one selected attachment (matched \(selectedCount)); narrow the selection with --name/--indices, or use --dir to save multiple.")
    }
}

/// Resolve the 0-based POSITIONAL indices (into `names`, the message's attachment list) selected
/// by --name (EVERY position whose name matches exactly — duplicates all included) or --indices
/// (a comma-separated list, clamped to the valid range) — or every position when neither is given
/// (default all). Always returned ascending, regardless of the order --indices was typed in.
/// Caller has already enforced --name/--indices mutual exclusion (`requireNameXorIndices`).
func resolveAttachmentIndices(names: [String], name: String?, indices: String?) -> [Int] {
    if let name {
        return names.enumerated().filter { $0.element == name }.map(\.offset)
    }
    if let indices {
        let want = Set(indices.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        return names.indices.filter { want.contains($0) }
    }
    return Array(names.indices)
}

/// Reduce an attachment's Mail-reported name to a safe basename for path composition — strips any
/// directory components (a crafted name like "../../etc/passwd" collapses to "passwd") and
/// substitutes a safe placeholder for the degenerate empty/"."/".." cases, so a hostile attachment
/// name can never compose a destination path outside the target directory (zip-slip class).
func safeAttachmentBasename(_ raw: String, fallbackIndex: Int) -> String {
    let base = (raw as NSString).lastPathComponent
    if base.isEmpty || base == "." || base == ".." {
        return "attachment-\(fallbackIndex)"
    }
    return base
}

/// De-collide a list of basenames so EVERY output name is globally unique — the 2nd+ time a
/// basename would appear gets "-N" spliced before its extension, incrementing N until the
/// candidate is free. Checks against the full set of names ALREADY EMITTED (not just a per-input
/// repeat count), so a literal name that coincidentally matches what de-collision would produce
/// (e.g. ["image.png", "image-1.png", "image.png"] — a genuinely distinct second attachment
/// already named "image-1.png") still can't collide: the second "image.png" skips straight to
/// "image-2.png". Same-named (or accidentally-colliding) sibling attachments from one message
/// never silently overwrite one another on disk.
func deCollidedBasenames(_ names: [String]) -> [String] {
    var used: Set<String> = []
    var out: [String] = []
    for n in names {
        guard used.contains(n) else {
            used.insert(n)
            out.append(n)
            continue
        }
        let ns = n as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        func candidate(_ suffix: Int) -> String { ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)" }
        var suffix = 1
        while used.contains(candidate(suffix)) { suffix += 1 }
        used.insert(candidate(suffix))
        out.append(candidate(suffix))
    }
    return out
}

/// Resolve a user-supplied message identifier — Envelope Index ROWID, RFC-5322 Message-ID,
/// or a `message://` deep link — to a message row. Returns nil if not found.
func resolveMessageRow(ctx: MailContext, id: String) throws -> [String: String?]? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if let rowid = Int(trimmed) { return try ctx.index.message(rowid: rowid) }
    if trimmed.lowercased().hasPrefix("message://") {
        // message://%3C<encoded id>%3E  → strip scheme + angle-bracket wrappers, decode.
        var inner = String(trimmed.dropFirst("message://".count))
        inner = inner.removingPercentEncoding ?? inner
        return try ctx.index.message(internetMessageID: inner)
    }
    return try ctx.index.message(internetMessageID: trimmed)
}

/// Emit a messages result as JSON, or a compact human list under `--text`.
func emitMessages(_ result: MailMessagesResult, json: Bool) throws {
    if json { try Output.emit(tool: "mail", data: result); return }
    for m in result.messages { printMessageText(m, full: false) }
    if let hasMore = result.has_more, hasMore, let next = result.next_offset {
        FileHandle.standardError.write(Data("… more (next --offset \(next))\n".utf8))
    }
}

func printMessageText(_ m: MailMessage, full: Bool) {
    let flag = m.flagged ? " ⚑\(m.flag_color_name.map { "(\($0))" } ?? "")" : ""
    let unread = m.is_read ? "" : " •"
    print("[\(m.id)]\(unread)\(flag) \(m.subject)")
    print("    from: \(m.sender)   \(m.date_received ?? "")   \(m.account)/\(m.mailbox)")
    if let to = m.to, !to.isEmpty { print("    to: \(to.joined(separator: ", "))") }
    if let cc = m.cc, !cc.isEmpty { print("    cc: \(cc.joined(separator: ", "))") }
    if full, let content = m.content, !content.isEmpty {
        print("    ----")
        print(content)
    } else if let snip = m.snippet, !snip.isEmpty {
        print("    \(snip.prefix(140))")
    }
}

extension MailMessage {
    /// Build a message from a live Mail.app selection when it isn't in the Envelope Index.
    static func fromSelection(_ sel: MailScript.ScriptSelection) -> MailMessage {
        MailMessage(
            id: sel.applescriptID,
            message_id: sel.applescriptID,
            rowid: 0,
            internet_message_id: sel.internetMessageID,
            mail_link: MailFormat.mailLink(internetMessageID: sel.internetMessageID),
            applescript_id: sel.applescriptID,
            subject: sel.subject,
            sender: sel.sender,
            sender_name: nil,
            sender_address: nil,
            mailbox: "",
            account: "",
            read_status: sel.readStatus,
            is_read: sel.readStatus,
            flagged: sel.flagged,
            flag_color: nil,
            flag_color_name: nil,
            date_received: nil,
            received_date: nil,
            date_sent: nil,
            has_attachments: false,
            attachment_count: 0,
            size: nil,
            conversation_id: nil,
            snippet: nil,
            content: sel.content,
            to: nil, cc: nil, bcc: nil)
    }
}
