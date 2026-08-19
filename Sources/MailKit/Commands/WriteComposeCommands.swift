import Foundation
import ArgumentParser
import AppleKit

// P2 compose surface: send, reply, forward, draft, draft-rich. Write-model v2
// (docs/write-model-v2.md): outbound verbs EXECUTE when invoked — the CLI replaces the MCP
// oracles, which send on call. `--dry-run` previews; `APPLE_DRY_RUN=1` restores
// dry-run-by-default. The opt-in SANDBOX (APPLE_TEST_MODE truthy OR --test-mode) restricts
// recipients to the self-only allowlist and drafts to labeled test items. Live delivery is
// wired for ALL body types — plain text (Mail `content`), file attachments (AppleScript
// `make new attachment`), and HTML (multipart `.eml` opened as an X-Unsent outgoing message
// and sent, since Mail's AppleScript `content` is plain-text only). EVERY sending path still
// routes through the same `guardOutbound` before any send — unsandboxed it validates
// recipients exist; sandboxed it enforces the self-only allowlist (see AGENTS.md Safety:
// agent runs stay sandboxed by conduct rule).

/// Split repeatable + comma-joined recipient options into a flat address list.
///
/// REFUSES a control character in any resulting address (validation, exit 64): recipient lists
/// are US(0x1F)-joined into the AppleScript argv for send/draft/save, so an embedded US would
/// split ONE vetted address into two — the second never seen by `guardOutbound`'s allowlist
/// comparison. A control character is never part of a legitimate address, so refusing costs
/// nothing and closes the channel at its single chokepoint (review-caught; the same class as
/// the attachment-path and allowlist guards).
func splitRecipients(_ raw: [String]) throws -> [String] {
    let out = raw.flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if let bad = out.first(where: hasControlCharacters) {
        throw AppleError.validation("recipient '\(bad.replacingOccurrences(of: "\u{1F}", with: "<US>"))' contains a control character — refusing.")
    }
    return out
}

/// Reduce an INDEX-supplied recipient rendering to a bare addr-spec for outbound use.
///
/// `EnvelopeIndex.recipients()` returns `MailFormat.person(...)` display form —
/// `"Display Name <addr@host>"` — where the display name is RFC-2047-DECODED REMOTE data:
/// arbitrary scalars chosen by whoever mailed the operator. `reply --all` folds those strings
/// into the outbound recipient list, which is US-joined into the gui-send argv and re-split
/// in-script into one `to recipient` per field — so a display name carrying a US byte would
/// inject an ADDITIONAL auto-sent recipient that `guardOutbound` never saw (review-caught;
/// unsandboxed-only, since the sandbox's exact-match allowlist fails such an entry closed).
///
/// Two defenses, both needed: take only the addr-spec (the display name — the attacker-chosen
/// part — is discarded outright, and a bare address is what Mail's `address:` property wants
/// anyway), then REFUSE a control character in what remains.
func outboundAddressFromIndex(_ raw: String) throws -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
        s = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }
    guard !hasControlCharacters(s) else {
        throw AppleError.validation("a recipient address read from the message index contains a control character — refusing to compose to it.")
    }
    return s
}

/// Common outbound guard (write-model v2, docs/write-model-v2.md): a live send EXECUTES when
/// invoked — the CLI is a replacement for the MCP servers, and the oracle's send_email sends
/// on call. The self-only recipient allowlist is the SANDBOX's restriction (bucket 3): inside
/// the opt-in sandbox every recipient must be the operator's own allowlisted address; outside
/// it, recipients are unrestricted. Sandbox refusals stay `safety_violation` (exit 77) so
/// they read as deliberate, not as bugs. NOTE FOR AGENTS (AGENTS.md conduct rules, which the
/// product no longer enforces): your sends run sandboxed, self-addressed only — the narrow
/// unsandboxed exception is the once-per-flip self-addressed verification send.
/// The oracle's anti-spam recipient cap: `to + cc + bcc` may not exceed 100
/// (oracle A `security.py:89-91`, `max_recipients = 100` → "Too many recipients (max: 100)").
/// BUCKET 1 — an oracle-mirrored gate, so it applies UNCONDITIONALLY, sandbox or not. Write-model
/// v2 lifts CLI-only restrictions; it does not lift limits the oracle itself enforces, and this is
/// one the oracle applies on every send path.
let outboundRecipientCap = 100

/// `applyRecipientCap` is INTENTIONALLY NOT DEFAULTED. Oracle A applies the 100-recipient cap at
/// exactly two call sites — `validate_send_operation(to, cc, bcc)` from `send_email`
/// (server.py:898) and `send_email_with_attachments` (server.py:1085). `forward_message` checks
/// only `if not to:`, `reply_to_message` validates nothing, and oracle B has no cap anywhere. So
/// only `mail send` may cap: applying it to reply/forward/draft-rich would REFUSE INPUT BOTH
/// ORACLES ACCEPT, i.e. drop capability — the same defect the bulk cap deliberately avoids for
/// `move`/`flag`. A defaulted `= true` would silently re-introduce it at the next call site added,
/// which is precisely how the sibling defect happened; requiring the argument makes the compiler
/// ask the question every time. (Review-caught: the first cut capped all four call sites.)
func guardOutbound(recipients: [String], sandboxActive: Bool, applyRecipientCap: Bool) throws {
    guard !recipients.isEmpty else { throw AppleError.validation("no recipients to send to.") }
    // UNCONDITIONAL for the surfaces that DO cap — deliberately above the `sandboxActive`
    // early-return, because the oracle caps regardless of any mode.
    if applyRecipientCap {
        guard recipients.count <= outboundRecipientCap else {
            throw AppleError.validation(
                "Too many recipients (max: \(outboundRecipientCap)) — \(recipients.count) given.")
        }
    }
    guard sandboxActive else { return }
    // Fail-closed inside the sandbox: EVERY recipient must be an allowlisted self-address.
    // Compare case-insensitively (email addresses are case-insensitive) so a legit self-reply
    // whose stored sender_address differs in case from APPLE_TEST_RECIPIENTS isn't refused.
    // A literal "*" entry is dropped (it is the script layer's out-of-sandbox sentinel, never a
    // valid address — see outboundAllowlist) so operator data can't smuggle a match-anything.
    let allow = Set(TestMode.allowedRecipients.filter { $0 != "*" }.map { $0.lowercased() })
    for r in recipients where !allow.contains(r.lowercased()) {
        throw AppleError.mailSafety("sandbox active: recipient '\(r)' is not in the self-only allowlist (APPLE_TEST_RECIPIENTS) — refusing. Disengage the sandbox to send beyond it.", sandbox: true)
    }
}

