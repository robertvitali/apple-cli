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
        } catch let code as ExitCode {
            // A command body already emitted its JSON envelope via `runGuarded`, then signaled
            // its exit code by throwing ExitCode. Honor it verbatim — the envelope is already
            // out; re-emitting here would double-print AND clobber the real exit code (64/65/77).
            Foundation.exit(code.rawValue)
        } catch {
            // Not an ExitCode ⇒ an ArgumentParser outcome that never reached a command body.
            // `tool: "apple"` is intentional: the parse failed before a subcommand resolved, so
            // this is a binary-level event, not attributable to a domain.
            let ecode = Apple.exitCode(for: error)
            if ecode == .success {
                Apple.exit(withError: error) // --help / --version: prints to stdout, exit 0
            }
            // The human-readable detail may echo operator-supplied argv (e.g. "The value 'X' is
            // invalid for '--flag'"), so it goes to stderr ONLY — never onto the stdout machine
            // channel an agent captures. The stdout envelope carries a generic message instead.
            FileHandle.standardError.write(Data((Apple.fullMessage(for: error) + "\n").utf8))
            if ecode == .validationFailure {
                // A genuine parse/validation error (bad flag, missing/extra arg, bad value).
                Output.emitError(tool: "apple", type: AppleErrorType.validation,
                                 message: "invalid arguments (see stderr for details)")
                Foundation.exit(AppleExit.usage) // 64
            } else {
                // A non-parse, non-ExitCode error reached main() — e.g. a future command body
                // not wrapped in runGuarded. Report it as an internal error, not a usage error.
                Output.emitError(tool: "apple", type: AppleErrorType.unknown,
                                 message: "internal error (see stderr for details)")
                Foundation.exit(AppleExit.unknown) // 70
            }
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
