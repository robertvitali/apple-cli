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
        throw AppleError.mailSafety("sandbox active: recipient '\(r)' is not in the self-only allowlist (APPLE_TEST_RECIPIENTS) — refusing. Disengage the sandbox to send beyond it.")
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
    if bad == "<empty-address>" {
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
    if let dir = sensitiveAttachmentDir(path, home: home) ?? sensitiveAttachmentDir(expanded, home: home) {
        throw AppleError.mailSafety("cannot attach a file from a sensitive directory (\(dir)) — refusing.")
    }
    return path
}

/// The sensitive credential/config directory a resolved path falls under, or nil (mirrors
/// patrickfreyer `sensitive_dirs`). Pure — unit-testable with synthetic paths, no real files.
/// CASE-INSENSITIVE by design. The default macOS volume is case-insensitive APFS, and
/// `resolvingSymlinksInPath()` only canonicalizes the case of components that ALREADY EXIST — so a
/// case-sensitive comparison fails OPEN for a file that does not exist yet, which is exactly the
/// "plant a new ~/.ssh/authorized_keys" case. Verified: `--out ~/.SSH/authorized_keys` was accepted
/// while the identical lowercase path was refused. Over-blocking a genuinely distinct `.SSH`
/// directory on a case-SENSITIVE volume is the fail-closed direction and is the correct trade.
func sensitiveAttachmentDir(_ resolvedPath: String, home: String) -> String? {
    let dirs = [".ssh", ".gnupg", ".config", ".aws", ".claude",
                "Library/Keychains", "Library/LaunchAgents", "Library/LaunchDaemons"]
        .map { home + "/" + $0 }
    let lowered = resolvedPath.lowercased()
    return dirs.first(where: {
        let d = $0.lowercased()
        return lowered == d || lowered.hasPrefix(d + "/")
    })
}

/// THE shared write-destination guard: every command that writes bytes to an operator-supplied
/// path resolves it through here first.
///
/// Both oracles refuse two path classes before touching Mail (patrickfreyer manage.py:197-220 for
/// `save_email_attachment`, analytics.py:428-443 for `export_emails`): a destination outside
/// `$HOME`, and anything at or under a credential/config directory. `attachments save` had
/// NEITHER check and documented its path as "TRUSTED" — so `--out ~/.ssh/authorized_keys
/// --execute` would have overwritten an SSH key with attachment bytes. That is a divergence in
/// the less-safe direction, which strict-superset does not license.
///
/// Symlinks are resolved BEFORE comparing (the oracles use `realpath`), and the blocklist is
/// tested against the resolved path AND the pre-resolution literal so a sensitive directory that
/// is itself a symlink cannot slip past. `$HOME` itself is allowed, matching manage.py:201.
///
/// - Parameter action: verb for the refusal message, e.g. "save attachments into".
/// - Parameter allowOutsideHome: opt out of the `$HOME` rule ONLY. The credential blocklist and
///   the control-character rejection are absolute and cannot be disabled. Oracle A's
///   `save_attachments` has no confinement at all (server.py), so `/tmp` and `/Volumes/*` are
///   legitimate destinations there; confining unconditionally would DROP that capability. Default
///   safe, explicit opt-out restores oracle-A parity.
/// - Throws: `AppleError.mailSafety` (exit 77) — a refused write is a safety violation, not a
///   usage error, and callers must apply this on the DRY-RUN path too so a preview never promises
///   a write that `--execute` would refuse.
func confineWriteDestination(_ raw: String, action: String, allowOutsideHome: Bool = false) throws -> URL {
    // CONTROL CHARACTERS FIRST, and unconditionally. The confined path is later serialized into an
    // ASCII-delimited blob for AppleScript using RS (0x1E) between records and US (0x1F) between
    // fields. A path containing those bytes passes every path check as one string and is then
    // re-parsed downstream as TWO records — the second targeting a destination that never passed
    // confinement, anywhere on disk. Verified as a live bypass before this guard existed.
    // Rejecting the whole C0 range + DEL also covers NUL and newline injection.
    if let bad = raw.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) {
        throw AppleError.mailSafety(
            "cannot \(action) a path containing a control character (U+\(String(format: "%04X", bad.value))) — refusing.")
    }
    let expanded = (raw as NSString).expandingTildeInPath
    let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    let path = resolved.path
    if !allowOutsideHome {
        // Case-insensitive for the same reason the blocklist is — see sensitiveAttachmentDir.
        let l = path.lowercased(), h = home.lowercased()
        guard l == h || l.hasPrefix(h + "/") else {
            throw AppleError.mailSafety("cannot \(action) a path outside your home directory (\(home)); got: \(path)")
        }
    }
    // ABSOLUTE — never opt-out-able. Checked against the resolved path AND the pre-resolution
    // literal, so a sensitive dir that is itself a symlink is caught too.
    if let dir = sensitiveAttachmentDir(path, home: home) ?? sensitiveAttachmentDir(expanded, home: home) {
        throw AppleError.mailSafety("cannot \(action) a sensitive directory (\(dir)) — refusing.")
    }
    return resolved
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
    // Reaped on every materialising call rather than once per process. A `once` flag would be a
    // mutable global read from concurrent callers — a real data race for no gain, since this is one
    // listing of a directory only this tool writes to.
    OwnedTempDir.reapFiles(in: dir, prefix: "apple-cli-", olderThan: 24 * 60 * 60)
    return dir
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
                    throw AppleError.mailSafety("sandbox active: draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") — refusing.")
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
            try Output.emit(tool: "mail", data: preview, sandboxActive: sandboxActive)
        }
    }
}

