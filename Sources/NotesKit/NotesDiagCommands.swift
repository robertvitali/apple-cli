import ArgumentParser
import Foundation
import AppleKit

// Diagnostics, export, and reveal-in-UI. `sync-status` is SQLite/WAL-backed (live-testable
// without Notes automation); `export`/`stats`/`health`/`doctor` mix AppleScript + FDA probes.

extension NotesStore {
    /// Notes-specific Full Disk Access probe: can we actually open NoteStore.sqlite for reading?
    /// (AppleKit's `Permissions.hasFullDiskAccess` probes Messages/TCC; the Notes-relevant grant
    /// is NoteStore readability.)
    static func hasFDA() -> Bool {
        guard dbExists else { return false }
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
        try runGuarded(tool: notesTool) {
            let status = NotesStore.syncStatus()
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
        try runGuarded(tool: notesTool) {
            let (healthy, checks) = NotesScript().healthCheck()
            let fda = NotesStore.hasFDA()
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
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
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
            let fda = NotesStore.hasFDA()
            checks.append(DoctorCheck(name: "Full Disk Access", status: fda ? "ok" : "warn",
                detail: fda ? "granted — checklist features available"
                    : "not granted — get-checklist and checklist annotations in get-markdown won't work. Grant your terminal Full Disk Access in System Settings > Privacy & Security."))
            checks.append(Self.binarySignatureCheck())
            let healthy = !checks.contains { $0.status == "fail" }
            try emitNotes(DoctorResult(healthy: healthy, checks: checks), json: global.json,
                          human: healthy ? "healthy" : "ISSUES FOUND")
        }
    }

    /// Adapts the reference's Node-runtime-signature check to the `apple` binary: an ad-hoc-signed
    /// binary loses TCC (Automation/FDA) grants on every rebuild, which looks like random
    /// permission loss. Best-effort (never fails the run).
    static func binarySignatureCheck() -> DoctorCheck {
        let name = "Binary signature"
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
            if out.isEmpty { return DoctorCheck(name: name, status: "warn", detail: "could not inspect \(exe) with codesign") }
            let adhoc = out.range(of: "Signature=adhoc", options: .regularExpression) != nil
                || out.contains("TeamIdentifier=not set")
            if adhoc {
                return DoctorCheck(name: name, status: "warn",
                    detail: "\(exe) is ad-hoc signed (no Team ID). macOS revokes its Automation and Full Disk "
                        + "Access grants whenever the binary changes; sign with a Developer ID at a stable path to persist grants.")
            }
            return DoctorCheck(name: name, status: "ok", detail: "\(exe) has a stable signature — TCC grants persist across updates")
        } catch {
            return DoctorCheck(name: name, status: "warn", detail: "could not inspect binary signature")
        }
    }
}

// MARK: stats

struct StatsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats",
        abstract: "Library totals: per-account/folder counts + recent-activity, with partial-coverage flags.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: notesTool) {
            let stats = try NotesScript().getNotesStats()
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
        try runGuarded(tool: notesTool) {
            let data = try NotesScript().exportNotesAsJson()
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
        try runGuarded(tool: notesTool) {
            try NotesScript().showNote(id: id, separately: separately)
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
        try runGuarded(tool: notesTool) {
            try NotesScript().showFolder(id: id, separately: separately)
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
        try runGuarded(tool: notesTool) {
            try NotesScript().showAccount(id: id, separately: separately)
            try emitNotes(ShownEntity(id: id, separately: separately), json: global.json, human: "Shown account \(id).")
        }
    }
}