/// The recipient allowlist handed to the AppleScript dispatch layer (nativeReply/nativeForward/
/// sendDraft). `"*"` is the OUT-OF-SANDBOX wildcard sentinel (`firstDisallowed` skips the
/// allowlist comparison when it sees one), so it must NEVER be derivable from operator data:
/// `TestMode.allowedRecipients` is a raw comma-split of APPLE_TEST_RECIPIENTS, and an operator
/// habitually spelling "allow all" as `APPLE_TEST_RECIPIENTS="*"` would otherwise disable the
/// ACTIVE sandbox's recipient check (review-caught). Sandboxed lists therefore DROP any literal
/// `"*"` — AND any entry containing a control character: the list is US(0x1F)-joined into the
/// script argv and re-split in-script, so an entry that merely CONTAINS a US byte would
/// materialize extra entries after the split (`"a@x\u{1F}*"` → `a@x` + the sentinel —
/// review-caught). Fail-closed both ways: dropped entries only SHRINK the allowlist; an
/// allowlist of only bad entries becomes empty, which refuses every recipient.
/// `allowed` is injectable for the logic tier; production callers use the default.
func outboundAllowlist(sandboxActive: Bool, allowed: [String] = TestMode.allowedRecipients) -> [String] {
    guard sandboxActive else { return ["*"] }
    return allowed.filter { entry in
        entry != "*" && !entry.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

/// Build the refusal message for a native reply/forward the self-only guard rejected.
///
/// The `discarded` half is deliberately loud. Nothing was sent either way — the guard held — but
/// if the composed draft could NOT be closed, a message addressed to a non-self recipient is
/// sitting in Mail's outgoing store one click from being sent, which is a named dangerous action.
/// Asserting "the draft was discarded" without knowing it is how an orphan compose survives, so
/// the failure case tells the operator to remove it by hand instead.
func refusalMessage(kind: String, bad: String, discarded: Bool, sandboxActive: Bool) -> String {
    // Unsandboxed, the in-script allowlist comparison is skipped (wildcard), so the ONLY
    // reachable `bad` is the `<empty-address>` sentinel — a malformed compose, not an
    // allowlist miss; saying "non-self recipient(s)" there would be flatly wrong.
    let head: String
    if bad.hasPrefix("(unrecognized script result") {
        // The parser's fail-closed default: output we cannot interpret is never a success,
        // but it is not an allowlist miss either — say what actually happened. (createfail/
        // setupfail are a TYPED outcome now — composeFailureMessage below — so the only
        // parenthesized pseudo-reason left here is this sentinel; the in-script guard's own
        // "(no recipients populated)" / "(recipients vanished before send)" rows are genuine
        // audit trips and KEEP the refusal wording — review caught the broad `(`-prefix
        // branch swallowing them as compose failures.)
        head = "refusing the \(kind): Mail returned an unrecognized script result \(bad). Nothing was sent."
    } else if bad == "(no recipients populated)" || bad == "(recipients vanished before send)" {
        // Zero-recipient audit trips from the reply/forward tail: they fire BEFORE the allowlist is
        // consulted and are unconditional of the sandbox wildcard, so they are refusals-to-send but
        // NOT allowlist misses. The message must not claim the sandbox refused a recipient — that
        // would disagree with `error.sandbox` being absent (they are not sandbox-caused, per
        // `mailOutboundRefusalIsSandboxCaused`). Kept as a refusal (not a compose failure), per the
        // prior review that these trips retain refusal wording.
        head = "refusing the \(kind): Mail reported no deliverable recipients \(bad). Nothing was sent."
    } else if bad == "<empty-address>" {
        head = "refusing the \(kind): Mail composed it with an empty/blank recipient address. Nothing was sent."
    } else if sandboxActive {
        head = "refusing the \(kind): Mail addressed it to recipient(s) outside the sandbox's self-only allowlist (\(bad)). Nothing was sent."
    } else {
        head = "refusing the \(kind): Mail addressed it to recipient(s) that failed verification (\(bad)). Nothing was sent."
    }
    return discarded
        ? "\(head) The composed draft was discarded."
        : "\(head) WARNING: the composed draft could NOT be discarded and may still be in Mail's outgoing messages — open Mail and delete it manually."
}

/// Companion to `refusalMessage` for the typed `.composeFailed` outcome (createfail/setupfail):
/// composing in Mail failed BEFORE any delivery — an upstream failure, never an allowlist
/// refusal, and the wording must not claim one (review: an Accessibility-denied HTML paste
/// rendered as "recipients outside the allowlist"). The discard warning carries the same
/// operator action as the refusal path.
func composeFailureMessage(kind: String, reason: String, discarded: Bool) -> String {
    let head = "composing the \(kind) in Mail failed: \(reason). Nothing was sent."
    return discarded
        ? "\(head) The composed draft was discarded."
        : "\(head) WARNING: the composed draft could NOT be discarded and may still be in Mail's outgoing messages — open Mail and delete it manually."
}

/// Resolve + validate a single attachment path: expand `~`, require it to exist and be a REGULAR
/// file (a directory / missing path is rejected). Returns the resolved absolute path for both the
/// AppleScript attachment route and the `.eml` builder. CONTAINMENT NOTE (write-model v2): outside
/// the sandbox recipients are unrestricted, so the sensitive-directory blocklist below and the
/// executable-extension blocklist ARE the containment for attachment content — they are absolute
/// and fire in both modes. Inside the sandbox, `guardOutbound`'s self-only allowlist additionally
/// bounds where an attachment can go. Missing/non-regular files are `not_found` (exit 65),
/// matching the prior inline behavior.
/// Executable / script extensions blocked from attachment sends by default (mirrors s-morgan
/// `validate_attachment_type`'s `dangerous_extensions`). Blocking is the parity default; there is
/// no allow-executables override yet.
let dangerousAttachmentExtensions: Set<String> = [
    "exe", "bat", "cmd", "com", "scr", "pif", "vbs", "vbe", "js", "jse", "wsf", "wsh",
    "msi", "msp", "scf", "lnk", "inf", "reg", "ps1", "psm1", "app", "deb", "rpm", "sh",
    "bash", "csh", "ksh", "zsh", "command",
]

/// Whether a Mail outbound refusal `reason` (the `bad`/`addr` value an in-script recipient check
/// returns) was caused BY the sandbox's self-only allowlist rather than an always-on condition.
/// Only an allowlist miss — a real recipient outside the self-only set — is a sandbox-policy
/// refusal, so only it stamps `error.sandbox`. Every other reason is an always-on trip that fires
/// identically whether the sandbox is on or off, so marking it `sandbox: true` would tell a
/// consumer "retry unsandboxed" when that retry hits the very same block (the false-positive class
/// Q14 exists to kill). Those always-on reasons are exactly the non-address sentinels the in-script
/// checks emit: `<empty-address>` (a blank recipient), and the parenthesized audit trips `(no
/// recipients populated)` / `(recipients vanished before send)` / `(unrecognized script result …)`.
/// A real disallowed address (from `firstDisallowed`) never begins with `(` or `<`, so excluding
/// those two prefixes covers every current sentinel AND any future parenthesized one. Single-sourced
/// across the draft-send `.blocked` and reply/forward `.refused` paths, mirroring `refusalMessage`'s
/// own reason partition so message and flag agree.
func mailOutboundRefusalIsSandboxCaused(reason: String, sandboxActive: Bool) -> Bool {
    guard sandboxActive else { return false }
    if reason == "<empty-address>" { return false }
    if reason.hasPrefix("(") { return false }
    return true
}

/// Builds the refusal error for a `sendDraft` `.blocked` result. Factored out of the
/// `manage_drafts action=send` switch so the sandbox-causation is unit-pinnable without driving
/// live Mail. Message clauses AND the `sandbox` flag derive from the SAME reason predicate
/// (`mailOutboundRefusalIsSandboxCaused`) so they never disagree: an allowlist miss (real non-self
/// recipient) reads as a self-only refusal and stamps `sandbox: true`; an always-on
/// `<empty-address>` broken compose points at fixing the draft and leaves the flag absent, even
/// under an active sandbox.
func blockedDraftSendError(address: String, subject: String, sandboxActive: Bool) -> AppleError {
    let sandboxCaused = mailOutboundRefusalIsSandboxCaused(reason: address, sandboxActive: sandboxActive)
    let which = address == "<empty-address>" ? "an empty/blank recipient address" : "'\(address)'"
    // Allowlist advice/wording only when the allowlist is actually what refused; an empty/blank
    // address is a broken compose (always-on), so it must NOT claim an allowlist miss.
    let advice = sandboxCaused
        ? "Set APPLE_TEST_RECIPIENTS to your own address(es) or fix the draft's recipients."
        : "Fix the draft's recipients in Mail."
    let why = sandboxCaused ? ", which is not in the self-only test allowlist" : ""
    return AppleError.mailSafety(
        "draft \"\(subject)\" is addressed to \(which)\(why) — refusing to send it. \(advice)",
        sandbox: sandboxCaused)
}

func resolveAttachmentPath(_ raw: String) throws -> String {
    // CONTROL CHARACTERS FIRST, unconditionally — the exact rule (and rationale) of
    // confineWriteDestination: resolved attachment paths are US-joined into the AppleScript
    // argv blob and re-split in-script, so a path CONTAINING a US byte would smuggle a second,
    // never-vetted path past the sensitive-dir blocklist below (review-caught; under v2 that
    // blocklist is the sole containment for unsandboxed attachment content).
    if let bad = raw.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) {
        throw AppleError.mailSafety(
            "cannot attach a path containing a control character (U+\(String(format: "%04X", bad.value))) — refusing.")
    }
    let expanded = (raw as NSString).expandingTildeInPath
    // Resolve symlinks BEFORE the sensitive-dir check so a symlink into ~/.ssh (etc.) cannot
    // bypass it (matches patrickfreyer's realpath). The real path is also what Mail attaches.
    let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        throw AppleError.notFound("attachment not found or not a regular file: \(raw)")
    }
    // Reject oversized attachments before handing the file to Mail (a clean pre-send refusal vs an
    // opaque Mail hang/failure) — matches s-morgan send_email_with_attachments' 25 MB default cap.
    let maxBytes = 25 * 1024 * 1024
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
       size.intValue > maxBytes {
        throw AppleError.validation("attachment exceeds the 25 MB send limit (\(size.intValue) bytes): \(raw)")
    }
    // Refuse dangerous executable/script types by default (s-morgan validate_attachment_type,
    // which matches on filename `endswith` — so a file literally named ".sh" is blocked too, which
    // NSString.pathExtension would miss).
    let base = (path as NSString).lastPathComponent.lowercased()
    if let blockedExt = dangerousAttachmentExtensions.first(where: { base.hasSuffix(".\($0)") }) {
        throw AppleError.validation("attachment type '.\(blockedExt)' is blocked (executable/script); refusing: \(raw)")
    }
    // Refuse reading from sensitive credential/config directories (patrickfreyer sensitive_dirs) —
    // a safety refusal (don't exfiltrate keys/tokens as an attachment). Check BOTH the resolved
    // path (defeats a symlink INTO a sensitive dir) AND the tilde-expanded literal (defeats a
    // sensitive dir that is ITSELF a symlink, e.g. a stow-managed `~/.ssh` -> `~/dotfiles/ssh`).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if let dir = sensitiveWriteDir(path, home: home) ?? sensitiveWriteDir(expanded, home: home) {
        throw AppleError.mailSafety("cannot attach a file from a sensitive directory (\(dir)) — refusing.")
    }
    return path
}

/// Read already-resolved attachment paths into `EmlBuilder.Attachment` parts (for the HTML/`.eml`
/// route). A path that can't be read (e.g. a TOCTOU race after `resolveAttachmentPath`) is
/// `not_found` rather than a silent drop.
func attachmentsFromPaths(_ paths: [String]) throws -> [EmlBuilder.Attachment] {
    try paths.map { path in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw AppleError.notFound("attachment could not be read: \(path)")
        }
        let name = (path as NSString).lastPathComponent
        return EmlBuilder.Attachment(filename: name, mimeType: EmlBuilder.mimeType(forFilename: name), data: data)
    }
}

/// The `.eml` output path: an explicit `--out`, else a labeled temp file.
/// An operator-supplied `--out` is CONFINED; the generated temp default is not (we chose it).
///
/// Confinement here is still load-bearing even though (write-model v2) `.eml` writes are gated
/// on `willExecute`: `--execute` is the DEFAULT posture for the send surface, so an unconfined
/// `--out` would still write bytes to an arbitrary operator-supplied location on an ordinary
/// invocation. The guard's own docstring claims every operator write path goes through it.
/// Where a generated `.eml` goes, and how long it lives.
///
/// TWO DIFFERENT ANSWERS, which is the whole of COMPLETION-LOOP Q4f:
///   * `--out` given — operator-facing OUTPUT. They chose the path, they own the file, we neither
///     relocate it nor change its mode nor ever delete it.
///   * no `--out` — an internal temp. It cannot be deleted when the command ends: `openEml` hands
///     the path to Mail with `open -a Mail`, which returns immediately and leaves Mail to read the
///     file after this process is gone. (Contrast the `--gui-send` HTML temp a few lines below,
///     which IS `defer`-deleted, because `sendHtmlViaGui` is synchronous.) So these accumulated:
///     measured 244 files, 976 KB, every one mode 0644, the oldest 11 days old — and unlike the
///     SQLite snapshots these are COMPLETE RFC-822 messages, headers and bodies.
///
/// The temp now goes in an owned 0700 directory at 0600 and is reaped on a later run. The reaper is
/// age-based, which is the weaker predicate deliberately rejected for snapshots — but there the
/// owner is one of our own processes and an `flock` answers exactly; here the owner is Mail.app,
/// which cannot be locked or interrogated. The hand-off completes in seconds, so a 24-hour window
/// is orders of magnitude more slack than it needs.
/// The temp `.eml` directory. `materialise: false` only computes the path.
///
/// A `--dry-run` reaches this to REPORT the planned destination, and a preview must not create a
/// directory, must not delete anything, and must not acquire a new way to fail — before this split
/// a dry-run did all three, and could exit 69 where it previously could not fail at all.
func emlTempDirectory(materialise: Bool, base: URL? = nil) throws -> URL {
    guard materialise else { return OwnedTempDir.path("apple-cli-eml", base: base) }
    let dir = try OwnedTempDir.make("apple-cli-eml", base: base)
    // A containment ROOT, never a removable directory: this one is shared with other invocations
    // and long-lived, and `rmdir`ing it would be a bug. Registering it also arms the process, so
    // the `--gui-send` temp below is actually removed on a signal death rather than waiting for
    // the 24-hour sweep. Which files may be registered — and which must NOT — is Q4k.
    SignalSafeCleanup.registerRoot(dir)
    // Reaped on every materialising call rather than once per process. A `once` flag would be a
    // mutable global read from concurrent callers — a real data race for no gain, since this is one
    // listing of a directory only this tool writes to.
    OwnedTempDir.reapFiles(in: dir, prefix: "apple-cli-", olderThan: 24 * 60 * 60)
    return dir
}

