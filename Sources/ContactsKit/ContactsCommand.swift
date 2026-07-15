import ArgumentParser
import AppleKit

/// `apple contacts …` — Contacts.
///
/// Ports `apple-contacts-mcp` (@ 1cd8789, 21 tools) to a strict superset over
/// Contacts.framework (CNContactStore) + `AppleScriptRunner` fallback for the two
/// entitlement-gated ops (notes, remove-member). Must build the universally-missing ops:
/// notes r/w, photo r/w, vCard import, group add/remove-member, rename, containers.
///
/// Asana: feat/asana-GID-REDACTED-contacts
public struct ContactsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Contacts — CRUD, groups, vCard, notes, photos (ports apple-contacts-mcp).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "contacts") {
            throw AppleError.notImplemented("contacts domain not yet implemented — see feat/asana-GID-REDACTED-contacts")
        }
    }
}
