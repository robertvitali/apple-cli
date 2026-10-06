import Foundation
import AppleKit

// Shared output + write-safety plumbing for every contacts subcommand.

/// Emit a payload as the JSON envelope (default) or a human rendering (`--text`).
/// JSON is the versioned contract; `--text` is a non-contractual convenience.
///
/// Both paths delegate to the shared `Output` renderer so contacts `--text` gets the
/// terminal-neutralization ([17]) and the numeric-vs-boolean rendering fix for free, and
/// there is exactly ONE `key: value` formatter on the fleet rather than a per-domain copy
/// that can drift (review LOW: the previous local `humanRender`/`compact` duplicated
/// `Output.humanText`/`humanValue` and carried its own copy of the NSNumber→Bool bug).
func emitContacts<T: Encodable>(_ global: GlobalOptions, _ data: T) throws {
    try Output.emit(tool: "contacts", data: data, text: !global.json)
}

/// Write-path emit. `sandboxActive` is REQUIRED — no default — so a write can never
/// silently under-report the sandbox in its envelope. (`Output.emit` defaults the
/// parameter for the read path's benefit, which would let an omission here compile;
/// docs/write-model-v2.md flags exactly that as the flip-commit residual risk.) The
/// text-aware overload surfaces `sandbox: true` on the `--text` branch too — a human
/// reading text output has the same need to know the write was confined as a machine.
func emitContactsWrite<T: Encodable>(_ global: GlobalOptions, _ data: T, sandboxActive: Bool) throws {
    try Output.emit(tool: "contacts", data: data, text: !global.json, sandboxActive: sandboxActive)
}

// MARK: - Pure list helpers (unit-testable without a store)

/// Clamp a requested page size to the hard cap (mirrors `min(limit, MAX)` in the oracle).
func effectiveLimit(_ requested: Int, cap: Int) -> Int { min(requested, cap) }

/// Union several summary lists preserving first-seen order, de-duped by `id`, capped.
/// Backs `search --deep` (the all-field fold-in extra).
func unionSummariesByID(_ lists: [[ContactSummary]], cap: Int) -> [ContactSummary] {
    var seen = Set<String>()
    var out: [ContactSummary] = []
    for list in lists {
        for c in list {
            if out.count >= cap { return out }
            if seen.insert(c.id).inserted { out.append(c) }
        }
    }
    return out
}

// MARK: - Input-size bounds (DoS guard for --file / --base64 / --json)

/// 25 MB ceiling — generous for notes / vCards / contact photos, small enough to stop a
/// pathological file or string from blowing up memory before we ever touch the store.
let maxContactsInputBytes = 25 * 1024 * 1024