/// May a generated `.eml` be queued for signal-time deletion?
///
/// The question is never "is it a `.eml`" — Q4k's first answer got that wrong in both directions.
/// It is "will anything read this file after we exit".
///
/// * `--out` given — the operator chose the path and owns the file. Never ours to delete, on any
///   signal, ever.
/// * handed to Mail — `openEml` runs `open -a Mail`, which returns immediately and leaves Mail to
///   read the file AFTER this process is gone. Deleting it on Ctrl-C destroys a live hand-off.
/// * neither — nothing reads it. `send --html --gui-send` writes a full RFC-822 message here and
///   then takes the `sendHtmlViaGui` branch, which never opens it. That file was invisible to
///   Q4k's first pass, which excluded every `.eml` by extension; review caught it.
///
/// DELIBERATELY CONSERVATIVE: callers pass `handedToMail: true` for everything except the branch
/// proven not to read it. A false negative costs a file 24 hours until the age sweep; a false
/// positive deletes the message out from under the compose window the operator is looking at.
/// Those are not symmetric, so the doubt goes to leaving the file alone.
/// Will something outside this process read the generated `.eml` after we exit?
///
/// Split out so the argument to `generatedEmlIsDisposable` is itself pinned by a table, not just
/// the predicate it feeds. Review caught that flipping the old inline `!willGuiSend` to either
/// constant left all 645 tests green — the same "pinned away from where the mistake is made"
/// defect this pair of functions exists to retire, recurring one level up.
///
/// The negation is deliberate and must stay: an unrecognized future branch defaults to
/// hand-off-and-keep, never to delete.
func generatedEmlIsHandedToMail(willGuiSend: Bool, willAutoSend: Bool,
                                hasAttachments: Bool, willDraft: Bool, hasHTML: Bool) -> Bool {
    if willGuiSend { return false }                 // sendHtmlViaGui reads htmlTmp, never the .eml
    if willAutoSend && hasAttachments { return false }  // sendWithAttachments takes attachment paths
    if willDraft && !hasHTML { return false }       // saveDraft likewise; the HTML draft is a hand-off
    return true
}

func generatedEmlIsDisposable(out: String?, handedToMail: Bool) -> Bool {
    if out != nil { return false }
    return !handedToMail
}

