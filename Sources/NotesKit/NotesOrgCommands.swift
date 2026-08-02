import ArgumentParser
import Foundation
import AppleKit

// Folder + account commands.

// MARK: folders (list)

struct FoldersCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "folders",
        abstract: "List all folders (with full nested paths) for an account.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account to list folders from.") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let folders = try NotesScript().listFolders(account: account)
            try emitNotes(FolderList(folders: folders, count: folders.count, sync_warning: currentSyncWarning()),
                json: global.json,
                human: folders.isEmpty ? "No folders." : folders.map { "  - \($0.name)" }.joined(separator: "\n"))
        }
    }
}

// MARK: create-folder

struct CreateFolderCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-folder",
        abstract: "Create a folder, nested paths create intermediates (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Folder name or nested path (A/B/C).") var name: String
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            try validateBounds(folder: name, account: account)
            try requireNonEmptyFolderName(name)
            let gate = try resolveNotesWrite(global)
            // The folder name is argv-supplied, so the sandbox label check is computable here
            // and runs on BOTH paths — no store read, and the preview refuses what execute does.
            try guardLiveWrite(labeledName: name, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                try emitNotesWrite(DryRunPreview("create-folder", "Would create folder \"\(name)\". Re-run without --dry-run."),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would create folder \"\(name)\".")
                return
            }
            let folder = try NotesScript().createFolder(name: name, account: account)
            try emitNotesWrite(CreatedFolder(ok: true, folder: folder.name), json: global.json,
                               sandboxActive: gate.sandboxActive,
                               human: "Created folder \"\(folder.name)\".")
        }
    }
}

// MARK: delete-folder

struct DeleteFolderCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete-folder",
        abstract: "Delete a folder AND EVERY NOTE IN IT, permanently (previews by default; --execute performs it).")
    /// PER-SURFACE DEFAULT: this one surface previews unless `--execute` is passed, while every
    /// other Notes write executes on invocation. Deliberate, and a knowing deviation from strict
    /// oracle parity (the oracle cascades too, on call). The justification is the spec's own
    /// rule for `APPLE_ALLOW_EMPTY_TRASH`: an op that destroys an unbounded amount of unlabeled
    /// real data wholesale, irreversibly, in ONE flagless invocation warrants a control the
    /// caller must reach for. Measured here: the cascaded notes do NOT reach Recently Deleted.
    /// Pinned by a marker test; flipping it to `false` restores strict parity in one line if the
    /// operator prefers that.
    static let surfaceDefaultDryRun = true

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Folder name or nested path.") var name: String
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            try validateBounds(folder: name, account: account)
            try requireNonEmptyFolderName(name)
            let gate = try resolveNotesWrite(global, defaultDryRun: Self.surfaceDefaultDryRun)
            try guardLiveWrite(labeledName: name, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                try emitNotesWrite(DryRunPreview("delete-folder", "Would delete folder \"\(name)\" AND EVERY NOTE IN IT. Measured: this cascades, and the cascaded notes do NOT go to Recently Deleted — they are destroyed permanently. Pass --execute to perform it."),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would delete folder \"\(name)\".")
                return
            }
            try NotesScript().deleteFolder(name: name, account: account)
            try emitNotesWrite(CreatedFolder(ok: true, folder: name), json: global.json,
                               sandboxActive: gate.sandboxActive,
                               human: "Deleted folder \"\(name)\".")
        }
    }
}

// MARK: accounts

struct AccountsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "accounts",
        abstract: "List Notes accounts (iCloud, Gmail, Exchange…) with default folder + upgraded flag.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: notesTool) {
            let accounts = try NotesScript().listAccounts()
            try emitNotes(AccountList(accounts: accounts, count: accounts.count), json: global.json,
                human: accounts.isEmpty ? "No accounts." : accounts.map { "  - \($0.name)" }.joined(separator: "\n"))
        }
    }
}

// MARK: default-location

struct DefaultLocationCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "default-location",
        abstract: "The default account + folder where Notes.app creates new notes.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: notesTool) {
            let loc = try NotesScript().getDefaultLocation()
            try emitNotes(loc, json: global.json,
                          human: "Default account: \(loc.account.name)\nDefault folder: \(loc.folder.name)")
        }
    }
}

// MARK: shared (list-shared-notes)

struct SharedCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shared",
        abstract: "Notes shared with collaborators (title, account, id).")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: notesTool) {
            let notes = try NotesScript().listSharedNotes()
            try emitNotes(SharedNoteList(notes: notes, count: notes.count), json: global.json,
                human: notes.isEmpty ? "No shared notes." : notes.map { "  - \($0.title) [\($0.id)]" }.joined(separator: "\n"))
        }
    }
}