/// Read a `contacts … --file` input of at most `maxContactsInputBytes`: a regular file outside
/// the credential directories, or a pipe or socket the caller hands over as `/dev/stdin` or
/// `/dev/fd/N`. The credential-directory list and the control-character rule are those of the
/// attachment sources (`AttachmentSource.resolve`), because a file read here is copied into a
/// contact, which can sync off the machine.
///
/// 1. A control character (C0 or DEL) anywhere in the spelling → `safety_violation`.
/// 2. Another user's `~user` spelling → `validation_error`, under the shared tilde policy
///    (`TildeSpelling`). `~/…` means the operator's own home, and `expandingTildeInPath` drops a
///    trailing slash and collapses `//`.
/// 3. Exactly `/dev/stdin` or `/dev/fd/N` names a descriptor the caller handed over, which is
///    duplicated (`F_DUPFD_CLOEXEC`) rather than opened by path, so no spelling elsewhere can pass
///    for it; the duplicate keeps the caller's flags, so a pipe read that way blocks as stdin does.
///    Any other spelling is opened in two steps: its directory, then the last component inside
///    that open directory (`openat`), so the directory checked in step 5 is the one the file was
///    found in. `O_NONBLOCK` keeps the open from waiting for a writer on a named pipe, `O_NOCTTY`
///    keeps a terminal from becoming the controlling terminal, and a regular file opened this way
///    drops `O_NONBLOCK` before the read. The file's kind, size and content come from that one
///    descriptor, so a file swapped or relinked after the open cannot change what is read.
/// 4. A regular file is read. A pipe or socket is read only when handed over (a shell pipe hands
///    over a pipe; Node's and Bun's spawn input, a socket): a named pipe opened by path reads as
///    empty when nothing writes to it. Anything else (a named pipe, device, directory, or a socket
///    opened by path) → `validation_error`.
/// 5. A regular file inside a credential directory (`sensitiveDirectories`), whose directory
///    entry is inside one (a link out of it), or whose path passes through one →
///    `safety_violation`, however the path is spelled.
///    The directories are compared by identity (`st_dev`, `st_ino`, following links) with every
///    ancestor of the opened file's path (`F_GETPATH`) and of the directory it was found in, so a
///    directory that is itself a link, such as a dotfiles checkout, is covered too. So is every
///    directory the spelling passes through, made absolute and resolved as the kernel walks it,
///    for a path that enters a credential directory and leaves it again through `..` after a link.
/// 6. A size over the ceiling → `validation_error`. The read stops one byte past the ceiling,
///    so a pipe, or a file that grows after the size check, is refused without being read in full.
///
/// **What this does not stop** (as on `AttachmentSource`): it is a guard against accidents and
/// naive commands, not an exfiltration control. A hard link to a credential file made outside
/// those directories is read under the name it was opened by; so is a copy, the target of a link
/// out of a credential directory named directly or through a further link, and content piped or
/// redirected onto stdin from any of these. The directories are compared by path as they are at that moment, so a
/// credential directory or file moved while the command runs can evade the comparison. The list
/// is `sensitiveWriteDir`'s and is not exhaustive (`~/.netrc`, `~/.git-credentials`, `~/.docker`,
/// anything outside `home`), and `home` is Foundation's home directory, which
/// `CFFIXED_USER_HOME` moves. A handed-over pipe or socket whose writer stays open without writing
/// is waited on, as any reader of stdin would. Opening a device before refusing it can have side
/// effects (a serial port's DTR line), as reading it did before.
///
/// - Parameter home: the home directory the credential directories are measured against. A seam
///   for the logic tier, as on `AttachmentSource.resolve`; production takes the default.
func readBoundedFile(_ raw: String, _ what: String,
                     home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Data {
    if let bad = raw.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) {
        throw AppleError.safetyViolation(
            "cannot read the \(what) file from a path containing a control character "
            + "(U+\(String(format: "%04X", bad.value))) — refusing.")
    }
    guard let path = TildeSpelling.expandedOwnHome(raw) else {
        throw AppleError.validation("cannot read the \(what) file: " + TildeSpelling.refusalMessage(raw))
    }
    let failed = { (code: Int32) in
        AppleError.validation("failed to read \(what) file \(raw): \(String(cString: strerror(code)))")
    }
    let refuseKind = { (kind: String) in
        AppleError.validation(
            "\(what) file is \(kind), not a regular file or a pipe given as /dev/stdin: \(raw); "
            + "save the content to a regular file, or pass small content inline with \(inlineFlag(what))")
    }

    let handedOver = handedOverDescriptor(path)
    var directory: Int32 = -1
    defer { if directory >= 0 { close(directory) } }
    let fd: Int32
    if let caller = handedOver {
        fd = fcntl(caller, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw failed(errno) }
    } else {
        let parent = (path as NSString).deletingLastPathComponent
        // Search access is enough (`O_SEARCH`), as for an ordinary open of a path inside it; a
        // kernel that refuses `O_EXEC` on a directory gets the read-only open instead.
        let parentPath = parent.isEmpty ? "." : parent
        directory = open(parentPath, O_EXEC | O_DIRECTORY | O_CLOEXEC)
        if directory < 0, errno == EINVAL {
            directory = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard directory >= 0 else { throw failed(errno) }
        fd = openat(directory, (path as NSString).lastPathComponent,
                    O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EOPNOTSUPP { throw refuseKind("a socket") }
            throw failed(errno)
        }
    }
    defer { close(fd) }

    var info = stat()
    guard fstat(fd, &info) == 0 else { throw failed(errno) }
    let kind = info.st_mode & S_IFMT
    guard kind == S_IFREG || ((kind == S_IFIFO || kind == S_IFSOCK) && handedOver != nil) else {
        throw refuseKind(handedOver != nil && kind == S_IFCHR ? "a terminal or other character device"
                                                            : fileKind(kind))
    }
    let limitMB = maxContactsInputBytes / (1024 * 1024)
    if kind == S_IFREG {
        // A handed-over descriptor shares the caller's flags; only a file opened here is changed.
        if handedOver == nil {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw failed(errno) }
        }
        var found = [String]()
        for descriptor in [fd, directory] where descriptor >= 0 {
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &name) != -1 else { throw failed(errno) }
            found.append(String(cString: name))
        }
        // The file's own path is walked from its parent; the directory's path from itself.
        let chains = [(found[0] as NSString).deletingLastPathComponent] + found.dropFirst()
        if let dir = credentialDirectory(chains: chains, passed: directoriesPassed(absoluteSpelling(path)),
                                         home: home) {
            throw AppleError.safetyViolation(
                "cannot read the \(what) file from a sensitive directory (\(dir)) — refusing.")
        }
        if info.st_size > off_t(maxContactsInputBytes) {
            throw AppleError.validation("\(what) file exceeds the \(limitMB) MB limit (\(info.st_size) bytes)")
        }
    }
    let data: Data?
    do { data = try readAtMost(fd, limit: maxContactsInputBytes, expected: Int(info.st_size)) }
    catch let error as POSIXError { throw failed(error.code.rawValue) }
    guard let data else {
        throw AppleError.validation(
            "\(what) file exceeds the \(limitMB) MB limit (more than \(maxContactsInputBytes) bytes were read)")
    }
    return data
}