func emlDestURL(out: String?, materialise: Bool, base: URL? = nil,
                action: String = "write the generated .eml to") throws -> URL {
    guard let out else {
        return try emlTempDirectory(materialise: materialise, base: base)
            .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).eml")
    }
    // NOT $HOME-confined, deliberately: oracle B's `create_rich_email_draft` only
    // `expanduser()`s `output_path` (tools/compose.py:204) — the home/sensitive checks at
    // compose.py:410+ belong to the ATTACHMENT helper, not this one — so `/tmp/x.eml` is a
    // legitimate destination and refusing it would DROP a capability. The credential blocklist
    // and the control-character rejection still apply, which is what actually protects keys.
    return try confineWriteDestination(out, action: action, allowOutsideHome: true)
}

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Compose an email (EXECUTES by default; --dry-run previews; plain/HTML/attachments; mode send|draft|open).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Recipient (repeatable; comma-joined ok).") var to: [String] = []
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Plain-text body (fallback when --html is set).") var body: String = ""
    @Option(name: .long, help: "CC recipient (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "BCC recipient (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "HTML body. Default opens a rendered compose window for review (reliable); add --gui-send to auto-send.") var html: String?
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Flag(name: .long, help: "Auto-send an --html message via GUI keystroke automation (needs Accessibility, steals focus, fragile). Opt-in.") var guiSend = false
    @Option(name: .long, help: "Sending account (name or UUID).") var account: String?
    @Option(name: .long, help: "Write the generated .eml to this path (html/attachment sends).") var out: String?

    struct Preview: Encodable {
        let action: String; let mode: String; let account: String?; let sender_address: String?
        let to: [String]; let cc: [String]; let bcc: [String]
        let subject: String; let has_html: Bool; let attachments: [String]
        let eml_path: String?; let dry_run: Bool; let executed: Bool; let opened: Bool; let drafted: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble: fail-loud env validation, then bind the two decisions
            // ONCE — every branch below reads these locals, never the env or flags again.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let toL = try splitRecipients(to), ccL = try splitRecipients(cc), bccL = try splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            guard ["send", "draft", "open"].contains(mode) else { throw AppleError.validation("--mode must be send, draft, or open.") }
            // --gui-send is the explicit opt-in for GUI-keystroke HTML auto-send; it applies
            // ONLY to an --html send.
            if guiSend {
                guard html != nil else { throw AppleError.validation("--gui-send only applies to an --html send.") }
                guard mode == "send" else { throw AppleError.validation("--gui-send requires --mode send.") }
            }

            // Live actions across the three delivery modes:
            //  send  — plain/attachment AUTO-SEND (reliable AppleScript), HTML GUI auto-send
            //          (--gui-send; fragile), or HTML reliable OPEN (--html without --gui-send).
            //  open  — render a compose window for review (ANY body type), no send.
            //  draft — save to Drafts (ANY body type), no send.
            let willAutoSend = willExecute && mode == "send" && html == nil
            let willGuiSend = willExecute && guiSend
            let willOpenHtml = willExecute && mode == "send" && html != nil && !guiSend
            let willOpen = willExecute && mode == "open"
            let willDraft = willExecute && mode == "draft"
            let willLiveOutbound = willAutoSend || willGuiSend || willOpenHtml || willOpen || willDraft

            // PREVIEW HONESTY: every gate below is keyed on the MODE, not on willExecute — a
            // dry-run must refuse exactly what --execute would (review-caught: the will*-keyed
            // versions previewed clean for a sandboxed non-self send / unlabeled draft / empty
            // open-subject). None of these touch Mail, so they are safe on the preview path.
            //
            // Outbound gate FIRST — before any attachment read, .eml/.html build, or
            // AppleScript/GUI action. Modes that render a compose window or send take it
            // (self-only inside the sandbox); a (non-sending) --mode draft takes the sandbox
            // label gate below instead.
            if mode == "send" || mode == "open" {
                try guardOutbound(recipients: toL + ccL + bccL, sandboxActive: sandboxActive,
                                  applyRecipientCap: true)
            }
            // An open / HTML action needs a real subject — a compose window / sent message with
            // an empty subject is a mistake; refuse before building anything.
            if guiSend || (mode == "send" && html != nil) || mode == "open" {
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required for a --mode open / --html action; refusing an empty/whitespace subject.")
                }
            }
            // --mode draft saves a PERSISTENT Drafts item; inside the sandbox it takes the
            // same label restriction as `draft create` (NOT the recipient guard — a draft is
            // not a send). Unsandboxed drafts are unrestricted (the oracle saves on call).
            if mode == "draft" && sandboxActive {
                guard subject.hasPrefix(TestMode.sandboxPrefix) else {
                    throw AppleError.mailSafety("sandbox active: draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") — refusing.", sandbox: true)
                }
            }

            // Resolve --account to a send (From) identity for EVERY live path: the send paths set
            // the outgoing message `sender`; the open path uses it as the `.eml` `From:` so Mail
            // selects the account. Resolved to the account's bare address (a name/UUID `From:`
            // would be malformed and ignored). An unknown/addressless account is a not_found before
            // any Mail action. Only resolved on a LIVE outbound path so a headless dry-run does not
            // require Mail; the dry-run preview `.eml` falls back to the raw --account string below.
            var senderAddress: String?
            if let account, willLiveOutbound {
                guard let addr = AccountDirectory().sendAddress(for: account) else {
                    throw AppleError.notFound("account '\(account)' not found or has no send address.")
                }
                senderAddress = addr
            }

            // Resolve attachment paths once (existence + regular-file), then generate the .eml
            // whenever HTML or attachments are present, OR --mode open (which opens a rendered
            // compose window for ANY body type): it is the preview artifact, the `--out` target,
            // AND the delivery vehicle for the reliable HTML OPEN / --mode open / draft-HTML paths.
            // From: uses the resolved address on a live path, else the raw --account (headless preview).
            let attPaths = try attach.map { try resolveAttachmentPath($0) }
            var emlPath: String?
            // MODE-keyed (not willOpen): a plain-body `--mode open --dry-run` must still build
            // the .eml so `--out` runs through confineWriteDestination and the preview reports
            // the planned eml_path — otherwise a preview accepts a destination --execute
            // refuses (review-caught). The WRITE below stays willExecute-gated.
            if html != nil || !attPaths.isEmpty || mode == "open" {
                let atts = try attachmentsFromPaths(attPaths)
                // emitBcc: this .eml is only ever OPENED in a compose window (Mail moves Bcc to the
                // bcc field + strips the header on send) or written to --out — never wire-sent — so
                // carrying --bcc into it is safe and lets the open path honor --bcc.
                let eml = try EmlBuilder(from: senderAddress ?? account, to: toL, cc: ccL, bcc: bccL, subject: subject,
                                     textBody: body.isEmpty ? nil : body, htmlBody: html, attachments: atts,
                                     emitBcc: true).build()
                let dest = try emlDestURL(out: out, materialise: willExecute)
                // Write ONLY under willExecute (bucket 2, matching DraftRichCommand): a dry-run
                // still BUILDS the .eml (same validation as execute) and reports the planned
                // destination, but leaves no bytes on disk. The live open paths below all imply
                // willExecute, so the file they open always exists.
                if willExecute {
                    try eml.write(to: dest, atomically: true, encoding: .utf8)
                    if out == nil { OwnedTempDir.restrictToOwner(dest) }
                    // THREE routes are proven not to read this file, not one. The first version of
                    // this comment claimed the enumeration was closed at gui-send and it was not:
                    // `willAutoSend` with attachments and a plain `willDraft` with attachments both
                    // write a complete RFC-822 message — base64 attachment payloads included, so
                    // strictly MORE content than the gui-send file — and then call
                    // `sendWithAttachments`/`saveDraft`, which take attachment paths and never touch
                    // it. An over-general claim in exactly the place Q4l exists to stop making them.
                    let handedOff = generatedEmlIsHandedToMail(
                        willGuiSend: willGuiSend, willAutoSend: willAutoSend,
                        hasAttachments: !attPaths.isEmpty, willDraft: willDraft, hasHTML: html != nil)
                    if generatedEmlIsDisposable(out: out, handedToMail: handedOff) {
                        SignalSafeCleanup.track(dest.path)
                    }
                }
                emlPath = dest.path
            }

            var executed = false
            var opened = false
            var drafted = false
            var note: String?
            // ORACLE-MIRRORED SEND RATE LIMIT (bucket 1, unconditional). Applied to `send` and
            // `forward` ONLY, because those are the two the oracle puts in the "sends" tier
            // (OPERATION_TIERS: send_email, send_email_with_attachments, forward_message). It is
            // deliberately NOT applied to `reply`, which the oracle tiers as "expensive_ops" — a
            // tier this port does not carry (see SendRateLimiter). Only branches that actually put
            // mail on the wire consume budget; every preview path is excluded because each `will*`
            // predicate folds in `willExecute`.
            if willGuiSend || willAutoSend {
                let rl = SendRateLimiter.consume()
                guard rl.allowed else { throw AppleError.validation(SendRateLimiter.refusal(rl)) }
                if rl.degraded {
                    FileHandle.standardError.write(Data(
                        ("warning: send rate-limit state is unwritable — the oracle's 3-sends/60s cap "
                         + "is NOT being enforced for this call (failing open).\n").utf8))
                }
            }
            if willGuiSend {
                // Opt-in HTML auto-send via GUI keystrokes (fragile — see MailScript.sendHtmlViaGui).
                // The raw HTML goes to a temp file the script reads via `cat` (never interpolated).
                // Same owned directory as the .eml temps, for the same reason: this holds the full
                // HTML body of an outgoing message. The `defer` below covers the normal exit, but a
                // SIGKILL or a panic leaves it behind — and a leftover in the SHARED temp root is
                // one the reaper would never find, which is exactly how the 244 .eml files
                // accumulated. Inside the owned directory the prefix-matching reaper collects it.
                let htmlTmp = try emlTempDirectory(materialise: true)
                    .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                try (html ?? "").write(to: htmlTmp, atomically: true, encoding: .utf8)
                OwnedTempDir.restrictToOwner(htmlTmp)
                defer { try? FileManager.default.removeItem(at: htmlTmp) }
                // The `defer` covers a normal exit; a signal death skips it. Safe to register
                // BECAUSE `sendHtmlViaGui` is synchronous — nothing reads this file once the call
                // returns. The `.eml` temps a few lines down are deliberately NOT registered: they
                // are handed to Mail by `open -a Mail` and read AFTER we exit, so unlinking one on
                // Ctrl-C would destroy a live hand-off rather than clean up a leak (Q4k).
                SignalSafeCleanup.track(htmlTmp.path)
                try MailScript().sendHtmlViaGui(htmlPath: htmlTmp.path, subject: subject,
                    to: toL, cc: ccL, bcc: bccL, attachmentPaths: attPaths, sender: senderAddress)
                executed = true
                note = "sent via GUI keystroke automation (--gui-send); required Accessibility permission and stole window focus"
            } else if willOpenHtml, let emlPath {
                // Reliable HTML path: open the rendered .eml as a compose window for review.
                try MailScript().openEml(path: emlPath)
                opened = true
                note = "HTML rendered in a Mail compose window for review — click Send, or re-run with --gui-send to auto-send (GUI automation; needs Accessibility). The .eml is kept at eml_path."
            } else if willAutoSend {
                if !attPaths.isEmpty {
                    // Attachments, no HTML: direct AppleScript route (matches send_email_with_attachments).
                    try MailScript().sendWithAttachments(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL, attachmentPaths: attPaths, sender: senderAddress)
                } else {
                    // Plain text.
                    try MailScript().send(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL, sender: senderAddress)
                }
                executed = true
            } else if willOpen, let emlPath {
                // --mode open: render the .eml as a compose window for review (ANY body type). No send.
                try MailScript().openEml(path: emlPath)
                opened = true
                note = "compose window opened for review (--mode open) — not sent; click Send in Mail if desired. The .eml is kept at eml_path."
            } else if willDraft {
                // --mode draft: save to Drafts (no send). Plain/attachment bodies save DIRECTLY via
                // AppleScript (`save` an outgoing message) — reliable. HTML cannot be saved to Drafts
                // headlessly (Mail's AppleScript `content` is plain-text only, and a
                // LaunchServices-opened `.eml` window never surfaces in `outgoing messages` to be
                // saved). Rather than force-open a compose window that can't auto-save AND can't be
                // closed programmatically (leaving a stuck window), we WRITE the rendered `.eml` and
                // tell the operator how to file it. drafted:false is honest — it is NOT yet in Drafts.
                if html != nil {
                    drafted = false
                    note = "HTML can't be saved to Drafts headlessly (Mail limitation) — the rendered .eml is at eml_path; open it (`apple mail draft-rich --open`, or `open <eml_path>`) and press Cmd-S to file it in Drafts."
                } else {
                    try MailScript().saveDraft(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL,
                                               attachmentPaths: attPaths, sender: senderAddress)
                    drafted = true
                }
            } else if willExecute {
                note = "mode '\(mode)' is preview-only; use --mode send to deliver"
            }
            // A dry-run that reports an eml_path must say the file was NOT written (mirrors
            // DraftRichCommand's preview note — review-caught: the planned path read as real).
            if !willExecute, emlPath != nil {
                note = "dry-run: nothing written or opened; eml_path is the planned destination."
            }

            let preview = Preview(action: "send", mode: mode, account: account, sender_address: senderAddress,
                                  to: toL, cc: ccL, bcc: bccL,
                                  subject: subject, has_html: html != nil, attachments: attach,
                                  eml_path: emlPath, dry_run: !willExecute, executed: executed, opened: opened, drafted: drafted, note: note)
            try Output.emit(tool: "mail", data: preview, text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct ReplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reply to a message by id or --subject (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to reply to (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Reply to the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Mailbox to scope the --subject lookup (default INBOX — oracle B searches only the inbox; use 'All' for the previous store-wide sweep).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long) var body: String
    @Flag(name: .long, help: "Reply to all recipients.") var all = false
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "HTML reply body. Default opens a rendered compose window for review; add --gui-send to auto-send.") var html: String?
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Flag(name: .long, help: "Auto-send an --html reply THREADED via Mail's native reply verb + pasteboard paste (needs Accessibility, steals focus). Opt-in; without it --html --mode send opens an unthreaded .eml compose window.") var guiSend = false

    struct Preview: Encodable {
        let action: String; let target: String; let matched_message_id: String?
        let reply_all: Bool; let mode: String; let has_html: Bool; let sender_address: String?
        let to: [String]; let cc: [String]; let bcc: [String]; let attachments: [String]
        let dry_run: Bool; let executed: Bool; let opened: Bool; let note: String?
        /// Id of the newly-created reply (oracle A `reply_to_message` → `reply_id`). Populated
        /// on BOTH native paths (plain and pasteboard-HTML) in every delivery mode; nil on
        /// dry-run and on the unthreaded .eml open path (Mail assigns no id to a
        /// LaunchServices-opened window).
        var reply_id: String? = nil
        /// gap17 --mode draft: true when the reply was composed and filed to Drafts, NOT sent
        /// (oracle B reply_to_email send=False). Always emitted, like `mail send`'s twin field
        /// (review: the same wire key must not have two shapes across verbs of one tool).
        var drafted: Bool = false
        /// Oracle A returns the ORIGINAL message's id as `original_message_id`; `matched_message_id`
        /// is the CLI's original key for the same value. Both are emitted (additive).
        var original_message_id: String? = nil
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see SendCommand).
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            // EMPTY-SUBJECT guard, both modes, BEFORE the store opens. EnvelopeIndex skips an
            // empty subjectContains, so `--subject ""` would resolve to the NEWEST message in
            // the entire store — and under v2 an unsandboxed flagless reply then SENDS a real
            // reply quoting it. `reply --subject "$UNSET_VAR"` must refuse, not fire
            // (review-caught; same class as the draft empty-subject guard).
            if let subject, subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppleError.validation("--subject must not be empty or whitespace; an empty keyword matches every message in the store.")
            }
            // Mode + --gui-send validity are pure flag checks — hoisted above the store open so
            // they hold on BOTH paths, store-independently (preview honesty; review-caught: the
            // notImplemented refusal was execute-only, so a dry-run previewed a mode --execute
            // refuses with 70).
            guard ["send", "draft", "open"].contains(mode) else {
                throw AppleError.validation("--mode must be send, draft, or open.")
            }
            if guiSend {
                guard html != nil else { throw AppleError.validation("--gui-send only applies to an --html reply.") }
            }
            // Attachment paths resolved ONCE, in BOTH modes, and BEFORE the store opens:
            // existence, the 25 MB cap, the executable-extension blocklist, the sensitive-dir
            // refusal and the control-char rejection are filesystem/string checks that depend
            // only on `attach`. Hoisting them here makes a preview refuse exactly what execute
            // would, store-independently, and matches SendCommand's precedence (review-caught
            // twice: they first ran only inside the live block, then only after target
            // resolution — where a not_found target masked them).
            let attachPaths = try attach.map { try resolveAttachmentPath($0) }
            let ctx = try MailContext()
            // Resolve the target to a full summary (need original sender + subject to compose).
            let row: [String: String?]
            if let id {
                guard let r = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                row = r
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                // extra16: oracle B scopes the reply subject lookup to the account's INBOX;
                // the old hardwired "All" could bind an archived/sent message to the same
                // keyword. --mailbox restores the sweep deliberately. Unknown mailbox is the
                // SHARED fail-loud guard (review L2: reply had adopted the weakest of the
                // three not-found shapes).
                try requireMailboxKnown(ctx: ctx, name: mailbox, accountUUID: f.accountUUID)
                f.mailboxName = mailbox; f.subjectContains = subject; f.limit = 1
                guard let r = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)' in mailbox '\(mailbox)' (pass --mailbox All to sweep the whole store).") }
                row = r
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            var target = ctx.decodeSummary(row)
            // reply-all folds in the original to/cc — but the summary decode omits recipients, so
            // hydrate them from the index (same source `mail get` uses) or --all would fold nothing.
            if all {
                let recips = try ctx.index.recipients(messageRowid: intVal(row["rowid"]) ?? 0)
                target.to = recips.to
                target.cc = recips.cc
            }
            // Reply addresses the ORIGINAL SENDER (never a user-supplied recipient) — so a reply
            // can only be self-safe when the original message is from self. reply-all also folds
            // in the original to/cc. guardOutbound then requires EVERY recipient to be the
            // operator's allowlisted self-address → replying to real mail is refused, fail-closed.
            guard let sender = target.sender_address, !sender.isEmpty else {
                throw AppleError.upstream("cannot determine the original sender address to reply to.")
            }
            // Every index-sourced recipient reduced to its bare addr-spec + control-char
            // checked: the reply-all fold carries REMOTE display names, which must never reach
            // the US-joined dispatch argv (see outboundAddressFromIndex).
            var recipients = [try outboundAddressFromIndex(sender)]
            if all {
                recipients += try ((target.to ?? []) + (target.cc ?? [])).map(outboundAddressFromIndex)
                    .filter { !$0.isEmpty }
            }
            let ccL = try splitRecipients(cc), bccL = try splitRecipients(bcc)

            let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
            // Quote from the index snippet/content already in hand — avoids a slow full-body
            // AppleScript scan (message-id has no Mail index; a body fetch can hang on Gmail).
            let original = target.content ?? target.snippet
            let quotedPlain = original.map { "\n\n> " + $0.replacingOccurrences(of: "\n", with: "\n> ") } ?? ""

            // Four mutually-exclusive live actions (gap17/gap15) — the partition is a PURE
            // pinned function (review M6: the PREVIOUS version of this partition shipped a
            // real bug — `--mode draft --html` opened a compose window for a caller who
            // asked for a draft — and nothing pinned it).
            let route = ReplyRouting.decide(willExecute: willExecute, hasHtml: html != nil,
                                            guiSend: guiSend, mode: mode)
            let willNativeHtml = route.nativeHtml
            let willOpenHtml = route.openHtml
            let willLiveOutbound = willNativeHtml || willOpenHtml

            // Outbound gate in BOTH modes (preview honesty): the recipient set is already
            // resolved above on the dry-run path too, so a sandboxed preview refuses a
            // non-allowlisted reply exactly as --execute would. Fires before any attachment
            // read, .eml/.html build, or send.
            try guardOutbound(recipients: recipients + ccL + bccL, sandboxActive: sandboxActive,
                                  applyRecipientCap: false)   // oracle reply_to_message: no cap
            var executed = false
            var opened = false
            var drafted = false
            var senderAddress: String?
            var note: String?
            var replyID: String?
            if willLiveOutbound {
                // A live reply needs a real subject (replySubject always carries "Re:" today, so
                // this is belt-and-suspenders).
                guard !replySubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required for a live reply; refusing an empty/whitespace subject.")
                }
                // Resolve --account to the send-from identity (mirrors SendCommand): the reply goes
                // out FROM this account's address, not Mail's default. Live-path only, so headless
                // dry-runs never touch Mail; unknown/addressless account is a not_found up front.
                if let account {
                    guard let addr = AccountDirectory().sendAddress(for: account) else {
                        throw AppleError.notFound("account '\(account)' not found or has no send address.")
                    }
                    senderAddress = addr
                }
                // ORACLE-MIRRORED REPLY RATE LIMIT (D8, SAFETY WINS). Oracle A tiers
                // `reply_to_message` as `expensive_ops` (20/60s) and runs check_rate_limit per
                // operation regardless of send/draft/open — so this consumes the reply budget once
                // per live reply, closing the runaway-loop hole where a loop replied instead of
                // sending to route around the `sends` cap. Only the EXECUTE path reaches here (the
                // preview returns before willLiveOutbound), so a dry-run consumes no budget. The
                // reply window is SEPARATE from the send window (distinct oracle tiers).
                let rl = ReplyRateLimiter.consume()
                guard rl.allowed else { throw AppleError.validation(ReplyRateLimiter.refusal(rl)) }
                if rl.degraded {
                    FileHandle.standardError.write(Data(
                        ("warning: reply rate-limit state is unwritable — the oracle's 20-replies/60s "
                         + "(expensive_ops) cap is NOT being enforced for this call (failing open).\n").utf8))
                }
                // Quoted original, escaped into the HTML part (willOpenHtml only — the
                // willNativeHtml path pastes the BARE fragment on top of Mail's native reply,
                // which already carries its own quoted original; adding ours would double-quote).
                let quotedHTML = original.map {
                    "<br><br><blockquote>" + EmlBuilder.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>"
                } ?? ""
                if willNativeHtml {
                    // gap15/extra15 + D8 item 5: reply via the oracle's pasteboard flow — Mail's
                    // native reply verb composes the threaded reply (In-Reply-To / References /
                    // replied-to state / native quote), then the fragment is pasted into the
                    // compose window via NSPasteboard + cmd-v (needs Accessibility, steals focus,
                    // restores the clipboard after). Serves BOTH the plain reply (fragment =
                    // oracle-B plain-wrap of --body) and the HTML reply (fragment = --html). The
                    // fragment travels by TEMP FILE PATH, never through script source.
                    guard let imid = target.internet_message_id, !imid.isEmpty else {
                        throw AppleError.upstream("message '\(target.id)' has no RFC Message-ID; cannot reply to it via Mail.app.")
                    }
                    let htmlTmp = try emlTempDirectory(materialise: true)
                        .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                    // Oracle B fidelity (compose.py:519-530): the plain reply wraps --body in a
                    // <div> + gap divs (`MailComposeFragment.replyPlain`); the HTML reply appends
                    // the gap divs to --html (`replyHtml`). Both keep Mail's quoted original in its
                    // HTML layer (Mail strips trailing <br>, hence divs — the oracle's own comment).
                    let fragment = html.map(MailComposeFragment.replyHtml) ?? MailComposeFragment.replyPlain(body)
                    try fragment.write(to: htmlTmp, atomically: true, encoding: .utf8)
                    OwnedTempDir.restrictToOwner(htmlTmp)
                    defer { try? FileManager.default.removeItem(at: htmlTmp) }
                    SignalSafeCleanup.track(htmlTmp.path)   // synchronous consumer; see the send path

                    switch try MailScript().nativeReplyHtml(internetMessageID: imid,
                                                            accountName: target.account.isEmpty ? nil : target.account,
                                                            replyAll: all, sender: senderAddress,
                                                            selfAllowlist: outboundAllowlist(sandboxActive: sandboxActive),
                                                            cc: ccL, bcc: bccL, attachmentPaths: attachPaths,
                                                            mailboxHint: target.mailbox,
                                                            mode: mode, htmlFragmentPath: htmlTmp.path) {
                    case .sent(let newID, let actual):
                        executed = true
                        replyID = newID
                        if !actual.isEmpty { recipients = actual }
                        note = html != nil
                            ? "HTML reply sent via Mail's native reply verb + pasteboard paste (needed Accessibility, stole focus); threading + Mail's HTML quote layer preserved. NOTE: --body is not carried on this path (oracle parity — the HTML fragment IS the reply body)."
                            : "replied via Mail's native reply verb + pasteboard paste (needed Accessibility, stole focus); threading headers, replied-to state, and Mail's HTML quote layer preserved (--body pasted as HTML per oracle B)."
                    case .drafted(let newID, let actual):
                        // executed stays false: nothing left the machine (matches
                        // `mail send --mode draft`'s contract — review caught the two verbs
                        // answering "did mail go out?" oppositely for identical semantics).
                        drafted = true
                        replyID = newID
                        if !actual.isEmpty { recipients = actual }
                        note = (html != nil ? "HTML reply" : "reply")
                            + " composed via Mail's native reply verb + pasteboard paste and saved to Drafts (--mode draft) — NOT sent; needed Accessibility. A compose window showing the filed draft may remain open (Mail quirk, measured); close it with Cmd-W."
                    case .opened(let newID, let actual):
                        opened = true
                        replyID = newID
                        if !actual.isEmpty { recipients = actual }
                        note = (html != nil ? "HTML reply" : "reply")
                            + " composed via Mail's native reply verb + pasteboard paste and left open in a visible compose window (--mode open) — NOT sent; review and click Send"
                    case .notFound:
                        throw AppleError.notFound("message '\(imid)' is not reachable in Mail.app to reply to.")
                    case .sendFailed(let newID):
                        throw AppleError.upstream("Mail reported the reply was NOT sent (send returned false — account offline or the server refused). Draft id \(newID) may still be in Mail.")
                    case .refused(let bad, let discarded):
                        throw AppleError.mailSafety(refusalMessage(kind: "reply", bad: bad, discarded: discarded, sandboxActive: sandboxActive), sandbox: mailOutboundRefusalIsSandboxCaused(reason: bad, sandboxActive: sandboxActive))
                    case .composeFailed(let reason, let discarded):
                        throw AppleError.upstream(composeFailureMessage(kind: "reply", reason: reason, discarded: discarded))
                    }
                } else if willOpenHtml {
                    // Reliable HTML reply: build a multipart .eml (quote embedded) and open a
                    // rendered compose window for review.
                    let atts = try attachmentsFromPaths(attachPaths)
                    // emitBcc: safe — this .eml is only opened in a compose window, never wire-sent.
                    let eml = try EmlBuilder(from: senderAddress, to: recipients, cc: ccL, bcc: bccL, subject: replySubject,
                                             textBody: body + quotedPlain, htmlBody: (html ?? "") + quotedHTML, attachments: atts,
                                             emitBcc: true).build()
                    let dest = try emlDestURL(out: nil, materialise: true)
                    try eml.write(to: dest, atomically: true, encoding: .utf8)
                    OwnedTempDir.restrictToOwner(dest)          // always a temp on this path
                    try MailScript().openEml(path: dest.path)
                    opened = true
                    note = "HTML reply rendered in a compose window for review — click Send, or re-run with --gui-send to auto-send."
                }
            }
            // (willLiveOutbound == willExecute — the two live flags partition every
            // mode × html × gui-send combination, so the only non-live path is a dry-run,
            // which falls through to the honest executed=false/opened=false preview below.)

            try Output.emit(tool: "mail", data: Preview(action: "reply", target: id ?? "subject:\(subject ?? "")",
                matched_message_id: target.id, reply_all: all, mode: mode, has_html: html != nil, sender_address: senderAddress,
                to: recipients, cc: ccL, bcc: bccL, attachments: attach,
                dry_run: !willExecute, executed: executed, opened: opened, note: note,
                reply_id: replyID, drafted: drafted, original_message_id: target.id), text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct ForwardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forward", abstract: "Forward a message by id or --subject (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to forward; or use --subject.") var id: String?
    @Option(name: .long, help: "Forward the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long, help: "Mailbox to scope the --subject lookup (default INBOX — oracle B forward_email's default; use 'All' for a store-wide sweep).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Text to prepend before the forwarded content.") var body: String?

    struct Preview: Encodable {
        let action: String; let matched_message_id: String?; let sender_address: String?; let to: [String]
        let cc: [String]; let bcc: [String]; let dry_run: Bool; let executed: Bool; let note: String?
        /// Id of the newly-created forward (oracle A `forward_message` → `forward_id`). Present
        /// only on an executed native forward; nil on dry-run.
        var forward_id: String? = nil
        /// Oracle A `forward_message` → `original_message_id`; mirrors `matched_message_id`.
        var original_message_id: String? = nil
        /// Oracle A `forward_message` → `recipients` (server.py:1901-1908); mirrors `to`
        /// under the alias convention (extra14).
        var recipients: [String] = []
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see SendCommand).
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let toL = try splitRecipients(to), ccL = try splitRecipients(cc), bccL = try splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            // EMPTY-SUBJECT guard, both modes, BEFORE the store opens: an empty keyword would
            // resolve to the NEWEST message in the store, and an unsandboxed flagless forward
            // then dispatches its body AND attachments to the given recipient —
            // `forward --subject "$UNSET_VAR" --to boss@…` must refuse, not exfiltrate
            // (review-caught; same class as the draft/reply empty-subject guards).
            if let subject, subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppleError.validation("--subject must not be empty or whitespace; an empty keyword matches every message in the store.")
            }
            // Outbound guard fires BEFORE any resolve/emit → one envelope. BOTH modes (preview
            // honesty): a sandboxed dry-run to a non-allowlisted recipient must refuse exactly
            // as --execute would; recipients come from flags, so no Mail access is needed.
            try guardOutbound(recipients: toL + ccL + bccL, sandboxActive: sandboxActive,
                                  applyRecipientCap: false)   // oracle forward_message: no cap
            // Resolve --account to the send-from identity (mirrors SendCommand/ReplyCommand): the
            // forward goes out FROM this account's address. Live-path only (headless dry-runs never
            // touch Mail); fires before the Envelope Index opens, so an unknown account is a clean
            // not_found even where the index is unreadable.
            var senderAddress: String?
            if willExecute, let account {
                guard let addr = AccountDirectory().sendAddress(for: account) else {
                    throw AppleError.notFound("account '\(account)' not found or has no send address.")
                }
                senderAddress = addr
            }
            let ctx = try MailContext()
            let target: MailMessage
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                target = ctx.decodeSummary(row)
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                try requireMailboxKnown(ctx: ctx, name: mailbox, accountUUID: f.accountUUID)
                f.mailboxName = mailbox; f.subjectContains = subject; f.limit = 1
                guard let row = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)' in mailbox '\(mailbox)' (pass --mailbox All to sweep the whole store).") }
                target = ctx.decodeSummary(row)
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            // Forward composes a NEW message to the self-only --to (guardOutbound above), carrying
            // the original body — so forwarding real mail to yourself is fine (recipient is self).
            var executed = false
            var note: String?
            var forwardID: String?
            var verifiedRecipients = toL
            if willExecute {
                // Parity: use Mail's NATIVE `forward` verb. A re-composed plain-text quote drops
                // the original's ATTACHMENTS and flattens its rich formatting — both oracles
                // forward natively (oracle A returns the new id as `forward_id`, and its
                // `include_attachments` default is True). See MailScript's "Native reply /
                // forward" note for the fail-closed recipient readback.
                guard let imid = target.internet_message_id, !imid.isEmpty else {
                    throw AppleError.upstream("message '\(target.id)' has no RFC Message-ID; cannot forward it via Mail.app.")
                }
                // ORACLE-MIRRORED SEND RATE LIMIT — `forward_message` is in the oracle's "sends"
                // tier alongside send_email (OPERATION_TIERS). This is the execute path; the
                // preview returns before reaching here, so a dry-run consumes no budget.
                let rl = SendRateLimiter.consume()
                guard rl.allowed else { throw AppleError.validation(SendRateLimiter.refusal(rl)) }
                if rl.degraded {
                    FileHandle.standardError.write(Data(
                        ("warning: send rate-limit state is unwritable — the oracle's 3-sends/60s cap "
                         + "is NOT being enforced for this call (failing open).\n").utf8))
                }
                // gap17/extra15 (D8 item 5): a --body prepend is pasted as HTML (oracle B
                // forward_email), NEVER `set content` — so Mail's forwarded original keeps its HTML
                // layer. No --body ⇒ empty fragment path ⇒ the shared tail skips the paste and the
                // native forward is delivered untouched (matches oracle B, which pastes only when a
                // message is provided; the empty-body forward then needs no Accessibility).
                var fwdFragmentPath = ""
                var fwdHtmlTmp: URL?
                let prepend = body ?? ""
                if !prepend.isEmpty {
                    let htmlTmp = try emlTempDirectory(materialise: true)
                        .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                    try MailComposeFragment.forwardPrepend(prepend).write(to: htmlTmp, atomically: true, encoding: .utf8)
                    OwnedTempDir.restrictToOwner(htmlTmp)
                    SignalSafeCleanup.track(htmlTmp.path)   // synchronous consumer; see the reply path
                    fwdHtmlTmp = htmlTmp
                    fwdFragmentPath = htmlTmp.path
                }
                // Deleted after nativeForward returns (synchronous consumer); the defer is at the
                // `if willExecute` scope so it fires AFTER the switch, not before the paste reads it.
                defer { if let f = fwdHtmlTmp { try? FileManager.default.removeItem(at: f) } }
                switch try MailScript().nativeForward(internetMessageID: imid,
                                                      accountName: target.account.isEmpty ? nil : target.account,
                                                      htmlFragmentPath: fwdFragmentPath, to: toL, cc: ccL, bcc: bccL,
                                                      sender: senderAddress,
                                                      selfAllowlist: outboundAllowlist(sandboxActive: sandboxActive),
                                                      mailboxHint: target.mailbox) {
                case .sent(let newID, let actual):
                    executed = true
                    forwardID = newID
                    // Echo what MAIL actually addressed when it reported it (review L7 —
                    // reply already does this; the request-echo stays the preview shape).
                    if !actual.isEmpty { verifiedRecipients = actual }
                    // Disclose the Accessibility/focus-steal only when a --body prepend was actually
                    // pasted (decision-5, 2026-08-18) — an empty-body forward uses the native verb
                    // untouched and needs no Accessibility, mirroring oracle B (pastes only when a
                    // message is provided). Keeps the surfacing consistent with the reply notes.
                    note = prepend.isEmpty
                        ? "forwarded via Mail's native forward verb — the original's attachments and formatting are carried"
                        : "forwarded via Mail's native forward verb — the original's attachments and formatting are carried; --body was pasted as HTML (needed Accessibility, stole focus) so Mail's forwarded original keeps its HTML layer"
                case .notFound:
                    throw AppleError.notFound("message '\(imid)' is not reachable in Mail.app to forward.")
                case .sendFailed(let newID):
                    throw AppleError.upstream("Mail reported the forward was NOT sent (send returned false — account offline or the server refused). Draft id \(newID) may still be in Mail.")
                case .refused(let bad, let discarded):
                    throw AppleError.mailSafety(refusalMessage(kind: "forward", bad: bad, discarded: discarded, sandboxActive: sandboxActive), sandbox: mailOutboundRefusalIsSandboxCaused(reason: bad, sandboxActive: sandboxActive))
                case .composeFailed(let reason, let discarded):
                    throw AppleError.upstream(composeFailureMessage(kind: "forward", reason: reason, discarded: discarded))
                case .drafted, .opened:
                    // nativeForwardScript pins theMode to "send" in its preamble, so the script
                    // can never emit drafted/opened. Total-switch arm, fail-loud if it ever does.
                    throw AppleError.upstream("Mail returned an unexpected non-send outcome for a forward; nothing was sent.")
                }
            }
            try Output.emit(tool: "mail", data: Preview(action: "forward", matched_message_id: target.id, sender_address: senderAddress,
                to: toL, cc: ccL, bcc: bccL, dry_run: !willExecute, executed: executed, note: note,
                forward_id: forwardID, original_message_id: target.id,
                recipients: verifiedRecipients), text: global.text, sandboxActive: sandboxActive)
        }
    }
}


