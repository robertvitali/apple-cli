import Foundation
import AppleKit

// Shared helpers for the Mail command tree — kept small + pure where possible.

extension AppleError {
    /// Mail-side spelling of the shared safety refusal — a live mutation blocked by the
    /// test-mode / subject-label / recipient guard. Delegates to `AppleError.safetyViolation`
    /// (AppleKit) so all three domains emit the identical `error.type` / exit 77; kept as a named
    /// alias only because the ~30 Mail call sites read as `mailSafety`.
    /// Pass `sandbox: true` at a SANDBOX-policy gate (an unlabeled target, a non-self recipient, a
    /// sandbox-incompatible rule) so the refusal carries `error.sandbox` (Q14); leave it false for a
    /// refusal that fires regardless of sandbox state. Marked EXPLICITLY at each throw rather than
    /// inferred from the message text — an earlier prefix-sniffing version silently missed the rule
    /// gates (`requireLabeledName`/`requireSelfScoped`) and the reply/forward self-only refusal,
    /// whose messages don't start "sandbox active:".
    static func mailSafety(_ m: String, sandbox: Bool = false) -> AppleError {
        .safetyViolation(m, sandbox: sandbox)
    }
}

/// Gate a live mutation on an EXISTING message (write-model v2): mutations EXECUTE when
/// invoked — the oracle's move/mark/flag/delete mutate real mail on call, and the CLI
/// replaces it. The label restriction is the SANDBOX's (bucket 3): inside the opt-in
/// sandbox, only `apple-cli-test…`-labeled items may be touched, so an agent run can only
/// mutate test data it created. Returns the RFC Message-ID to operate on.
///
/// NOTE (defense-in-depth boundary, unchanged): the sandbox label key is the message
/// SUBJECT, which anyone can set by emailing the operator a message titled
/// `apple-cli-test …`. Acceptable ONLY because every op gated here is REVERSIBLE
/// (mark/flag/move/trash-to-Trash). This subject-prefix check must NEVER become the sole
/// gate for an irreversible operation — those keep their UNCONDITIONAL canonical-label +
/// APPLE_ALLOW_* gates regardless of sandbox state.
func requireLiveMessageMutation(_ m: MailMessage, sandboxActive: Bool) throws -> String {
    if sandboxActive {
        guard m.subject.hasPrefix(TestMode.sandboxPrefix) else {
            throw AppleError.mailSafety("sandbox active: target message '\(m.id)' (subject: \"\(m.subject)\") is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate it. Disengage the sandbox to operate on real mail.", sandbox: true)
        }
    }
    guard let imid = m.internet_message_id, !imid.isEmpty else {
        throw AppleError.upstream("message '\(m.id)' has no RFC Message-ID; cannot mutate it via Mail.app.")
    }
    return imid
}

