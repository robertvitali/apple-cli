import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

@Suite("Mail account commands with injected dependencies")
struct MailAccountCommandInjectionTests {
    private let scratch = ScratchDirs("mail-account-cmd")
    private func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
    }

    private func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        return try #require(object as? [String: Any])
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

    private func context() throws -> MailContext {
        let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        return try MailContext(explicitPath: fixture, accountDirectory: accountDirectory())
    }

    @Test func accountsListUsesInjectedDirectory() throws {
        let command = try AccountsList.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(directoryFactory: { accountDirectory() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["count"] as? Int == 1)
        let accounts = try #require(data["accounts"] as? [[String: Any]])
        #expect(accounts.first?["name"] as? String == "Example Account")
        #expect(accounts.first?["id"] as? String == EnvelopeIndexTests.iCloudUUID)
    }

    @Test func accountsListTextUsesInjectedDirectory() throws {
        let command = try AccountsList.parse(["--text"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(directoryFactory: { accountDirectory() })
        }

        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("Example Account [imap]"))
        #expect(text.contains(EnvelopeIndexTests.iCloudUUID))
    }

    @Test func mailboxesListUsesInjectedContextAndHonorsNoCounts() throws {
        let command = try MailboxesList.parse([
            "--account", "Example Account",
            "--no-counts",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["account"] as? String == "Example Account")
        #expect(data["count"] as? Int == 2)
        let mailboxes = try #require(data["mailboxes"] as? [[String: Any]])
        #expect(mailboxes.allSatisfy { $0["account"] as? String == "Example Account" })
        #expect(mailboxes.allSatisfy { $0["total_count"] == nil })
    }

    @Test func mailboxesListTextIncludesCountsFromInjectedContext() throws {
        let command = try MailboxesList.parse(["--account", "Example Account", "--text"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("Example Account: INBOX  [2 total, 1 unread]"))
        #expect(text.contains("Example Account: Sent Messages  [1 total, 0 unread]"))
    }

    @Test func unreadCountsUsesInjectedDirectoryAndScript() throws {
        let command = try UnreadCountsCommand.parse([
            "--account", "Example Account",
            "--summary",
            "--include-zero",
        ])
        let scriptRunner = MailScriptInjectionTests.FakeMailRunner()
        scriptRunner.untimedResults = ["Example Account\(MailScript.US)INBOX\(MailScript.US)2\(MailScript.RS)"]
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(
                scriptFactory: { MailScript(runner: scriptRunner) },
                directoryFactory: { accountDirectory() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["total_unread"] as? Int == 2)
        let summary = try #require(data["summary"] as? [String: Int])
        #expect(summary["Example Account"] == 2)
    }

    @Test func unreadCountsNestedTextUsesInjectedScriptWithoutDirectoryLookup() throws {
        let command = try UnreadCountsCommand.parse(["--text", "--include-zero"])
        let scriptRunner = MailScriptInjectionTests.FakeMailRunner()
        scriptRunner.untimedResults = [
            "Example Account\(MailScript.US)INBOX\(MailScript.US)2\(MailScript.RS)" +
            "Example Account\(MailScript.US)Archive\(MailScript.US)0\(MailScript.RS)",
        ]
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(
                scriptFactory: { MailScript(runner: scriptRunner) },
                directoryFactory: { accountDirectory() })
        }

        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("Example Account:"))
        #expect(text.contains("  INBOX: 2"))
        #expect(text.contains("  Archive: 0"))
    }

    @Test func doctorUsesInjectedPreflightContextAndDirectory() throws {
        let command = try MailDoctor.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(
                contextFactory: { try context() },
                directoryFactory: { accountDirectory() },
                preflightFactory: { Permissions.Preflight(full_disk_access: true, notes: ["synthetic preflight"]) },
                locateDBFactory: { "/tmp/synthetic-envelope-index.sqlite" })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["full_disk_access"] as? Bool == true)
        #expect(data["envelope_index_path"] as? String == "/tmp/synthetic-envelope-index.sqlite")
        #expect(data["envelope_index_readable"] as? Bool == true)
        #expect(data["mailbox_count"] as? Int == 4)
        #expect(data["account_count"] as? Int == 1)
        #expect(data["mail_automation"] as? Bool == true)
        #expect(data["notes"] as? [String] == ["synthetic preflight"])
    }

    @Test func doctorReportsUnreadableLocatedIndexAndUnavailableAutomation() throws {
        let command = try MailDoctor.parse(["--text"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(
                contextFactory: { throw AppleError.notFound("synthetic unreadable index") },
                directoryFactory: { AccountDirectory(runner: MailScriptInjectionTests.ThrowingMailRunner()) },
                preflightFactory: { Permissions.Preflight(full_disk_access: false, notes: []) },
                locateDBFactory: { "/tmp/synthetic-envelope-index.sqlite" })
        }

        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("Full Disk Access: false"))
        #expect(text.contains("Envelope Index found but could not be opened."))
        #expect(text.contains("Mail automation unavailable"))
    }
}
