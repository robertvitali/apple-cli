import Foundation
import AppleKit

// Shared output + write-safety plumbing for every contacts subcommand.

/// Emit a payload as the JSON envelope (default) or a human rendering (`--text`).
/// JSON is the versioned contract; `--text` is a non-contractual convenience.
func emitContacts<T: Encodable>(_ global: GlobalOptions, _ data: T) throws {
    if global.json {
        try Output.emit(tool: "contacts", data: data)
    } else {
        let text = (try? humanRender(data)) ?? ""
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

/// Generic human renderer — one flat pass over the payload's JSON object, printing
/// `key: value` lines (nested objects/arrays shown as compact JSON). Honest, DRY, and
/// good enough for the convenience `--text` mode without per-type formatters.
private func humanRender<T: Encodable>(_ value: T) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(value)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return String(decoding: data, as: UTF8.self)
    }
    var lines: [String] = []
    for key in obj.keys.sorted() {
        lines.append("\(key): \(compact(obj[key]!))")
    }
    return lines.joined(separator: "\n")
}

private func compact(_ any: Any) -> String {
    if any is NSNull { return "null" }
    if let s = any as? String { return s }
    if let b = any as? Bool { return b ? "true" : "false" }
    if let n = any as? NSNumber { return n.stringValue }
    if let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes]) {
        return String(decoding: data, as: UTF8.self)
    }
    return String(describing: any)
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

// MARK: - Write-safety gate

/// Outcome of the destructive-op safety gate.
enum WriteDecision {
    case dryRun    // default: emit a preview, mutate nothing
    case execute   // test-mode gate satisfied: proceed to mutate
}

/// Resolve whether a destructive command may execute. Fail-closed:
/// - default (no `--execute`, or `--dry-run` present) → `.dryRun` (safe preview).
/// - `--execute` but the test-mode gate is unsatisfied → `safety_violation`.
/// - `--execute` + `--test-mode` + `APPLE_TEST_MODE=1` → `.execute`.
///   When `labeledName` is supplied (create / create-group), it must also carry the
///   sandbox prefix — "create only clearly-labeled test data".
///
/// This preserves the MCP's `safety_violation` `error.type` while being strictly more
/// conservative than the MCP (which gated only deletes); `--dry-run` is a CLI extra.
func resolveWrite(_ global: GlobalOptions, labeledName: String? = nil) throws -> WriteDecision {
    guard global.willExecute else { return .dryRun }
    guard global.testMode && TestMode.isEnabled else {
        throw AppleError.safetyViolation(
            "refusing a live write: pass --execute --test-mode AND set APPLE_TEST_MODE=1 "
            + "(the default is a --dry-run preview that mutates nothing).")
    }
    if let name = labeledName {
        guard name.hasPrefix(TestMode.sandboxPrefix) else {
            throw AppleError.safetyViolation(
                "refusing to create unlabeled data in test mode: name must start with "
                + "'\(TestMode.sandboxPrefix)'.")
        }
    }
    return .execute
}

/// Dry-run preview payload (a CLI extra — the MCP has no dry-run). Only the fields
/// relevant to each operation are populated; the rest omit via encodeIfPresent.
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
}