struct ReplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reply to a message by id or --subject (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to reply to (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Reply to the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long) var body: String
    @Flag(name: .long, help: "Reply to all recipients.") var all = false
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "HTML reply body. Default opens a rendered compose window for review; add --gui-send to auto-send.") var html: String?
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Flag(name: .long, help: "Auto-send an --html reply via GUI keystroke automation (needs Accessibility, steals focus, fragile). Opt-in.") var guiSend = false

    struct Preview: Encodable {
        let action: String; let target: String; let matched_message_id: String?
        let reply_all: Bool; let mode: String; let has_html: Bool; let sender_address: String?
        let to: [String]; let cc: [String]; let bcc: [String]; let attachments: [String]
        let dry_run: Bool; let executed: Bool; let opened: Bool; let note: String?
        /// Id of the newly-created reply (oracle A `reply_to_message` → `reply_id`). Present only
        /// on the native-reply path; nil on dry-run and on the HTML open/gui-send paths.
        var reply_id: String? = nil
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
            // `--mode draft` / `--mode open` are oracle B `reply_to_email(mode=…, send=False)`
            // capabilities that are NOT implemented for reply yet (tracked as a parity gap).
            // Refuse explicitly IN BOTH MODES rather than emitting a success-shaped envelope
            // that did nothing — a preview of an unimplemented mode is as misleading as an
            // execute of one.
            guard mode == "send" else {
                throw AppleError.notImplemented("`reply --mode \(mode)` is not implemented yet (oracle B reply_to_email mode=\(mode)); use --mode send, or pass --dry-run to preview.")
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
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = 1
                guard let r = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)'.") }
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

            // (mode + --gui-send validity were hoisted above the store open — see the
            // preview-honesty block at the top of run(). Past this point mode == "send".)
            // Three mutually-exclusive live outbound actions (mirrors SendCommand / Option A).
            // NOTE the `mode == "send"` clause on willOpenHtml: without it (as before), a
            // `reply --mode draft --html …` took the HTML-open path and OPENED a compose window
            // for a caller who asked for a draft. SendCommand's twin already had the clause.
            let willAutoSend = willExecute && mode == "send" && html == nil
            let willGuiSend = willExecute && guiSend
            let willOpenHtml = willExecute && mode == "send" && html != nil && !guiSend
            let willLiveOutbound = willAutoSend || willGuiSend || willOpenHtml

            // Outbound gate in BOTH modes (preview honesty): the recipient set is already
            // resolved above on the dry-run path too, so a sandboxed preview refuses a
            // non-allowlisted reply exactly as --execute would. Fires before any attachment
            // read, .eml/.html build, or send.
            try guardOutbound(recipients: recipients + ccL + bccL, sandboxActive: sandboxActive,
                                  applyRecipientCap: false)   // oracle reply_to_message: no cap
            var executed = false
            var opened = false
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
                // Quoted original, escaped into the HTML part (shared by the gui-send + open paths).
                let quotedHTML = original.map {
                    "<br><br><blockquote>" + EmlBuilder.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>"
                } ?? ""
                if willGuiSend {
                    // Opt-in HTML auto-send via GUI keystrokes (fragile — see MailScript.sendHtmlViaGui).
                    let htmlTmp = try emlTempDirectory(materialise: true)
                        .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                    try ((html ?? "") + quotedHTML).write(to: htmlTmp, atomically: true, encoding: .utf8)
                    OwnedTempDir.restrictToOwner(htmlTmp)
                    defer { try? FileManager.default.removeItem(at: htmlTmp) }
                    try MailScript().sendHtmlViaGui(htmlPath: htmlTmp.path, subject: replySubject,
                        to: recipients, cc: ccL, bcc: bccL, attachmentPaths: attachPaths, sender: senderAddress)
                    executed = true
                    note = "sent via GUI keystroke automation (--gui-send); required Accessibility and stole focus"
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
                } else { // willAutoSend — plain reply via Mail's NATIVE `reply` verb
                    // Parity: a re-composed "Re:" message is NOT a reply — only Mail's `reply`
                    // verb sets In-Reply-To/References and the original's replied-to state, and
                    // returns the new message's id (oracle A `reply_id`). See MailScript's
                    // "Native reply / forward" note for the safety readback.
                    guard let imid = target.internet_message_id, !imid.isEmpty else {
                        throw AppleError.upstream("message '\(target.id)' has no RFC Message-ID; cannot reply to it via Mail.app.")
                    }
                    switch try MailScript().nativeReply(internetMessageID: imid,
                                                        accountName: target.account.isEmpty ? nil : target.account,
                                                        body: body, replyAll: all, sender: senderAddress,
                                                        selfAllowlist: outboundAllowlist(sandboxActive: sandboxActive),
                                                        cc: ccL, bcc: bccL, attachmentPaths: attachPaths,
                                                        // Hand the locator the mailbox the Envelope
                                                        // Index already resolved, so an ARCHIVED
                                                        // message (incl. [Gmail]/All Mail, which the
                                                        // blind scan skips to avoid hanging) is a
                                                        // targeted lookup rather than unreachable.
                                                        mailboxHint: target.mailbox) {
                    case .sent(let newID, let actual):
                        executed = true
                        replyID = newID
                        // Report what MAIL actually addressed, not our pre-send prediction — on
                        // this one command the CLI does not choose the recipients.
                        if !actual.isEmpty { recipients = actual }
                        note = "replied via Mail's native reply verb — threading headers and the original's replied-to state are preserved"
                    case .notFound:
                        throw AppleError.notFound("message '\(imid)' is not reachable in Mail.app to reply to.")
                    case .sendFailed(let newID):
                        throw AppleError.upstream("Mail reported the reply was NOT sent (send returned false — account offline or the server refused). Draft id \(newID) may still be in Mail.")
                    case .refused(let bad, let discarded):
                        throw AppleError.mailSafety(refusalMessage(kind: "reply", bad: bad, discarded: discarded, sandboxActive: sandboxActive))
                    }
                }
            }
            // (No preview-only else-branch: mode is always "send" past the hoisted guard, so
            // willLiveOutbound == willExecute — an unreachable note would just be dead code.)

            try Output.emit(tool: "mail", data: Preview(action: "reply", target: id ?? "subject:\(subject ?? "")",
                matched_message_id: target.id, reply_all: all, mode: mode, has_html: html != nil, sender_address: senderAddress,
                to: recipients, cc: ccL, bcc: bccL, attachments: attach,
                dry_run: !willExecute, executed: executed, opened: opened, note: note,
                reply_id: replyID, original_message_id: target.id), sandboxActive: sandboxActive)
        }
    }
}

