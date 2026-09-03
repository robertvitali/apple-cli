import ArgumentParser
import Foundation
import AppleKit

// Diagnostics, export, and reveal-in-UI. `sync-status` is SQLite/WAL-backed (live-testable
// without Notes automation); `export`/`stats`/`health`/`doctor` mix AppleScript + FDA probes.

extension NotesStore {
    /// Notes-specific Full Disk Access probe: can we actually open NoteStore.sqlite for reading?
    /// (AppleKit's `Permissions.hasFullDiskAccess` probes Messages/TCC; the Notes-relevant grant
    /// is NoteStore readability.)
    static func hasFDA() -> Bool { hasFDA(dbPath: dbPath) }

    /// Path-parameterized core of `hasFDA`, for the same reason the read cores in `NotesStore`
    /// carry one: the logic tier points it at a synthetic fixture instead of the operator's store.
    static func hasFDA(dbPath: String) -> Bool {
        guard exists(at: dbPath) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: dbPath)) else { return false }
        try? handle.close()
        return true
    }
}

// MARK: sync-status (SQLite/WAL — live)

struct SyncStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-status",
        abstract: "Whether iCloud sync is in progress (pending count + seconds since last change).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try run(storeFactory: { LiveNotesStore() })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(storeFactory: () -> any NotesStoreReading) throws {
        try runGuarded(tool: notesTool) {
            let store = storeFactory()
            let status = store.syncStatus()
            try emitNotes(status, json: global.json,
                          human: status.sync_detected ? "iCloud sync: ACTIVE" : "iCloud sync: idle")
        }
    }
}

// MARK: health-check

struct HealthCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "health",
        abstract: "Quick pass/fail: Notes.app reachable + Full Disk Access for checklist features.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) }, storeFactory: { LiveNotesStore() })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript,
             storeFactory: () -> any NotesStoreReading) throws {
        try runGuarded(tool: notesTool) {
            let store = storeFactory()
            let (healthy, checks) = scriptFactory().healthCheck()
            let fda = store.hasFDA()
            try emitNotes(HealthResult(healthy: healthy, checks: checks, full_disk_access: fda),
                          json: global.json, human: (healthy ? "healthy" : "issues detected") + ", FDA: \(fda)")
        }
    }
}

// MARK: doctor

struct DoctorCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor",
        abstract: "Detailed setup diagnostics (automation permission, accounts, Full Disk Access, binary signature).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) }, storeFactory: { LiveNotesStore() }, signatureCheck: { DoctorCmd.binarySignatureCheck() })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript,
             storeFactory: () -> any NotesStoreReading,
             signatureCheck: () -> DoctorCheck) throws {
        try runGuarded(tool: notesTool) {
            let store = storeFactory()
            let script = scriptFactory()
            var checks: [DoctorCheck] = []
            let (_, hc) = script.healthCheck()
            for c in hc { checks.append(DoctorCheck(name: "Notes.app: \(c.name)", status: c.passed ? "ok" : "fail", detail: c.message)) }
            if let accounts = try? script.listAccounts() {
                checks.append(DoctorCheck(name: "Accounts", status: accounts.isEmpty ? "warn" : "ok",
                    detail: accounts.isEmpty ? "no Notes accounts found"
                        : "\(accounts.count) account(s): \(accounts.map { $0.name }.joined(separator: ", "))"))
            } else {
                checks.append(DoctorCheck(name: "Accounts", status: "fail", detail: "could not list accounts"))
            }
            let fda = store.hasFDA()
            checks.append(DoctorCheck(name: "Full Disk Access", status: fda ? "ok" : "warn",
                detail: fda ? "granted — checklist features available"
                    : "not granted — get-checklist and checklist annotations in get-markdown won't work. Grant your terminal Full Disk Access in System Settings > Privacy & Security."))
            checks.append(signatureCheck())
            let healthy = !checks.contains { $0.status == "fail" }
            try emitNotes(DoctorResult(healthy: healthy, checks: checks), json: global.json,
                          human: healthy ? "healthy" : "ISSUES FOUND")
        }
    }

    /// The check's NAME on the wire. One constant so the classifier and the spawn cannot drift.
    static let signatureCheckName = "Binary signature"

    /// The whole DECISION `binarySignatureCheck` makes, as a pure function of what `codesign -dvvv`
    /// wrote and which binary was inspected.
    ///
    /// Split out because the classification is the part with branches and the spawn is the part
    /// that cannot be exercised in a unit test: `binarySignatureCheck` is only ever bound by
    /// `DoctorCmd.run()`, and every `doctor` test binds a stub `signatureCheck:` seam instead — so
    /// before this split, all four outcomes below (ad-hoc via `Signature=adhoc`, ad-hoc via
    /// `TeamIdentifier=not set`, empty output, and a stable signature) were reachable only by
    /// running the real `codesign` against the real binary, and none of them was covered.
    ///
    /// `codesign` writes its report to STDERR, which the caller merges into the same pipe, so
    /// `output` is the combined stream.
    static func classifySignature(_ output: String, executable: String) -> DoctorCheck {
        let name = signatureCheckName
        // Nothing but whitespace means codesign said nothing at all — it ran but produced no
        // report (a binary it cannot read, an unexpected build). Not a pass and not a definite
        // ad-hoc: warn. Trimmed, because a lone "\n" is the same non-answer as "" and must not
        // classify as a stable signature on a security-posture check.
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DoctorCheck(name: name, status: "warn", detail: "could not inspect \(executable) with codesign")
        }
        // Both tells are LITERALS, matched literally. `range(of:options: .regularExpression)` was
        // behaviorally identical today (`=` carries no meaning in ICU regex) but it invited a later
        // edit adding a `.` or `+` to the tell to silently change matching semantics here.
        let adhoc = output.contains("Signature=adhoc")
            || output.contains("TeamIdentifier=not set")
        if adhoc {
            return DoctorCheck(name: name, status: "warn",
                detail: "\(executable) is ad-hoc signed (no Team ID). macOS revokes its Automation and Full Disk "
                    + "Access grants whenever the binary changes; sign with a Developer ID at a stable path to persist grants.")
        }
        return DoctorCheck(name: name, status: "ok", detail: "\(executable) has a stable signature — TCC grants persist across updates")
    }

    /// Adapts the reference's Node-runtime-signature check to the `apple` binary: an ad-hoc-signed
    /// binary loses TCC (Automation/FDA) grants on every rebuild, which looks like random
    /// permission loss. Best-effort (never fails the run).
    ///
    /// KNOWINGLY UNTESTED: the `Process` spawn itself. Running it in a unit test would shell out to
    /// `/usr/bin/codesign` against whatever binary happens to be hosting the test bundle, so the
    /// verdict would be a property of the build machine rather than of this code. The decision it
    /// feeds is `classifySignature`, which is pure and covered; what is left here is the spawn, the
    /// pipe read, and the launch-failure `catch`. Listed rather than left to look like coverage.
    static func binarySignatureCheck() -> DoctorCheck {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "/usr/bin/true"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dvvv", exe]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            proc.waitUntilExit()
            return classifySignature(out, executable: exe)
        } catch {
            // codesign could not be launched at all — a different failure from "ran and said
            // nothing", so it keeps its own wording rather than routing through the classifier.
            return DoctorCheck(name: signatureCheckName, status: "warn", detail: "could not inspect binary signature")
        }
    }
}

