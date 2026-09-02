import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

@Suite("Mail read commands with injected context")
struct MailReadCommandInjectionTests {
    private let scratch = ScratchDirs("mail-read-cmd")
    private func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
    }

    private func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        return try #require(object as? [String: Any])
    }

    private func context() throws -> MailContext {
        let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        let accountRunner = MailScriptInjectionTests.FakeMailRunner()
        accountRunner.untimedResults = [
            [
                EnvelopeIndexTests.iCloudUUID,
                "Example Account",
                "imap",
                "true",
                "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        return try MailContext(explicitPath: fixture, accountDirectory: AccountDirectory(runner: accountRunner))
    }

    @Test func listCommandUsesInjectedContextAndEmitsSyntheticRows() throws {
        let command = try ListCommand.parse([
            "--account", "Example Account",
            "--limit", "1",
            "--no-content",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let envelope = try payload(from: stdout)
        #expect(envelope["tool"] as? String == "mail")
        #expect(envelope["ok"] as? Bool == true)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["account"] as? String == "Example Account")
        #expect(data["mailbox"] as? String == "INBOX")
        #expect(data["count"] as? Int == 1)
        let messages = try #require(data["messages"] as? [[String: Any]])
        let first = try #require(messages.first)
        #expect(first["account"] as? String == "Example Account")
        #expect(first["mailbox"] as? String == "INBOX")
        #expect(first["snippet"] == nil)
        #expect(first["content_preview"] == nil)
    }

    @Test func listCommandUsesPerAccountWindowAndUnreadFiltering() throws {
        let command = try ListCommand.parse([
            "--limit-per-account", "2",
            "--unread",
            "--limit", "0",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["limit_per_account"] as? Int == 2)
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.map { $0["rowid"] as? Int }.contains(10))
        #expect(messages.map { $0["rowid"] as? Int }.contains(13))
    }

    @Test func searchCommandUsesInjectedContextForIndexedSearch() throws {
        let command = try SearchCommand.parse([
            "--account", "Example Account",
            "--mailbox", "All",
            "--subject", "hello",
            "--flagged",
            "--limit", "5",
            "--sort", "date_asc",
        ])
        let (streams, stdout) = streams()
        // Fail-closed: this path must not reach AppleScript, so the runner throws if touched.
        // `AttachmentsList` swallows runner errors via `try?`, so assert `neverCalled` as well
        // rather than relying on the throw alone.
        let noScript = MailScriptInjectionTests.ThrowingMailRunner()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: noScript) })
        }

        #expect(noScript.neverCalled)

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["count"] as? Int == 1)
        #expect(data["sort"] as? String == "date_asc")
        #expect(data["system_folders_excluded"] as? Bool == true)
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.first?["rowid"] as? Int == 10)
        #expect(messages.first?["account"] as? String == "Example Account")
    }

    @Test func searchCommandUsesInjectedScriptForLiveBodySearch() throws {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.timedResults = ["msg10@host\(MailScript.RS)missing@example.com\(MailScript.RS)"]
        let command = try SearchCommand.parse([
            "--account", "Example Account",
            "--mailbox", "INBOX",
            "--body", "needle",
            "--body-live",
            "--limit", "1",
            "--no-content",
            "--body-live-timeout", "12",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() },
                            scriptFactory: { MailScript(runner: fake) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["count"] as? Int == 1)
        #expect(data["has_more"] as? Bool == true)
        #expect((data["note"] as? String)?.contains("omitted") == true)
        let messages = try #require(data["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        #expect(message["rowid"] as? Int == 10)
        #expect(message["snippet"] == nil)
        #expect(fake.timedCalls.first?.timeout == 12)
        #expect(fake.timedCalls.first?.arguments[0] == "needle")
        #expect(fake.timedCalls.first?.arguments[8] == "Example Account")
    }

    @Test func getCommandUsesInjectedContextAndHeadersOnlyClearsPreview() throws {
        let command = try GetCommand.parse([
            "10",
            "--account", "Example Account",
            "--mailbox", "INBOX",
            "--headers-only",
        ])
        let (streams, stdout) = streams()
        // Fail-closed: this path must not reach AppleScript, so the runner throws if touched.
        // `AttachmentsList` swallows runner errors via `try?`, so assert `neverCalled` as well
        // rather than relying on the throw alone.
        let noScript = MailScriptInjectionTests.ThrowingMailRunner()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: noScript) })
        }

        #expect(noScript.neverCalled)

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        let message = try #require(data["message"] as? [String: Any])
        #expect(message["rowid"] as? Int == 10)
        #expect(message["account"] as? String == "Example Account")
        #expect(message["snippet"] == nil)
        #expect(message["content_preview"] == nil)
        #expect(message["content"] as? String == "")
    }

    @Test func getCommandUsesInjectedScriptForFullBodyContent() throws {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.untimedResults = ["Full synthetic body"]
        let command = try GetCommand.parse(["10", "--content"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() },
                            scriptFactory: { MailScript(runner: fake) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        let message = try #require(data["message"] as? [String: Any])
        #expect(message["content"] as? String == "Full synthetic body")
        #expect(fake.untimedArguments.first == ["<msg10@host>", "Example Account"])
    }

    @Test func getCommandTextOutputUsesInjectedContext() throws {
        let command = try GetCommand.parse(["10", "--text"])
        let (streams, stdout) = streams()
        // Fail-closed: this path must not reach AppleScript, so the runner throws if touched.
        // `AttachmentsList` swallows runner errors via `try?`, so assert `neverCalled` as well
        // rather than relying on the throw alone.
        let noScript = MailScriptInjectionTests.ThrowingMailRunner()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: noScript) })
        }

        #expect(noScript.neverCalled)

        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.contains("Hello"))
        #expect(text.contains("Example Account"))
    }

    @Test func threadCommandUsesInjectedContextForSubjectThread() throws {
        let command = try ThreadCommand.parse([
            "--subject", "Re: Hello",
            "--account", "Example Account",
            "--mailbox", "All",
            "--limit", "0",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["matched_by"] as? String == "subject_keyword")
        #expect(data["count"] as? Int == 2)
        #expect(data["has_more"] as? Bool == false)
    }

    @Test func threadCommandUsesReferencesPathAndReportsHasMore() throws {
        let command = try ThreadCommand.parse(["10", "--references", "--limit", "1"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["matched_by"] as? String == "references")
        #expect(data["count"] as? Int == 1)
        #expect(data["total"] as? Int == 2)
        #expect(data["has_more"] as? Bool == true)
    }

    @Test func attachmentsListUsesInjectedContextAndSkipsLiveLookup() throws {
        let command = try AttachmentsList.parse([
            "10",
            "--account", "Example Account",
            "--mailbox", "All",
            "--no-live",
        ])
        let (streams, stdout) = streams()
        // Fail-closed: this path must not reach AppleScript, so the runner throws if touched.
        // `AttachmentsList` swallows runner errors via `try?`, so assert `neverCalled` as well
        // rather than relying on the throw alone.
        let noScript = MailScriptInjectionTests.ThrowingMailRunner()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: noScript) })
        }

        #expect(noScript.neverCalled)

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["count"] as? Int == 1)
        #expect(data["matched_by"] as? String == "message_id")
        #expect((data["note"] as? String)?.contains("live enrichment skipped") == true)
        let attachments = try #require(data["attachments"] as? [[String: Any]])
        #expect(attachments.first?["name"] as? String == "report.pdf")
        #expect(attachments.first?["save_index"] as? Int == 0)
    }

    @Test func attachmentsListUsesInjectedScriptForLiveMetadata() throws {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.timedResults = [
            "ok" + MailScript.RS +
            [
                "report.pdf",
                "application/pdf",
                "42",
                "1",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        let command = try AttachmentsList.parse(["10"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() },
                            scriptFactory: { MailScript(runner: fake) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["note"] == nil)
        let attachments = try #require(data["attachments"] as? [[String: Any]])
        let attachment = try #require(attachments.first)
        #expect(attachment["name"] as? String == "report.pdf")
        #expect(attachment["mime_type"] as? String == "application/pdf")
        #expect(attachment["size"] as? Int == 42)
        #expect(attachment["downloaded"] as? Bool == true)
        #expect(attachment["attachment_id"] as? String == "1.2")
        #expect(attachment["save_index"] as? Int == 0)
        #expect(fake.timedCalls.first?.arguments == ["<msg10@host>", "Example Account"])
    }

    @Test func attachmentsListSubjectPathGroupsSyntheticMessages() throws {
        let command = try AttachmentsList.parse([
            "--subject", "Hello",
            "--account", "Example Account",
            "--mailbox", "All",
            "--max-results", "2",
            "--no-live",
        ])
        let (streams, stdout) = streams()
        // Fail-closed: this path must not reach AppleScript, so the runner throws if touched.
        // `AttachmentsList` swallows runner errors via `try?`, so assert `neverCalled` as well
        // rather than relying on the throw alone.
        let noScript = MailScriptInjectionTests.ThrowingMailRunner()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: noScript) })
        }

        #expect(noScript.neverCalled)

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["matched_by"] as? String == "subject_keyword")
        #expect(data["matched_email_count"] as? Int == 2)
        let emails = try #require(data["emails"] as? [[String: Any]])
        #expect(emails.count == 2)
        #expect(emails.contains { $0["attachment_count"] as? Int == 1 })
        #expect(emails.contains { $0["attachment_count"] as? Int == 0 })
    }

    @Test func selectedCommandUsesInjectedScriptAndContextEnrichment() throws {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.untimedResults = [
            [
                "apple-script-id",
                "<msg10@host>",
                "Fallback subject",
                "Fallback Sender <sender@example.com>",
                "0",
                "1",
                "2026-01-01T09:00:00",
                "Selected content",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        let command = try SelectedCommand.parse(["--no-content"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() },
                            scriptFactory: { MailScript(runner: fake) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["count"] as? Int == 1)
        let messages = try #require(data["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        #expect(message["applescript_id"] as? String == "apple-script-id")
        #expect(message["rowid"] as? Int == 10)
        #expect(message["content"] as? String == "")
        #expect(message["snippet"] == nil)
        #expect(message["content_preview"] == nil)
    }

    @Test func selectedCommandFallsBackWhenContextCannotEnrichSelection() throws {
        let fake = MailScriptInjectionTests.FakeMailRunner()
        fake.untimedResults = [
            [
                "apple-script-id",
                "",
                "Fallback subject",
                "Fallback Sender <sender@example.com>",
                "0",
                "0",
                "2026-01-01T09:00:00",
                "Selected content",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        let command = try SelectedCommand.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { throw AppleError.notFound("synthetic missing context") },
                            scriptFactory: { MailScript(runner: fake) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        let messages = try #require(data["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        #expect(message["subject"] as? String == "Fallback subject")
        #expect(message["content"] as? String == "Selected content")
        #expect(message["content_preview"] == nil)
    }
}
