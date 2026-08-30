import ArgumentParser
import AppleKit

/// `apple contacts …` — Contacts.
///
/// Ports `apple-contacts-mcp` (@ 1cd8789, v0.3.0, 21 tools) to a strict superset over
/// Contacts.framework (`CNContactStore`) with an AppleScript fallback for the two
/// entitlement-gated ops (contact notes, group remove-member). Adds curated extras:
/// `search --deep` (all-field), `--dry-run`/`--execute` write gating, `--out`/`--file`
/// file I/O for vCard and photos, and `--json` full-fidelity create/update.
///
/// Command surface (each maps to an MCP tool):
///   auth · list · get · search · create · update · delete
///   note {get,set} · photo {get,set}
///   groups {list,members,create,rename,delete,add,remove}
///   vcard {export,import} · containers list
///
public struct ContactsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Contacts — CRUD, groups, vCard, notes, photos (ports apple-contacts-mcp).",
        subcommands: [
            AuthCommand.self,
            ListCommand.self,
            GetCommand.self,
            SearchCommand.self,
            CreateCommand.self,
            UpdateCommand.self,
            DeleteCommand.self,
            NoteCommand.self,
            PhotoCommand.self,
            GroupsCommand.self,
            VCardCommand.self,
            ContainersCommand.self,
        ]
    )
    public init() {}
}

// MARK: - Subcommand groups (bare invocation prints help via ArgumentParser default)

struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Read/write a contact's note (AppleScript; entitlement-gated field).",
        subcommands: [NoteGetCommand.self, NoteSetCommand.self])
}

struct PhotoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photo",
        abstract: "Read/write a contact's photo.",
        subcommands: [PhotoGetCommand.self, PhotoSetCommand.self])
}

struct GroupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List/inspect/manage contact groups and membership.",
        subcommands: [
            GroupsListCommand.self, GroupsMembersCommand.self, GroupsCreateCommand.self,
            GroupsRenameCommand.self, GroupsDeleteCommand.self, GroupsAddCommand.self,
            GroupsRemoveCommand.self,
        ])
}

struct VCardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vcard",
        abstract: "Export/import contacts as vCard.",
        subcommands: [VCardExportCommand.self, VCardImportCommand.self])
}

struct ContainersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "containers",
        abstract: "List contact containers (accounts).",
        subcommands: [ContainersListCommand.self])
}