/// PREVIEW-HONESTY twin of `requireLiveMessageMutation`'s sandbox half: a sandboxed dry-run
/// must refuse an unlabeled target exactly as `--execute` would (review-caught — the bulk
/// previews emitted a clean plan over real mail while sandboxed). Label check ONLY: the
/// imid-addressability check stays execute-side (it reflects Mail addressing reality, not a
/// policy gate — a preview that lists an unaddressable target is informative, not misleading).
func previewValidateSandboxTargets(_ msgs: [MailMessage], sandboxActive: Bool) throws {
    guard sandboxActive else { return }
    for m in msgs where !m.subject.hasPrefix(TestMode.sandboxPrefix) {
        throw AppleError.mailSafety("sandbox active: target message '\(m.id)' (subject: \"\(m.subject)\") is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate it. Disengage the sandbox to operate on real mail.", sandbox: true)
    }
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
/// so a mixed batch containing one unlabeled/real message mutates nothing. Phase 2 then mutates;
/// a target Mail can't locate is collected into `not_found` (op returns false — not a throw).
///
/// If an op HARD-fails mid-loop (an AppleScript execution error, thrown), Phase 2 re-throws the
/// underlying error ANNOTATED with the ids already applied (`AppleError.addingBulkContext`), so a
/// bulk failure no longer discards the partial-mutation record — a retry can exclude those ids
/// (extra33 / SEC-M2: move/delete are not idempotent). The failure still aborts (unchanged exit
/// code); only the previously-lost `applied` list is now surfaced on `error.applied`.
///
/// `op` returns true when the change applied. Returns (applied ids, not-found ids).
func executeMessageMutation(_ msgs: [MailMessage], sandboxActive: Bool,
                            _ op: (_ internetMessageID: String, _ account: String?) throws -> Bool) throws
    -> (applied: [String], notFound: [String]) {
    // Phase 1 — gate every target up front; the first sandbox-refused one throws before any op.
    let validated: [(id: String, imid: String, account: String?)] = try msgs.map { m in
        (m.id, try requireLiveMessageMutation(m, sandboxActive: sandboxActive), m.account.isEmpty ? nil : m.account)
    }
    // Phase 2 — mutate the fully-validated set; op returning false means "not locatable", a THROW
    // means a hard failure that aborts — carrying the ids already applied so they aren't lost.
    //
    // Two deliberate scoping choices (review):
    //  * only `applied` is carried on the abort, NOT the partial `not_found` accumulated so far —
    //    a not-found id was never mutated, so there is nothing to exclude from a retry; the
    //    retry-safety contract is strictly about ids that CHANGED.
    //  * `applied` records confirmed successes in PRIOR iterations, never `failedID`. An op may
    //    change its item and then throw (a later script step or outcome delivery can fail).
    //    The error therefore tells callers to verify the failed item's state before retrying;
    //    its absence from `applied` does not establish that it was unchanged.
    var applied: [String] = [], notFound: [String] = []
    for t in validated {
        do {
            if try op(t.imid, t.account) { applied.append(t.id) } else { notFound.append(t.id) }
        } catch {
            let base = (error as? AppleError) ?? AppleError.upstream("\(error)")
            throw base.addingBulkContext(applied: applied, failedID: t.id)
        }
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

/// True when a string carries a C0 control character or DEL — the bytes that desynchronize the
/// RS(0x1E)/US(0x1F)-delimited blobs every AppleScript call is argv-fed with. Any operator- or
/// REMOTE-supplied value that lands in such a blob must be rejected or scrubbed first, or one
/// vetted field silently becomes two (see `confineWriteDestination`, `resolveAttachmentPath`,
/// `outboundAllowlist`, `safeAttachmentBasename`).
func hasControlCharacters(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// Reduce an attachment's Mail-reported name to a safe basename for path composition — strips any
/// directory components (a crafted name like "../../etc/passwd" collapses to "passwd") and
/// substitutes a safe placeholder for the degenerate empty/"."/".." cases, so a hostile attachment
/// name can never compose a destination path outside the target directory (zip-slip class).
///
/// Control characters are SCRUBBED (not refused): unlike the operator-supplied path channels,
/// this name is REMOTE data — the sender's MIME filename — so a hostile sibling attachment must
/// not be able to kill a legitimate save. Scrubbing first is load-bearing: the basename is
/// composed into a destination path that is later US/RS-joined into the `saveAttachments` blob,
/// where an embedded US would TRUNCATE the destination (defeating the symlink + pre-existing-file
/// checks, which ran against the full path) and an embedded RS would inject a whole extra save
/// record with an attacker-chosen relative destination (review-caught).
func safeAttachmentBasename(_ raw: String, fallbackIndex: Int) -> String {
    let scrubbed = String(String.UnicodeScalarView(
        raw.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? Unicode.Scalar(0x5F)! : $0 }))
    let base = (scrubbed as NSString).lastPathComponent
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
/// Fail-loud mailbox scoping: an unknown mailbox name used to resolve to an empty predicate and
/// return an empty SUCCESS (indistinguishable from a genuinely empty mailbox), while the
/// unknown-account path throws not_found. Matches on full path or leaf, case-insensitively —
/// the same match `mailboxRowids` resolution uses — and lets the "All" wildcard through.
func requireMailboxKnown(ctx: MailContext, name: String, accountUUID: String?) throws {
    if EnvelopeIndex.isAllWildcard(name) { return }
    let known = ctx.index.mailboxes.contains { m in
        (accountUUID == nil || m.url.accountID == accountUUID)
            && (m.url.path.caseInsensitiveCompare(name) == .orderedSame
                || m.url.leaf.caseInsensitiveCompare(name) == .orderedSame)
    }
    guard known else {
        throw AppleError.notFound(
            "unknown mailbox '\(name)'\(accountUUID != nil ? " in the selected account" : ""). Use `apple mail mailboxes list` to see known mailboxes.")
    }
}

func resolveMessageRow(ctx: MailContext, id: String) throws -> [String: String?]? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    // An EMPTY id fell through to `message(internetMessageID: "")`, which matches a row whose
    // internet-message-id column is empty — review measured `delete --permanent ""` resolving
    // an ARBITRARY real message with ok:true. A script's unset $ID variable must fail loud,
    // not permanently destroy an unrelated message.
    guard !trimmed.isEmpty else {
        throw AppleError.validation("message id must not be empty.")
    }
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
        Output.writeError(Data("… more (next --offset \(next))\n".utf8))
    }
    // A human reading --text gets the same silent-filtering problem `system_folders_excluded`
    // was added to remove for JSON callers: a short list is indistinguishable from a sparse
    // store. --text is outside the versioned contract, so this goes to stderr next to the
    // pagination hint rather than into the payload.
    if result.system_folders_excluded == true {
        Output.writeError(Data(
            "(system mailboxes excluded — pass --include-system-folders to include Trash/Junk/Sent/Drafts/Spam)\n".utf8))
    }
}

func printMessageText(_ m: MailMessage, full: Bool) {
    let flag = m.flagged ? " ⚑\(m.flag_color_name.map { "(\($0))" } ?? "")" : ""
    let unread = m.is_read ? "" : " •"
    Output.printText("[\(m.id)]\(unread)\(flag) \(m.subject)")
    Output.printText("    from: \(m.sender)   \(m.date_received ?? "")   \(m.account)/\(m.mailbox)")
    if let to = m.to, !to.isEmpty { Output.printText("    to: \(to.joined(separator: ", "))") }
    if let cc = m.cc, !cc.isEmpty { Output.printText("    cc: \(cc.joined(separator: ", "))") }
    if full, let content = m.content, !content.isEmpty {
        Output.printText("    ----")
        Output.printText(content)
    } else if let snip = m.snippet, !snip.isEmpty {
        Output.printText("    \(snip.prefix(140))")
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
            // Oracle A always returns date_received for a selected message; the selection
            // AppleScript now reads it, so the non-index path no longer emits a null date.
            // Both wire names (A `date_received` / B `received_date`) carry it.
            date_received: sel.dateReceived,
            received_date: sel.dateReceived,
            date_sent: nil,
            has_attachments: false,
            attachment_count: 0,
            size: nil,
            conversation_id: nil,
            snippet: nil,
            content_preview: nil,
            content: sel.content,
            to: nil, cc: nil, bcc: nil)
    }
}