// MARK: stats

struct StatsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats",
        abstract: "Library totals: per-account/folder counts + recent-activity, with partial-coverage flags.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            let stats = try scriptFactory().getNotesStats()
            try emitNotes(stats, json: global.json, human: "Total notes: \(stats.total_notes)")
        }
    }
}

// MARK: export (json + curated md/txt)

struct RenderedExport: Encodable {
    let format: String
    let note_count: Int
    let content: String
}

struct ExportCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export",
        abstract: "Export the whole library. --format json (structured, default) | md | txt (curated extras).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Export format: json|md|txt.") var format: String = "json"

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            let data = try scriptFactory().exportNotesAsJson()
            switch format.lowercased() {
            case "json":
                try emitNotes(data, json: global.json,
                    human: "Exported \(data.summary.total_notes) notes from \(data.summary.total_folders) folders.")
            case "md", "txt":
                let md = format.lowercased() == "md"
                var blocks: [String] = []
                var count = 0
                for account in data.accounts {
                    for folder in account.folders {
                        for note in folder.notes {
                            count += 1
                            if md {
                                blocks.append("# \(note.title)\n\n" + ((try? NotesText.htmlToMarkdown(note.content)) ?? "_[list nesting too deep to render]_"))
                            } else {
                                blocks.append("\(note.title)\n\n\(note.plaintext)")
                            }
                        }
                    }
                }
                let content = blocks.joined(separator: "\n\n---\n\n")
                try emitNotes(RenderedExport(format: format.lowercased(), note_count: count, content: content),
                              json: global.json, human: content)
            default:
                throw AppleError.validation("Invalid --format \"\(format)\" (expected json|md|txt).")
            }
        }
    }
}

// MARK: reveal in UI

struct ShowNoteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-note", abstract: "Reveal a note in the Notes.app UI by id.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id.") var id: String
    @Flag(name: .long, help: "Open in a separate window.") var separately = false
    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            try scriptFactory().showNote(id: id, separately: separately)
            try emitNotes(ShownEntity(id: id, separately: separately), json: global.json, human: "Shown note \(id).")
        }
    }
}

struct ShowFolderCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-folder", abstract: "Reveal a folder in the Notes.app UI by id.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Folder id (from `folders`).") var id: String
    @Flag(name: .long, help: "Open in a separate window.") var separately = false
    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            try scriptFactory().showFolder(id: id, separately: separately)
            try emitNotes(ShownEntity(id: id, separately: separately), json: global.json, human: "Shown folder \(id).")
        }
    }
}

struct ShowAccountCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-account", abstract: "Reveal an account in the Notes.app UI by id.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account id (from `accounts`).") var id: String
    @Flag(name: .long, help: "Open in a separate window.") var separately = false
    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            try scriptFactory().showAccount(id: id, separately: separately)
            try emitNotes(ShownEntity(id: id, separately: separately), json: global.json, human: "Shown account \(id).")
        }
    }
}