struct ForwardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forward", abstract: "Forward a message by id or --subject (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to forward; or use --subject.") var id: String?
    @Option(name: .long, help: "Forward the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long, help: "Mailbox to scope the --subject lookup (default All; MCP B forward_email mailbox).") var mailbox: String = "All"
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
                f.mailboxName = mailbox; f.subjectContains = subject; f.limit = 1
                guard let row = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)' in mailbox '\(mailbox)'.") }
                target = ctx.decodeSummary(row)
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            // Forward composes a NEW message to the self-only --to (guardOutbound above), carrying
            // the original body — so forwarding real mail to yourself is fine (recipient is self).
            var executed = false
            var note: String?
            var forwardID: String?
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
                switch try MailScript().nativeForward(internetMessageID: imid,
                                                      accountName: target.account.isEmpty ? nil : target.account,
                                                      body: body ?? "", to: toL, cc: ccL, bcc: bccL,
                                                      sender: senderAddress,
                                                      selfAllowlist: outboundAllowlist(sandboxActive: sandboxActive),
                                                      mailboxHint: target.mailbox) {
                case .sent(let newID, _):
                    executed = true
                    forwardID = newID
                    note = "forwarded via Mail's native forward verb — the original's attachments and formatting are carried"
                case .notFound:
                    throw AppleError.notFound("message '\(imid)' is not reachable in Mail.app to forward.")
                case .sendFailed(let newID):
                    throw AppleError.upstream("Mail reported the forward was NOT sent (send returned false — account offline or the server refused). Draft id \(newID) may still be in Mail.")
                case .refused(let bad, let discarded):
                    throw AppleError.mailSafety(refusalMessage(kind: "forward", bad: bad, discarded: discarded, sandboxActive: sandboxActive))
                }
            }
            try Output.emit(tool: "mail", data: Preview(action: "forward", matched_message_id: target.id, sender_address: senderAddress,
                to: toL, cc: ccL, bcc: bccL, dry_run: !willExecute, executed: executed, note: note,
                forward_id: forwardID, original_message_id: target.id), sandboxActive: sandboxActive)
        }
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

    struct Result: Encodable { let eml_path: String; let subject: String; let to: [String]; let has_html: Bool; let sender_address: String?; let opened: Bool; let note: String?; let dry_run: Bool }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see SendCommand). DraftRich previously wrote the .eml
            // UNCONDITIONALLY (no willExecute branch — the bucket-2 defect the spec names);
            // it now honors the bound decision like every other write.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let toL = try splitRecipients(to)
            // Opening the .eml in Mail (either flag) is a live compose-window action, so gate it
            // consistently with `send --mode open`: guardOutbound (self-only allowlist when the
            // sandbox is active; write-model v2 matches the create_rich_email_draft oracle, which
            // opens to any recipient) + a real subject, BEFORE any Mail access or .eml write. The
            // guard runs on the dry-run path too — a preview must refuse exactly what execute
            // would. The DEFAULT (neither flag) just writes the .eml headlessly and is ungated.
            var senderAddress: String?
            if openInMail || saveAsDraft {
                try guardOutbound(recipients: toL + (try splitRecipients(cc)) + (try splitRecipients(bcc)),
                                  sandboxActive: sandboxActive,
                                  applyRecipientCap: false)   // oracle-B-only surface: no cap
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required to open a draft-rich compose window.")
                }
                // Resolve --account to a real From ADDRESS on the live-open path (mirrors
                // create_rich_email_draft's _resolve_sender_address): a raw account NAME in `From:`
                // is malformed and Mail ignores it. Headless default keeps the raw fallback so it
                // never touches Mail (and never launches it).
                if let account {
                    guard let addr = AccountDirectory().sendAddress(for: account) else {
                        throw AppleError.notFound("account '\(account)' not found or has no send address.")
                    }
                    senderAddress = addr
                }
            }
            // emitBcc: a draft-rich .eml is only opened / written to disk, never wire-sent, so
            // carrying --bcc into it is safe and required for create_rich_email_draft parity.
            let eml = try EmlBuilder(from: senderAddress ?? account, to: toL, cc: try splitRecipients(cc), bcc: try splitRecipients(bcc),
                                 subject: subject, textBody: textBody, htmlBody: html, emitBcc: true).build()
            let dest = try emlDestURL(out: out, materialise: willExecute,
                                      action: "write the rich draft .eml to")
            if willExecute {
                try eml.write(to: dest, atomically: true, encoding: .utf8)
                if out == nil { OwnedTempDir.restrictToOwner(dest) }
            }
            // Optional review window (parity with create_rich_email_draft open_in_mail). Mail cannot
            // auto-save an HTML draft (a LaunchServices-opened .eml window doesn't surface in
            // `outgoing messages`), so --save-as-draft opens the SAME review window and instructs the
            // operator to Cmd-S — it never auto-files, so there is no `saved` claim.
            var opened = false
            var note: String?
            if willExecute && (openInMail || saveAsDraft) {
                try MailScript().openEml(path: dest.path)
                opened = true
                note = saveAsDraft
                    ? "compose window opened — press Cmd-S to file it in Drafts (Mail can't auto-save an HTML draft)."
                    : "compose window opened for review (not sent)."
            } else if !willExecute {
                note = "dry-run: nothing written or opened; eml_path is the planned destination."
            }
            try Output.emit(tool: "mail", data: Result(eml_path: dest.path, subject: subject, to: toL,
                has_html: html != nil, sender_address: senderAddress, opened: opened, note: note,
                dry_run: !willExecute), sandboxActive: sandboxActive)
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
                try Output.emit(tool: "mail", data: DraftsResult(action: "list", drafts: rows, count: rows.count))
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
                    throw AppleError.mailSafety("sandbox active: draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") to \(verb) — refusing.")
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
                    switch try script.sendDraft(subject: s, prefix: sandboxActive ? TestMode.sandboxPrefix : "",
                                                account: account, allowlist: outboundAllowlist(sandboxActive: sandboxActive)) {
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
                    case .blocked(let addr):
                        let which = addr == "<empty-address>" ? "an empty/blank recipient address" : "'\(addr)'"
                        // Unsandboxed, the only reachable block is <empty-address> (the allowlist
                        // comparison is skipped) — allowlist advice would be misleading there.
                        let advice = sandboxActive
                            ? "Set APPLE_TEST_RECIPIENTS to your own address(es) or fix the draft's recipients."
                            : "Fix the draft's recipients in Mail."
                        let why = sandboxActive ? ", which is not in the self-only test allowlist" : ""
                        throw AppleError.mailSafety("draft \"\(s)\" is addressed to \(which)\(why) — refusing to send it. \(advice)")
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
            try Output.emit(tool: "mail", data: payload, sandboxActive: sandboxActive)
        }
    }
}
