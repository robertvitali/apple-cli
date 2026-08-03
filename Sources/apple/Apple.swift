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


    /// The domain a pre-dispatch failure belongs to, or `"apple"` when none resolved.
    ///
    /// When `argv[1]` is the subcommand token it names the intended domain even though the parse
    /// failed — `apple notes --bogus` is unambiguously a Notes invocation — and the output contract
    /// (AGENTS.md, docs/DESIGN.md) specifies `tool` on the ERROR envelope with no parse-failure
    /// carve-out. It is not always the subcommand token (`apple --text notes --bogus` and
    /// `apple NOTES --bogus` both resolve nothing and stay `"apple"`), which is fail-safe.
    ///
    /// The pre-dispatch path carries every unknown flag, unknown verb, missing/extra positional
    /// and every numeric argument-parsing rejects before a body runs, across all six domains —
    /// a large, uniform slice, which is what made mis-attributing it worth fixing.
    ///
    /// SECURITY: `argv[1]` is operator-controlled and this value lands on the stdout MACHINE
    /// channel, which the PRE-DISPATCH path never lets argv reach — the detailed message is
    /// confined to stderr precisely because it echoes argv. (Scope that to this path, not the
    /// binary: command bodies legitimately echo operator identifiers, e.g. `contacts get X`
    /// reporting "No contact found with identifier 'X'".) Three properties:
    ///
    /// 1. An unknown `argv[1]` yields `"apple"` — the candidate must match a REGISTERED name.
    /// 2. The value returned is a registered literal, never the candidate's bytes. Swift's `==`
    ///    is Unicode CANONICAL equivalence, so a match does not imply byte equality: a
    ///    hypothetical name `blocK` compares equal to `bloc` + U+212A KELVIN while differing in
    ///    bytes. Unreachable today only because every registered name is lowercase ASCII — a
    ///    property of the current NAMING, not of the code.
    /// 3. The value is the subcommand's PRIMARY name. The contract enumerates domains, and an
    ///    alias is not one: returning the matched spelling would emit `tool:"msg"` for
    ///    `apple msg --bogus` — the same wrong-routing-key defect this helper exists to fix,
    ///    reached by a different spelling.
    ///
    /// Resolving to the SUBCOMMAND and then asking it for its name gets 2 and 3 together, and
    /// makes the predicate a structural mirror of ArgumentParser's own matcher rather than a
    /// union assembled by hand. `Tree.firstChild(withName:)` (Utilities/Tree.swift, pinned
    /// checkout) dispatches on exactly `_commandName == name || configuration.aliases.contains(name)`,
    /// and the `first { … }` below is arm-for-arm that test — so this resolves anything
    /// ArgumentParser would dispatch on by NAME. `_commandName` itself is
    /// `configuration.commandName` or a snake-cased type name when that is nil
    /// (ParsableCommand.swift), so all three ways of acquiring a name are covered. Name-based
    /// dispatch only: `defaultSubcommand` goes through `firstChild(equalTo:)` instead, and the
    /// lint asserts we do not set one.
    ///
    /// Properties 2 and 3 are LATENT for THIS roster — no registered name is non-ASCII and none
    /// declares an alias — so no in-tree test can fail on a revert of either. (Review proved 3 in
    /// an isolated build that registered an alias and a name-less subcommand; both resolve
    /// correctly here and both report "apple" under the old spelling.) `bats/helpers/subcommand_allowlist.py`
    /// pins this body, both `emitError` call sites, and the upstream matcher. Change it
    /// deliberately when you change these lines; never to make the lint pass.
    static func toolForParseFailure() -> String {
        let fallback = "apple"
        guard CommandLine.arguments.count > 1 else { return fallback }
        let candidate = CommandLine.arguments[1]
        let match = configuration.subcommands.first {
            $0._commandName == candidate || $0.configuration.aliases.contains(candidate)
        }
        return match?._commandName ?? fallback
    }

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
            // The envelope's `tool` names the DOMAIN when argv[1] identifies one — see
            // `toolForParseFailure()`. An earlier version emitted "apple" unconditionally on the
            // reasoning that a pre-subcommand parse failure is a binary-level event. That reads
            // well but contradicts the contract: AGENTS.md and docs/DESIGN.md both specify
            // `"tool": "<domain>"` on the ERROR envelope as well as the ok one, with no
            // parse-failure carve-out, so a consumer routing on `tool` was misrouted at exactly
            // the moment something went wrong.
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
                Output.emitError(tool: Apple.toolForParseFailure(), type: AppleErrorType.validation,
                                 message: "invalid arguments (see stderr for details)")
                Foundation.exit(AppleExit.usage) // 64
            } else {
                // A non-parse, non-ExitCode error reached main() — e.g. a future command body
                // not wrapped in runGuarded. Report it as an internal error, not a usage error.
                Output.emitError(tool: Apple.toolForParseFailure(), type: AppleErrorType.unknown,
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