/// gap19/gap20 pure cores (pinned): oracle B's rich-draft helpers, ported verbatim from
/// tools/compose.py.
enum RichDraft {
    /// `_safe_eml_name` (compose.py:29-33): non-[A-Za-z0-9._-] runs → "-", strip "-._" from
    /// both ends, fallback "rich-email-draft", cap 80. The regex output is pure ASCII, so the
    /// 80 cap is code-point == byte exact like Python's slice.
    static func safeEmlName(_ subject: String) -> String {
        let base = subject.isEmpty ? "rich-email-draft" : subject
        var cleaned = ""
        var pendingDash = false
        for ch in base.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") {
                if pendingDash { cleaned.append("-"); pendingDash = false }
                cleaned.append(ch)
            } else {
                pendingDash = true
            }
        }
        // Python's re.sub replaces LEADING runs with "-" too; the strip("-._") then removes
        // them — replicate by stripping the edge set after the fact.
        var trimmed = cleaned
        while let f = trimmed.first, f == "-" || f == "." || f == "_" { trimmed.removeFirst() }
        while let l = trimmed.last, l == "-" || l == "." || l == "_" { trimmed.removeLast() }
        if trimmed.isEmpty { trimmed = "rich-email-draft" }
        return String(trimmed.prefix(80))
    }

    /// `_default_rich_draft_path` (compose.py:36-40): a DETERMINISTIC subject-named cache file,
    /// idempotently overwritten — preview and execute name the SAME path, unlike the old
    /// per-run temp UUID. Root is the CLI's own cache dir (the oracle writes into
    /// `apple-mail-mcp/rich-drafts` — writing into another tool's cache would be rude;
    /// disclosed on port-spec row 18).
    static func defaultPath(subject: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/apple-cli/rich-drafts")
            .appendingPathComponent(safeEmlName(subject) + ".eml")
    }

    /// `_build_html_from_text` (compose.py:64-74), byte-identical markup. Escaping is
    /// Python `html.escape` with its DEFAULT quote=True — measured: it escapes `"` to
    /// `&quot;` and `'` to `&#x27;` too, so the three-entity version diverged on any body
    /// carrying quotes. `&` first, exactly like Python.
    static func htmlFromText(_ text: String) -> String {
        let safe = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
        return "<html><body style=\"font-family: -apple-system, BlinkMacSystemFont, "
            + "'Segoe UI', Arial, sans-serif; line-height: 1.45; color: #111111;\">"
            + "<pre style=\"white-space: pre-wrap; font: inherit; margin: 0;\">"
            + safe
            + "</pre></body></html>"
    }

    /// `_prepare_rich_bodies` (compose.py:77-101): fill placeholders, report what is missing.
    static func prepareBodies(subject: String, text: String?, html: String?)
        -> (plain: String, html: String, missing: [String]) {
        var plain = text ?? ""
        var rich = html ?? ""
        if plain.isEmpty && rich.isEmpty {
            plain = "Draft outline\n\n- Add recipients\n- Add the final rich-text content\n- Review before sending"
            return (plain, htmlFromText(plain), ["body"])
        }
        if !rich.isEmpty && plain.isEmpty {
            let trimmedSubject = subject.trimmingCharacters(in: RichDraft.pythonWhitespace)
            plain = (trimmedSubject.isEmpty ? "" : trimmedSubject + "\n\n")
                + "This message contains rich HTML content. Open it in Mail for the rendered version."
        }
        if !plain.isEmpty && rich.isEmpty {
            rich = htmlFromText(plain)
        }
        return (plain, rich, [])
    }

    /// Python `str.strip()`'s default whitespace (review M1, the repo's recurring
    /// counting-unit/API-set class, 3rd occurrence): `.whitespacesAndNewlines` covers
    /// Zs/Zl/Zp + TAB/LF/VT/FF/CR/NEL but NOT the C0 separators FS/GS/RS/US
    /// (U+001C–U+001F), which Python's isspace includes — measured end-to-end: a
    /// VT/FF/FS-only subject diverged from the executed oracle on missing_details.
    static let pythonWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: Unicode.Scalar(0x1C)!...Unicode.Scalar(0x1F)!)
        return set
    }()

    /// gap19: the oracle's missing_details list (compose.py:180-185).
    static func missingDetails(subject: String, to: [String], bodyMissing: [String]) -> [String] {
        var out: [String] = []
        if subject.trimmingCharacters(in: RichDraft.pythonWhitespace).isEmpty { out.append("subject") }
        if to.isEmpty { out.append("to") }
        out.append(contentsOf: bodyMissing)
        return out
    }
}

