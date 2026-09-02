import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

@Suite("Mail context and root command wiring")
struct MailContextCommandTests {
    private let scratch = ScratchDirs("mail-context-cmd")
    /// REQUIRED, deliberately un-defaulted: `MailContext.accounts()` falls back to constructing a
    /// live `AccountDirectory()` when handed nil, and that one drives Mail.app over AppleScript on
    /// first use. A `= nil` default made "forget the argument" compile into a live dependency —
    /// exactly the shape the injection seams exist to remove. Every sibling suite requires it too.
    private func fixtureContext(directory: AccountDirectory) throws -> MailContext {
        let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        return try MailContext(explicitPath: fixture, accountDirectory: directory)
    }

    private func accountDirectory() -> AccountDirectory {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.untimedResults = [
            [
                EnvelopeIndexTests.iCloudUUID,
                "Example Account",
                "imap",
                "true",
                "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        return AccountDirectory(runner: fake)
    }

    @Test func mailCommandRegistersExpectedSubcommands() throws {
        let command = try MailCommand.parse([])
        let config = MailCommand.configuration
        #expect(command.global.json == true)
        #expect(config.commandName == "mail")
        #expect(config.abstract.contains("Mail.app"))
        #expect(config.subcommands.contains { $0 == AccountsCommand.self })
        #expect(config.subcommands.contains { $0 == SearchCommand.self })
        #expect(config.subcommands.contains { $0 == ExportCommand.self })
        #expect(config.subcommands.contains { $0 == TrashCommand.self })
    }

    @Test func contextResolvesAccountsFromInjectedDirectoryAndIndexFallback() throws {
        let ctx = try fixtureContext(directory: accountDirectory())

        #expect(try ctx.requireAccountUUID("Example Account") == EnvelopeIndexTests.iCloudUUID)
        #expect(try ctx.requireAccountUUID(EnvelopeIndexTests.gmailUUID) == EnvelopeIndexTests.gmailUUID)
    }

    @Test func contextDecodesLabelsAndSummariesWithInjectedDirectory() throws {
        let ctx = try fixtureContext(directory: accountDirectory())
        var filters = EnvelopeIndex.MessageFilters()
        filters.accountUUID = EnvelopeIndexTests.iCloudUUID
        filters.mailboxName = "INBOX"
        filters.limit = 1

        let row = try #require(try ctx.index.queryMessages(filters).first)
        let labels = ctx.labels(forMailboxRowid: 1)
        let message = ctx.decodeSummary(row)

        #expect(labels.path == "INBOX")
        #expect(labels.account == "Example Account")
        #expect(message.account == "Example Account")
        #expect(message.mailbox == "INBOX")
    }

    @Test func contextAccountResolutionDistinguishesUnknownFromDirectoryFailure() {
        let unknown = MailContext.accountResolutionError(
            selector: "Missing Account",
            directoryLoadError: nil,
            knownNames: ["Example Account"])
        #expect(String(describing: unknown).contains("unknown account"))
        #expect(String(describing: unknown).contains("Known accounts"))

        let failed = MailContext.accountResolutionError(
            selector: "Example Account",
            directoryLoadError: AppleError.upstream("synthetic directory failure"),
            knownNames: [])
        #expect(String(describing: failed).contains("cannot resolve account"))
        #expect(String(describing: failed).contains("account directory could not be read"))
    }
}