/// The descriptor a spelling hands over: 0 for exactly `/dev/stdin`, `N` for exactly `/dev/fd/N`
/// with a decimal `N`, nil for anything else.
private func handedOverDescriptor(_ path: String) -> Int32? {
    if path == "/dev/stdin" { return 0 }
    guard path.hasPrefix("/dev/fd/") else { return nil }
    let number = path.dropFirst("/dev/fd/".count)
    guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int32(number)
}

/// `path` made absolute against `directory` (the working directory), with nothing else changed:
/// its `..` components stay, so every directory the spelling passes through can be checked.
func absoluteSpelling(_ path: String,
                      in directory: String = FileManager.default.currentDirectoryPath) -> String {
    path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
}

/// The credential directory under `home` that holds the file, or nil. Each of `chains` is a
/// directory whose path and every ancestor are compared with the credential directories by
/// identity; each of `passed` is a directory the caller's spelling passes through, compared
/// itself.
private func credentialDirectory(chains: [String], passed: [String], home: String) -> String? {
    var folders: [(device: dev_t, inode: ino_t, path: String)] = []
    for dir in sensitiveDirectories(home: home) {
        var folder = stat()
        if stat(dir, &folder) == 0 { folders.append((folder.st_dev, folder.st_ino, dir)) }
    }
    guard !folders.isEmpty else { return nil }
    func match(_ candidate: String) -> String? {
        var node = stat()
        guard stat(candidate, &node) == 0 else { return nil }
        return folders.first(where: { $0.device == node.st_dev && $0.inode == node.st_ino })?.path
    }
    for start in chains {
        var ancestor = start
        while !ancestor.isEmpty {
            if let hit = match(ancestor) { return hit }
            if ancestor == "/" { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
    return passed.lazy.compactMap(match).first
}

/// The directories an absolute spelling passes through on the way to its last component, each
/// spelled as given (`/a/../b/c` gives `/a`, `/a/..`, `/a/../b`), so `stat` resolves each as the
/// kernel walks it.
private func directoriesPassed(_ path: String) -> [String] {
    var prefix = ""
    return path.split(separator: "/").dropLast().map { component in
        prefix += "/" + component
        return prefix
    }
}

/// Read `fd` to its end, but never more than `limit + 1` bytes: nil means the input was longer
/// than `limit`, and the descriptor is left just past that extra byte. `expected` only sizes the
/// buffer. A non-blocking descriptor with nothing to read yet is waited on with `poll`; any other
/// read error but `EINTR` throws its `POSIXError`.
func readAtMost(_ fd: Int32, limit: Int, expected: Int = 0) throws -> Data? {
    var data = Data()
    data.reserveCapacity(min(max(expected, 0), limit))
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let want = min(chunk.count, limit + 1 - data.count)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
        if count < 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&ready, 1, 1000)
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        if count == 0 { return data }
        data.append(contentsOf: chunk[..<count])
        if data.count > limit { return nil }
    }
}

/// How a refused `--file` input is named in the error.
private func fileKind(_ kind: mode_t) -> String {
    switch kind {
    case S_IFIFO: return "a named pipe"
    case S_IFDIR: return "a directory"
    case S_IFCHR: return "a character device"
    case S_IFBLK: return "a block device"
    case S_IFSOCK: return "a socket"
    default: return "a special file"
    }
}

/// The inline flag that takes the same content as `--file` for each reader.
private func inlineFlag(_ what: String) -> String {
    switch what {
    case "note": return "--note"
    case "image": return "--base64 (the bytes base64-encoded)"
    case "vcard": return "--vcard"
    default: return "an inline flag"
    }
}

/// Reject an oversized inline string input (`--base64` / `--json`) before parsing it.
func checkBoundedInput(_ s: String, _ what: String) throws {
    if s.utf8.count > maxContactsInputBytes {
        throw AppleError.validation("\(what) exceeds the \(maxContactsInputBytes / (1024 * 1024)) MB limit")
    }
}

// MARK: - Write-safety gate (write-model v2)

/// The resolved write posture for one contacts command: whether it mutates, and whether the
/// opt-in sandbox is engaged. Bound ONCE at the top of every write `run()` and threaded from
/// there — never re-derived mid-command (docs/write-model-v2.md, "Core implementation").
struct WriteGate {
    let willExecute: Bool
    let sandboxActive: Bool
}

/// Resolve a contacts write under write-model v2: **it executes by default**, exactly as
/// calling the equivalent Contacts oracle tool does. `--dry-run` previews; `APPLE_DRY_RUN`
/// truthy restores dry-run-by-default (precedence: `--dry-run` > `--execute` > `APPLE_DRY_RUN`
/// > execute).
///
/// `APPLE_TEST_MODE` truthy or `--test-mode` engages the opt-in SANDBOX. Its restrictions are
/// the CLI's analogue of the oracle's own test-mode restrictions — note that oracle's
/// `check_test_mode_safety` (security.py:56) returns `None`, i.e. ALLOWS, when test mode is
/// off, and confines destructive ops to `CONTACTS_TEST_GROUP` when it is on; this CLI confines
/// them to `apple-cli-test`-labeled items instead. Same shape, different label mechanism.
///
/// `labeledName` (create / groups create) is checked on BOTH paths, so a sandboxed preview
/// cannot report clean for a name the execute path would refuse.
/// `prefix` is a seam for the logic tier, for the same reason the `envVar:` seams exist:
/// `TestMode.sandboxPrefix` reads `APPLE_TEST_SANDBOX` from the PROCESS environment, and
/// swift-testing runs all suites in one process — `MailKitTests` setenv()s that variable to
/// "qa-fixture" while these tests run. A test asserting a hard-coded "apple-cli-test…" name must
/// therefore pin the prefix rather than inherit whatever another suite last wrote. Production
/// callers never pass it.
func resolveWrite(_ global: GlobalOptions, labeledName: String? = nil,
                  prefix: String? = nil) throws -> WriteGate {
    try TestMode.validateWriteEnvironment()
    let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
    let willExecute = try global.willExecute(defaultDryRun: false)
    if sandboxActive, let name = labeledName {
        let required = prefix ?? TestMode.sandboxPrefix
        guard name.hasPrefix(required) else {
            throw AppleError.safetyViolation(
                "refusing to create unlabeled data in the sandbox: the name must start with "
                + "'\(required)'.", sandbox: true)
        }
    }
    return WriteGate(willExecute: willExecute, sandboxActive: sandboxActive)
}

// MARK: - Oracle-mirrored hard gate on the two deletes

/// Whether the operator has granted the oracle-mirrored delete gate.
///
/// ORACLE-MIRRORED (bucket 1 — kept UNCONDITIONALLY under write-model v2, sandbox or not).
/// The Contacts oracle refuses `delete_contact` (server.py:965) and `delete_group`
/// (server.py:1715) outside `CONTACTS_TEST_MODE=true` via `require_test_mode_for`
/// (security.py:161-179): the destructive path has no confirmation UX, so it is "only safe to
/// expose in test mode". That gate is part of the behavior being replicated, not a CLI-only
/// restriction to lift.
///
/// It reads the ENVIRONMENT signal ONLY — never the threaded `sandboxActive`, and never
/// `--test-mode`. The reason is PARITY, not security: the oracle's gate is keyed to an
/// environment variable, so the mirror is too, and a CLI that accepted the flag instead would
/// answer a different question than the tool it replaces.
///
/// Do NOT restate this as "an agent can self-grant a flag but not an environment variable" —
/// that is false. Anything that can pass argv can equally set the environment of the process
/// it spawns, so env-vs-flag is not a trust boundary here. (The `APPLE_ALLOW_*` variables on
/// Mail's irreversible ops carry the same caveat; their value is that they are absent by
/// default and must be added deliberately, not that they are unreachable.)
/// `envVar` is a seam for the logic tier, matching the ones `TestMode.sandboxActive(flag:envVar:)`
/// and `GlobalOptions.willExecute(defaultDryRun:envVar:)` already carry, and it exists for the same
/// reason: a test that needs the env-GRANTED branch must own a UNIQUE variable rather than
/// `setenv`-ing the real `APPLE_TEST_MODE`, which swift-testing's parallel suites read
/// concurrently. Production callers never pass it — the default IS the oracle-mirrored key.
func contactsDeleteEnvGranted(_ envVar: String = TestMode.testModeVar) -> Bool {
    TestMode.isTruthyEnv(envVar)
}

/// The refusal text for an ungranted delete — shared by the execute path (thrown) and the
/// preview (reported in `gate_note`), so a preview can never claim clean for a call the
/// execute path refuses.
func contactsDeleteGateMessage(_ command: String) -> String {
    "\(command) is only available with \(TestMode.testModeVar)=1 in the environment — "
    + "this command's destructive path has no confirmation UX. A --test-mode FLAG "
    + "deliberately does NOT satisfy it: this gate is keyed to the environment only."
}

/// WHY THE DELETES LABEL-CHECK `sandboxPrefix` AND NOT `canonicalSandboxPrefix`.
///
/// Three independent reviewers have now proposed pinning the two deletes to
/// `TestMode.canonicalSandboxPrefix` (the constant that ignores `APPLE_TEST_SANDBOX`), by
/// analogy with Mail's `requireCanonicalLabels` on `delete --permanent`. The analogy does not
/// hold, and the change would be a net loss. Recorded here so the fourth reviewer finds the
/// answer in place:
///
///  1. It would buy ZERO confinement. A contact's name is writable by an UNGATED op — under v2
///     `contacts update <id> --set given_name=apple-cli-test-x` executes with no gate at all,
///     after which the delete passes a canonical check anyway. Mail's constant works because a
///     received message's SUBJECT is not settable by any CLI op; it keys on something the
///     caller genuinely cannot move. A contact's name is CLI-writable by design — it IS the
///     oracle's `update_contact`.
///  2. It would DROP a capability the oracle has. In test mode the oracle deletes any contact
///     by id; canonical-only would make an unlabeled contact undeletable through the CLI
///     forever. AGENTS.md: "capabilities it drops are failures."
///  3. The oracle's own confinement key, `CONTACTS_TEST_GROUP`, is an operator env var of
///     exactly the same class as `APPLE_TEST_SANDBOX` — and `check_test_mode_safety` never
///     reads the target at all, so the CLI's fetched-target check is STRONGER than the oracle's
///     even with the prefix overridden.
///  4. Contacts delete is single-id. Widening the prefix selects no additional targets; each
///     deletion still names one CN id explicitly. Mail's `delete --permanent` is filter-based
///     and bulk, which is exactly how the 2026-07-25 `APPLE_TEST_SANDBOX="Re:"` incident swept
///     in a real message — that is what the canonical constant was introduced to stop, and the
///     mechanism has no counterpart here.

/// The `gate_note` for a sandboxed preview whose fetched-target label check cannot run here.
///
/// PREVIEW-HONESTY DIVERGENCE (disclosed, per docs/write-model-v2.md): `requireLabeled*Target`
/// resolves the target out of the Contacts store, which needs TCC authorization the preview
/// path deliberately does not take (a dry-run stays runnable in CI and on an unauthorized
/// machine). So a sandboxed preview of an id-addressed write says so rather than implying the
/// target passed a check that never ran.
func sandboxTargetUncheckedNote(_ what: String) -> String {
    "sandbox is engaged: the execute path additionally requires \(what) to be an "
    + "'\(TestMode.sandboxPrefix)'-labeled item. That check reads the Contacts store, so this "
    + "preview did not run it."
}

/// Join the gate notes a preview accumulated, or nil when it has none.
func joinedGateNote(_ parts: [String?]) -> String? {
    let kept = parts.compactMap { $0 }
    return kept.isEmpty ? nil : kept.joined(separator: " ")
}

/// Dry-run preview payload (a CLI extra — the oracle has no dry-run). Only the fields
/// relevant to each operation are populated; the rest omit via encodeIfPresent.
///
/// `note` is the write_note payload (the note text being set). `gate_note` is the
/// preview-honesty channel: a gate that WILL refuse this call, or one this preview could not
/// evaluate. Two distinct fields on purpose — conflating them would let a safety disclosure
/// be mistaken for user content.
struct DryRunPreview: Encodable {
    let dry_run = true
    let operation: String
    var identifier: String?
    var contact_identifier: String?
    var group_identifier: String?
    var group_id: String?
    var container_id: String?
    var name: String?
    var new_name: String?
    var note: String?
    var clears_photo: Bool?
    var parsed_count: Int?
    var fields: ContactFields?
    var gate_note: String?
}