/// gap17/gap15 + D8 item 5 (pinned): which live path a reply takes. Exactly ONE of the two is
/// true when willExecute; both false otherwise.
///  * nativeHtml — Mail's native `reply` verb + the oracle's NSPasteboard paste. Serves BOTH the
///    plain reply (D8: an oracle-B plain-wrapped fragment preserving Mail's HTML quote) AND the
///    threaded HTML reply (gui-send, or an --html draft/open) — needs Accessibility, steals focus.
///  * openHtml — the reliable no-Accessibility path for --html --mode send WITHOUT --gui-send: a
///    rendered .eml compose window (unthreaded, disclosed).
/// The former plain `native` (`set content`) path was REMOVED per D8: it flattened Mail's HTML
/// quote layer, the last behavior-inferior mail sub-path.
enum ReplyRouting {
    static func decide(willExecute: Bool, hasHtml: Bool, guiSend: Bool, mode: String)
        -> (nativeHtml: Bool, openHtml: Bool) {
        guard willExecute else { return (false, false) }
        if !hasHtml { return (true, false) }                 // plain → pasteboard (D8: preserves quote)
        if guiSend || mode != "send" { return (true, false) }
        return (false, true)
    }
}

/// Oracle B's reply/forward body → HTML-fragment wrappers (`tools/compose.py`), ported PURE so the
/// pasteboard fragment is byte-exact to the oracle and revert-red pinnable without live Mail.
enum MailComposeFragment {
    /// Python `html.escape` with its DEFAULT quote=True (`&` first): & < > " ' →
    /// &amp; &lt; &gt; &quot; &#x27;. This matches oracle B's `html_escape` exactly — NOT
    /// `EmlBuilder.escapeHTML`, which emits `&#39;` for the apostrophe (renders identically but is
    /// not the oracle's byte; the repo pins the oracle's byte elsewhere, e.g. RichDraft.htmlFromText).
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// The gap divs oracle B appends so a visible gap separates the pasted body from Mail's quoted
    /// original (Mail strips trailing <br>, hence divs — compose.py:521-523).
    static let gapDivs = "<div><br></div><div><br></div>"

