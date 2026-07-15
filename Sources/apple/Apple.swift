import Foundation
import ArgumentParser
import AppleKit
import MessagesKit
import MailKit
import ContactsKit
import NotesKit
import CalendarKit
import RemindersKit

// NOTE: this file must NOT be named `main.swift` — @main and a file named main.swift
// conflict in SwiftPM.

@main
struct Apple: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple",
        abstract: "One CLI for Apple's native apps — Messages, Mail, Contacts, Notes, Calendar, Reminders.",
        version: AppleVersion.current,
        subcommands: [
            MessagesCommand.self,
            MailCommand.self,
            ContactsCommand.self,
            NotesCommand.self,
            CalendarCommand.self,
            RemindersCommand.self,
            VersionCommand.self,
        ]
    )

    // Custom entry point so we can ignore SIGPIPE (a consumer closing the pipe early —
    // `apple … | head` — yields a clean exit, not an uncatchable crash) before dispatch.
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            exit(withError: error)
        }
    }
}

/// `apple version` — machine-readable version + output schema, for runtime capability
/// detection by agents (docs/versioning-policy.md §5.4). (`--version` prints the bare string.)
struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version + JSON schema_version (for runtime capability detection)."
    )
    struct Info: Encodable {
        let version: String
        let schema_version: Int
    }
    func run() throws {
        try runGuarded(tool: "version") {
            try Output.emit(tool: "version", data: Info(version: AppleVersion.current, schema_version: AppleVersion.schema))
        }
    }
}
