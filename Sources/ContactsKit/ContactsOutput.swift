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

/// Clamp a requested page size to the hard cap (mirrors `min(limit, MAX)` in the MCP).
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

/// Read a file into memory only after confirming it is under the size ceiling.
func readBoundedFile(_ path: String, _ what: String) throws -> Data {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    if let size = attrs?[.size] as? Int, size > maxContactsInputBytes {
        throw AppleError.validation(
            "\(what) file exceeds the \(maxContactsInputBytes / (1024 * 1024)) MB limit (\(size) bytes)")
    }
    do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
    catch { throw AppleError.validation("failed to read \(what) file \(path): \(error.localizedDescription)") }
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
/// calling the equivalent apple-contacts-mcp tool does. `--dry-run` previews; `APPLE_DRY_RUN`
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
                + "'\(required)'.")
        }
    }
    return WriteGate(willExecute: willExecute, sandboxActive: sandboxActive)
}

// MARK: - Oracle-mirrored hard gate on the two deletes

/// Whether the operator has granted the oracle-mirrored delete gate.
///
/// ORACLE-MIRRORED (bucket 1 — kept UNCONDITIONALLY under write-model v2, sandbox or not).
/// apple-contacts-mcp refuses `delete_contact` (server.py:965) and `delete_group`
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
var contactsDeleteEnvGranted: Bool { TestMode.isTruthyEnv(TestMode.testModeVar) }

/// The refusal text for an ungranted delete — shared by the execute path (thrown) and the
/// preview (reported in `gate_note`), so a preview can never claim clean for a call the
/// execute path refuses.
func contactsDeleteGateMessage(_ operation: String) -> String {
    "\(operation) is only available with \(TestMode.testModeVar)=1 in the environment — "
    + "mirroring apple-contacts-mcp's require_test_mode_for/CONTACTS_TEST_MODE gate on this "
    + "op (its destructive path has no confirmation UX). A --test-mode FLAG deliberately does "
    + "NOT satisfy it: the oracle keys this gate to the environment, so the replacement does too."
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

/// Dry-run preview payload (a CLI extra — the MCP has no dry-run). Only the fields
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