    /// `reply_to_email` plain branch (compose.py:527-530):
    /// `html_content = f"<div>{escape(body).replace(chr(10),'<br>')}</div>{gap}"`.
    static func replyPlain(_ body: String) -> String {
        "<div>" + htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>") + "</div>" + gapDivs
    }

    /// `reply_to_email` HTML branch (compose.py:524-525): `html_content = body_html + gap`.
    static func replyHtml(_ html: String) -> String { html + gapDivs }

    /// `forward_email` message branch (compose.py:1033-1035):
    /// `fwd_html_content = f"{escape(msg).replace(chr(10),'<br>')}<br><br>"` (NO div wrapper, NO
    /// gap divs — the forward's own shape). Only produced when a prepend body is given.
    static func forwardPrepend(_ body: String) -> String {
        htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>") + "<br><br>"
    }
}

struct DraftRichCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft-rich", abstract: "Generate a multipart .eml draft (EXECUTES by default; --dry-run previews; reliable HTML); optionally open it or save it to Drafts.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String?
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .customLong("text-body"), help: "Plain-text body (--text is reserved for global output mode).") var textBody: String?
    @Option(name: .long, help: "HTML body.") var html: String?
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Output .eml path (default: temp dir).") var out: String?
    @Flag(name: .customLong("open"), help: "Open the generated .eml in a Mail compose window for review (no send).") var openInMail = false
    @Flag(name: .long, help: "Open the .eml and save it to Drafts (no send; sandboxed runs restrict recipients to the self-only allowlist).") var saveAsDraft = false
    @Flag(name: .long, help: "Refuse to overwrite an existing .eml at the destination (the deterministic subject-named default overwrites, and DIFFERENT subjects can sanitize to the SAME filename).") var noClobber = false

    struct Result: Encodable {
        let eml_path: String; let subject: String; let to: [String]; let has_html: Bool
        let sender_address: String?; let opened: Bool; let note: String?; let dry_run: Bool
        /// gap19 (oracle create_rich_email_draft echoes): the account identity, CC/BCC, the
        /// oracle's missing_details list ("subject"/"to"/"body"), and whether the compose
        /// window was auto-filed to Drafts (extra19; nil when --save-as-draft wasn't asked).
        var account: String? = nil
        var cc: [String] = []
        var bcc: [String] = []
        var missing_details: [String] = []
        var saved: Bool? = nil
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see SendCommand). DraftRich previously wrote the .eml
            // UNCONDITIONALLY (no willExecute branch — the bucket-2 defect the spec names);
            // it now honors the bound decision like every other write.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let toL = try splitRecipients(to)
            let ccL = try splitRecipients(cc), bccL = try splitRecipients(bcc)
            // gap19: the oracle fills placeholder bodies (Draft outline / HTML wrapper /
            // rich-content fallback) and reports what is missing — ported pure + pinned.
            let bodies = RichDraft.prepareBodies(subject: subject, text: textBody, html: html)
            let missing = RichDraft.missingDetails(subject: subject, to: toL, bodyMissing: bodies.missing)
            // Opening the .eml in Mail (either flag) is a live compose-window action, so gate it
            // consistently with `send --mode open`: guardOutbound (self-only allowlist when the
            // sandbox is active; write-model v2 matches the create_rich_email_draft oracle, which
            // opens to any recipient) + a real subject, BEFORE any Mail access or .eml write. The
            // guard runs on the dry-run path too — a preview must refuse exactly what execute
            // would. The DEFAULT (neither flag) just writes the .eml headlessly and is ungated.
            var senderAddress: String?
            if openInMail || saveAsDraft {
                try guardOutbound(recipients: toL + ccL + bccL,
                                  sandboxActive: sandboxActive,
                                  applyRecipientCap: false)   // oracle-B-only surface: no cap
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required to open a draft-rich compose window.")
                }
                // On the live-open path an unresolvable account stays FAIL-LOUD (deliberate,
                // stricter than the oracle, which silently omits From).
                if let account {
                    guard let addr = AccountDirectory().sendAddress(for: account) else {
                        throw AppleError.notFound("account '\(account)' not found or has no send address.")
                    }
                    senderAddress = addr
                }
            } else if let account, willExecute {
                // extra18: the oracle resolves the sender UNCONDITIONALLY and OMITS From when
                // resolution fails (compose.py:186, :191-192). The headless default used
                // to write the raw account NAME into `From:` — a malformed header Mail
                // ignores. Resolution failure here (Mail unavailable, unknown account) omits
                // the header, byte-what the oracle writes. Gated on willExecute (review):
                // AccountDirectory drives Mail via AppleScript, and a dry-run that LAUNCHES
                // Mail is not a preview — sender_address stays nil in preview, disclosed.
                senderAddress = AccountDirectory().sendAddress(for: account)
            }
            // emitBcc: a draft-rich .eml is only opened / written to disk, never wire-sent, so
            // carrying --bcc into it is safe and required for create_rich_email_draft parity.
            // From: the RESOLVED address or nothing (extra18) — never the raw account name.
            let eml = try EmlBuilder(from: senderAddress, to: toL, cc: ccL, bcc: bccL,
                                 subject: subject, textBody: bodies.plain, htmlBody: bodies.html,
                                 emitBcc: true).build()
            // gap20: the default destination is the oracle's DETERMINISTIC subject-named cache
            // file, idempotently overwritten — so the dry-run preview's eml_path IS the path a
            // subsequent --execute writes (the old per-run temp UUID broke that identity).
            let dest: URL
            if let out {
                dest = try emlDestURL(out: out, materialise: willExecute,
                                      action: "write the rich draft .eml to")
            } else {
                dest = RichDraft.defaultPath(subject: subject)
            }
            if noClobber, FileManager.default.fileExists(atPath: dest.path) {
                throw AppleError.mailSafety("refusing to overwrite existing file '\(dest.path)' (--no-clobber).")
            }
            if willExecute {
                // extra17: the oracle mkdir -p's the parent immediately before writing
                // (compose.py:208) — without it a fresh cache dir (or an --out into a missing
                // directory) leaked a raw NSError as 'unknown'/70. The DEFAULT path's
                // directories go through OwnedTempDir.make (0700 + lstat symlink/owner
                // validation — a pre-planted symlink at the cache dir must not redirect
                // drafts, review); a user-chosen --out parent keeps the plain mkdir since
                // the operator owns that layout.
                do {
                    if out == nil {
                        // Same literal root RichDraft.defaultPath names, so the validated
                        // dirs and the write target cannot drift apart.
                        let caches = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Caches")
                        let appDir = try OwnedTempDir.make("apple-cli", base: caches)
                        _ = try OwnedTempDir.make("rich-drafts", base: appDir)
                    } else {
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                    }
                    try eml.write(to: dest, atomically: true, encoding: .utf8)
                } catch let e as AppleError {
                    throw e
                } catch {
                    throw AppleError.upstream("could not write the rich draft .eml to '\(dest.path)': \(error.localizedDescription)")
                }
                // Default-path files are 0600 (they carry Bcc + full bodies); a user-chosen
                // --out is operator-facing OUTPUT whose mode we do not touch (pinned contract
                // in emlDestURL's doc — review caught the unconditional chmod contradicting it).
                if out == nil { OwnedTempDir.restrictToOwner(dest) }
            }
            // Optional review window (parity with create_rich_email_draft open_in_mail).
            // extra19: --save-as-draft now ATTEMPTS the oracle's auto-file (`save` on the
            // matching open outgoing message, 10 x 0.5s retries — compose.py:104-131) and
            // reports `saved` honestly either way: a LaunchServices-opened .eml window often
            // never surfaces in `outgoing messages`, in which case the oracle reports
            // "Saved in Drafts: no" too, and the Cmd-S instruction remains the fallback.
            var opened = false
            var saved: Bool? = nil
            var note: String?
            if willExecute && (openInMail || saveAsDraft) {
                try MailScript().openEml(path: dest.path)
                opened = true
                if saveAsDraft {
                    let ok = MailScript().saveOpenDraft(subject: subject)
                    saved = ok
                    note = ok
                        ? "compose window opened and auto-filed to Drafts (oracle save verb)."
                        : "compose window opened — the auto-save found no matching outgoing message (Mail often doesn't register a LaunchServices-opened .eml); press Cmd-S to file it in Drafts."
                } else {
                    note = "compose window opened for review (not sent)."
                }
            } else if !willExecute {
                note = "dry-run: nothing written or opened; eml_path is the planned destination."
            }
            try Output.emit(tool: "mail", data: Result(eml_path: dest.path, subject: subject, to: toL,
                has_html: html != nil, sender_address: senderAddress, opened: opened, note: note,
                dry_run: !willExecute,
                account: account, cc: ccL, bcc: bccL, missing_details: missing,
                saved: saved), text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct DraftCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft", abstract: "Manage drafts: list | create | send | open | delete (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Action: list | create | send | open | delete.") var action: String
    @Option(name: .long) var account: String?
    @Option(name: .long) var subject: String?
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long) var body: String?
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "EXACT (case-insensitive) subject of the draft to send/open/delete — not a keyword/substring.") var draftSubject: String?

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see SendCommand).
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            guard ["list", "create", "send", "open", "delete"].contains(action) else {
                throw AppleError.validation("draft action must be list, create, send, open, or delete.")
            }
            let script = MailScript()

            // list — a live READ of Mail's real Drafts mailbox (no gate).
            if action == "list" {
                let drafts = try script.listDrafts()
                struct DraftRow: Encodable { let subject: String; let recipient: String; let date_sent: String }
                struct DraftsResult: Encodable { let action: String; let drafts: [DraftRow]; let count: Int }
                let rows = drafts.map { DraftRow(subject: $0.subject, recipient: $0.recipient, date_sent: $0.date_sent) }
                try Output.emit(tool: "mail", data: DraftsResult(action: "list", drafts: rows, count: rows.count),
                                text: global.text)
                return
            }

            // create / delete — live Mail Drafts mutations (sandbox: subject must carry the label).
            // send — routed to `mail send` (note); open — Mail-UI only (note).
            var executed = false
            var note: String?
            // On a successful `draft send`, the verified recipients the mail was dispatched to (the
            // draft's OWN pre-set to/cc/bcc, which this command never supplied) — surfaced in the
            // envelope's `to` so the machine contract reflects who it actually went to.
            var draftSentTo: [String]?
            let subj = subject ?? draftSubject
            // Sandbox restriction (bucket 3): inside the sandbox, every draft the command
            // touches must carry the test label; outside it, drafts are unrestricted (the
            // oracle's manage_drafts operates on any draft on call).
            func sandboxLabeled(_ s: String, verb: String) throws {
                // EMPTY-SUBJECT guard first, in BOTH modes. The v1 prefix gate rejected "" as a
                // side effect; the v2 split lost that, and unsandboxed `--subject ""` would have
                // matched every UNTITLED draft (the script's subject read defaults to "" when it
                // throws) — `draft send --subject "$UNSET_VAR"` sending a half-written compose,
                // or `draft delete` sweeping every untitled draft (review-caught).
                guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject (or --draft-subject) must not be empty or whitespace for draft \(verb).")
                }
                if sandboxActive, !s.hasPrefix(TestMode.sandboxPrefix) {
                    throw AppleError.mailSafety("sandbox active: draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") to \(verb) — refusing.", sandbox: true)
                }
            }
            // PREVIEW HONESTY: subject presence/emptiness and the sandbox label restriction are
            // computable without Mail, so they fire on BOTH paths — a dry-run must never preview
            // clean for input --execute refuses (review-caught: the guards used to sit inside
            // `if willExecute`, so `draft delete --dry-run --subject "Quarterly report"` under
            // the sandbox previewed ok:true while execute refused 77).
            guard let s = subj else {
                throw AppleError.validation("--subject (or --draft-subject) is required for draft \(action).")
            }
            try sandboxLabeled(s, verb: action)
            // A blank --account reaches the send/open/delete scripts' account filter as "" =
            // EVERY account — refuse the silent widening; omitting the flag is the documented
            // all-accounts spelling (review-caught).
            if let account, account.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("--account must not be empty or whitespace (omit it to search every account).")
            }
            // Bound BEFORE the mutation switch: splitRecipients throws on a control character,
            // and firing that after `draft send` dispatched would report "refusing" for mail
            // that already left (review-caught). Every action validates its recipients up front.
            let requestedTo = try splitRecipients(to)
            if willExecute {
                switch action {
                case "create":
                    // Resolve --account to the draft's sender identity (manage_drafts create
                    // parity); live path only, strict not_found on an unknown account.
                    var senderAddress: String?
                    if let account {
                        guard let addr = AccountDirectory().sendAddress(for: account) else {
                            throw AppleError.notFound("account '\(account)' not found or has no send address.")
                        }
                        senderAddress = addr
                    }
                    try script.createDraft(subject: s, body: body ?? "", to: requestedTo,
                                           cc: try splitRecipients(cc), bcc: try splitRecipients(bcc), sender: senderAddress)
                    executed = true
                case "delete":
                    // Sandboxed deletes stay prefix-scoped inside the script too (defense in
                    // depth); unsandboxed passes the empty prefix = any draft (oracle parity).
                    // --account scopes which account's Drafts are swept (review-caught: the
                    // script used to ignore it and delete matches across EVERY account).
                    let n = try script.deleteDrafts(subject: s, prefix: sandboxActive ? TestMode.sandboxPrefix : "",
                                                    account: account)
                    executed = n > 0
                    note = "deleted \(n) draft(s) matching \"\(s)\""
                case "send":
                    // Deliver an EXISTING Drafts item (manage_drafts action=send). A draft's
                    // recipients are PRE-SET. Inside the sandbox, the label check fires here AND
                    // the draft's own stored to/cc/bcc are verified against the self-only
                    // allowlist INSIDE the single AppleScript call (find→verify→send, no TOCTOU).
                    // Unsandboxed, the wildcard allowlist skips recipient restriction (oracle
                    // parity: manage_drafts sends the draft as addressed, on call).
                    //
                    // D8 (SAFETY WINS): a draft-send delivers real mail, so it is throttled like a
                    // normal send — consume the `sends` budget here (mirrors `mail send`/`forward`)
                    // and pass oracle A's 100-recipient cap into the script (enforced BEFORE the
                    // open/send). Consuming before dispatch matches `forward`, where an in-script
                    // refusal after `consume` also spends a slot — deliberately stricter, and rare.
                    let rl = SendRateLimiter.consume()
                    guard rl.allowed else { throw AppleError.validation(SendRateLimiter.refusal(rl)) }
                    if rl.degraded {
                        FileHandle.standardError.write(Data(
                            ("warning: send rate-limit state is unwritable — the oracle's 3-sends/60s cap "
                             + "is NOT being enforced for this call (failing open).\n").utf8))
                    }
                    switch try script.sendDraft(subject: s, prefix: sandboxActive ? TestMode.sandboxPrefix : "",
                                                account: account, allowlist: outboundAllowlist(sandboxActive: sandboxActive),
                                                recipientCap: outboundRecipientCap) {
                    case .sent(let recipients):
                        executed = true
                        draftSentTo = recipients
                        let who = recipients.isEmpty ? "its stored recipients" : recipients.joined(separator: ", ")
                        // The self-only claim is only true when the sandbox's allowlist actually
                        // ran; unsandboxed, the draft goes out exactly as addressed.
                        note = sandboxActive
                            ? "sent existing draft \"\(s)\" to \(who) (recipients verified self-only)"
                            : "sent existing draft \"\(s)\" to \(who) (as addressed — no sandbox recipient restriction)"
                    case .notFound:
                        let inAcct = account.map { " in account '\($0)'" } ?? ""
                        let labeled = sandboxActive ? "labeled " : ""
                        throw AppleError.notFound("no \(labeled)draft with the exact subject \"\(s)\"\(inAcct) found.")
                    case .noRecipients:
                        throw AppleError.validation("draft \"\(s)\" has no valid recipients; add a recipient in Mail or recreate it.")
                    case .tooManyRecipients(let n):
                        // D8: oracle A's send cap, applied to the draft-send. Matches the CLI's own
                        // `guardOutbound` phrasing (oracle A's "Too many recipients (max: 100)" +
                        // the "— N given" addendum). Nothing was opened or sent.
                        throw AppleError.validation("Too many recipients (max: \(outboundRecipientCap)) — \(n) given.")
                    case .blocked(let addr):
                        // Under an active sandbox a `.blocked` carries a REAL non-self address
                        // (the self-only allowlist ran) — a sandbox-policy refusal that MUST
                        // stamp error.sandbox; unsandboxed the only reachable block is
                        // <empty-address>. The construction is factored into a pure helper so
                        // that sandbox-causation is revert-red-pinnable without live Mail.
                        throw blockedDraftSendError(address: addr, subject: s, sandboxActive: sandboxActive)
                    case .wrongWindow:
                        throw AppleError.mailSafety("the outgoing message Mail surfaced for subject \"\(s)\" does not carry the draft's own stored recipients — most likely an OPEN compose window sharing that subject. Nothing was sent. Close the compose window (or send it manually) and retry.")
                    case .openFailed:
                        throw AppleError.upstream("draft \"\(s)\" was opened but Mail never surfaced its outgoing message within 30s; nothing was sent (a compose window may be open — close it or send manually), and the draft is unchanged — retry.")
                    case .sendError(let detail):
                        throw AppleError.upstream("draft \"\(s)\" opened and passed recipient verification, but Mail failed to dispatch it (error \(detail)); a compose window may be open — send it manually, or retry.")
                    }
                default: // open — open an EXISTING draft in a compose window (no send).
                    let ok = try script.openDraft(subject: s, account: account)
                    executed = ok
                    note = ok ? "opened draft \"\(s)\" in a compose window (not sent)" : "no draft matching \"\(s)\" found"
                }
            }
            let payload: [String: AnyEncodableBox] = [
                "action": AnyEncodableBox(action), "account": AnyEncodableBox(account),
                "subject": AnyEncodableBox(subj), "to": AnyEncodableBox(draftSentTo ?? requestedTo),
                "dry_run": AnyEncodableBox(!willExecute), "executed": AnyEncodableBox(executed),
                "note": AnyEncodableBox(note),
            ]
            try Output.emit(tool: "mail", data: payload, text: global.text, sandboxActive: sandboxActive)
        }
    }
}
