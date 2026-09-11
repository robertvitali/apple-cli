import Foundation
import Testing
import ArgumentParser
@testable import MailKit
@testable import AppleKit
import TestSupport

enum MailLimitFailure: CaseIterable, Sendable {
    case environment, explicit, overflow

    func error(marked: Bool) -> AppleError {
        let original: AppleError
        switch self {
        case .environment: original = .outputLimitEnvironmentInvalid()
        case .explicit: original = .outputLimitExplicitInvalid()
        case .overflow: original = .outputLimitExceeded(maximumOutputBytes: 128)
        }
        if marked { return original }
        return AppleError(type: original.type, message: original.message, exitCode: original.exitCode)
    }
}

/// Each instance belongs to one test. A single ordered trace records all delivery
/// forms; phase handlers throw the intended error, never fixture exhaustion.
final class MailLimitRunner: MailAppleScriptExecuting, @unchecked Sendable {
    struct Call {
        let mode: String
        let script: String
        let arguments: [String]
    }
    var handler: (Call) throws -> String
    private(set) var calls: [Call] = []

    init(_ handler: @escaping (Call) throws -> String) { self.handler = handler }
    private func perform(_ mode: String, _ script: String, _ arguments: [String]) throws -> String {
        let call = Call(mode: mode, script: script, arguments: arguments)
        calls.append(call)
        return try handler(call)
    }
    func run(_ script: String, arguments: [String]) throws -> String {
        try perform("inline", script, arguments)
    }
    func run(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
        try perform("timed", script, arguments)
    }
    func runViaStdin(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
        try perform("stdin", script, arguments)
    }
}

struct MailLimitOutcome {
    let exit: Int32
    let envelope: [String: Any]
    let stderr: Data

    static func capture(_ body: () throws -> Void) throws -> Self {
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var exit: Int32 = 0
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
            do { try body() } catch let code as ExitCode { exit = code.rawValue }
        }
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        return Self(exit: exit, envelope: try #require(object as? [String: Any]), stderr: stderr.data)
    }

    func expectMarked(_ error: AppleError) throws {
        #expect(exit == error.exitCode)
        #expect(envelope["ok"] as? Bool == false)
        #expect(envelope["tool"] as? String == "mail")
        #expect(Set(envelope.keys) == ["schema_version", "tool", "ok", "error"])
        guard let payload = envelope["error"] as? [String: Any] else {
            Issue.record("Expected an error payload, not a degraded success")
            return // continue paired controls and later phase cases after RED
        }
        #expect(Set(payload.keys) == ["type", "message"])
        #expect(payload["type"] as? String == error.type)
        #expect(payload["message"] as? String == error.message)
        #expect(stderr.isEmpty)
    }

    func expectSuccess() {
        #expect(exit == 0)
        #expect(envelope["ok"] as? Bool == true)
        #expect(envelope["error"] == nil)
        #expect(stderr.isEmpty)
    }
}

@Suite("Mail output-limit propagation", .serialized)
struct MailOutputLimitPropagationTests {
    private let scratch = ScratchDirs("mail-output-limit")
    private let confined = ConfinedScratchDirs("mail-output-limit")

    private func directory() -> AccountDirectory {
        AccountDirectory(runner: MailLimitRunner { _ in
            [EnvelopeIndexTests.iCloudUUID, "Example Account", "imap", "true", "sender@example.com"]
                .joined(separator: MailScript.US) + MailScript.RS
        })
    }

    private func context(_ directory: AccountDirectory) throws -> MailContext {
        let path = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        return try MailContext(explicitPath: path, accountDirectory: directory)
    }

    @Test(arguments: MailLimitFailure.allCases, [true, false])
    func cachedDirectoryCannotBypassPolicyThroughKnownIndexUUID(failure: MailLimitFailure, marked: Bool) throws {
        let error = failure.error(marked: marked)
        let runner = MailLimitRunner { _ in throw error }
        let dir = AccountDirectory(runner: runner)
        let ctx = try context(dir)
        #expect(dir.loadError != nil)
        #expect(AppleScriptRunner.isOutputLimitError(try #require(dir.loadError)) == marked)
        for _ in 0..<2 {
            if marked {
                let observed = #expect(throws: AppleError.self) {
                    _ = try ctx.requireAccountUUID(EnvelopeIndexTests.iCloudUUID)
                }
                #expect(observed?.type == error.type)
                #expect(observed?.message == error.message)
                #expect(observed?.exitCode == error.exitCode)
                if let observed { #expect(AppleScriptRunner.isOutputLimitError(observed)) }
            } else {
                #expect(try ctx.requireAccountUUID(EnvelopeIndexTests.iCloudUUID) == EnvelopeIndexTests.iCloudUUID)
            }
        }
        #expect(runner.calls.count == 1) // cached failure is checked, not refetched
        // Retained legacy accessors deliberately remain best-effort.
        #expect(ctx.accounts() === dir)
        #expect(ctx.labels(forMailboxRowid: 1).account == EnvelopeIndexTests.iCloudUUID)
    }

    enum DirectoryConsumer: CaseIterable, Sendable {
        case accounts, mailboxes, list, search, get, attachments, thread, targets, reply, forward
    }

    @Test(arguments: MailLimitFailure.allCases, [true, false])
    func checkedHelpersRetainLegacyAndMissingMailboxBehavior(failure: MailLimitFailure, marked: Bool) throws {
        let error = failure.error(marked: marked)
        let runner = MailLimitRunner { _ in throw error }
        let dir = AccountDirectory(runner: runner)
        let ctx = try context(dir)
        let row = try #require(try ctx.index.message(rowid: 10))
        for _ in 0..<2 {
            for accessor in 0..<4 {
                var observed: AppleError?
                do {
                    switch accessor {
                    case 0: try dir.checkOutputLimitFailure()
                    case 1: #expect(try ctx.checkedAccounts() === dir)
                    case 2: #expect(try ctx.checkedLabels(forMailboxRowid: 1).account == EnvelopeIndexTests.iCloudUUID)
                    default: #expect(try ctx.checkedDecodeSummary(row).account == EnvelopeIndexTests.iCloudUUID)
                    }
                } catch let failure as AppleError { observed = failure }
                #expect((observed != nil) == marked)
                if let observed {
                    #expect(AppleScriptRunner.isOutputLimitError(observed))
                    #expect(observed.message == error.message)
                    #expect(observed.type == error.type)
                    #expect(observed.exitCode == error.exitCode)
                }
            }
        }
        // A nonexistent mailbox never consumes the cached directory failure.
        let missing = try ctx.checkedLabels(forMailboxRowid: -1)
        #expect(missing.path.isEmpty && missing.account.isEmpty)
        #expect(try ctx.checkedDecodeSummary(["mailbox_rowid": "-1"]).account.isEmpty)
        #expect(ctx.accounts() === dir)
        #expect(ctx.decodeSummary(row).account == EnvelopeIndexTests.iCloudUUID)
        #expect(runner.calls.count == 1)
    }

    @Test(arguments: MailLimitFailure.allCases, [true, false])
    func checkedDraftPollingStopsOnErrorAndLegacyWrapperRemainsNonthrowing(failure: MailLimitFailure, marked: Bool) throws {
        let error = failure.error(marked: marked)
        let runner = MailLimitRunner { _ in throw error }
        let script = MailScript(runner: runner)
        #expect(try script.saveOpenDraftChecked(subject: "", retries: 2, delaySeconds: 0) == false)
        #expect(runner.calls.isEmpty)
        var observed: AppleError?
        do {
            #expect(try script.saveOpenDraftChecked(subject: "Synthetic Draft", retries: 3, delaySeconds: 0) == false)
        } catch let failure as AppleError { observed = failure }
        #expect((observed != nil) == marked)
        if let observed {
            #expect(AppleScriptRunner.isOutputLimitError(observed))
            #expect(observed.message == error.message)
            #expect(observed.exitCode == error.exitCode)
        }
        #expect(runner.calls.count == 1)
        #expect(script.saveOpenDraft(subject: "Synthetic Draft", retries: 3, delaySeconds: 0) == false)
        #expect(runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { $0.arguments == ["Synthetic Draft"] })
    }

    @Test func checkedDraftRetainsSuccessfulPolling() throws {
        var attempts = 0
        let runner = MailLimitRunner { _ in
            attempts += 1
            return attempts == 1 ? "pending" : " saved\n"
        }
        #expect(try MailScript(runner: runner).saveOpenDraftChecked(subject: "Synthetic Draft", retries: 3, delaySeconds: 0))
        #expect(runner.calls.count == 2)
    }

    @Test(arguments: MailLimitFailure.allCases, DirectoryConsumer.allCases)
    func realReadCommandsCheckCachedDirectory(failure: MailLimitFailure, consumer: DirectoryConsumer) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for marked in [true, false] {
                let error = failure.error(marked: marked)
                let runner = MailLimitRunner { _ in throw error }
                let dir = AccountDirectory(runner: runner)
                let ctx = try context(dir)
                let noScript = MailLimitRunner { _ in
                    Issue.record("This indexed command must not call a live runner")
                    throw AppleError.upstream("unexpected synthetic live lookup")
                }
                let outcome = try MailLimitOutcome.capture {
                    switch consumer {
                    case .accounts:
                        try AccountsList.parse([]).run(directoryFactory: { dir })
                    case .mailboxes:
                        try MailboxesList.parse([]).run(contextFactory: { ctx })
                    case .list:
                        try ListCommand.parse(["--limit", "1", "--no-content"]).run(contextFactory: { ctx })
                    case .search:
                        try SearchCommand.parse(["--subject", "Hello", "--no-content"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) })
                    case .get:
                        try GetCommand.parse(["10", "--headers-only", "--account", EnvelopeIndexTests.iCloudUUID])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) })
                    case .attachments:
                        try AttachmentsList.parse(["10", "--no-live", "--account", EnvelopeIndexTests.iCloudUUID])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) })
                    case .thread:
                        try ThreadCommand.parse(["--subject", "Hello"])
                            .run(contextFactory: { ctx })
                    case .targets:
                        try MarkCommand.parse(["10", "--read", "--account", EnvelopeIndexTests.iCloudUUID, "--dry-run"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) })
                    case .reply:
                        try ReplyCommand.parse(["10", "--body", "Synthetic reply", "--dry-run"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { dir })
                    case .forward:
                        try ForwardCommand.parse(["10", "--to", "recipient@example.com", "--dry-run"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { dir })
                    }
                }
                if marked { try outcome.expectMarked(error) }
                else if consumer == .accounts {
                    #expect(outcome.exit == 69)
                    let payload = try #require(outcome.envelope["error"] as? [String: Any])
                    #expect(payload["message"] as? String == "could not read Mail accounts — is Mail.app available and automation permitted?")
                } else { outcome.expectSuccess() }
                #expect(runner.calls.count == 1)
                #expect(noScript.calls.isEmpty)
            }
        }
    }

    enum Fallback: CaseIterable, Sendable {
        case unread, selected, overview, dashboard, attachmentList, attachmentSavePreview, attachmentSaveExecute, trashPreview, deletePreview, exportBody
    }

    @Test(arguments: MailLimitFailure.allCases, Fallback.allCases)
    func liveFallbacksPreservePolicyButRetainOrdinaryBehavior(failure: MailLimitFailure, fallback: Fallback) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for marked in [true, false] {
                let error = failure.error(marked: marked)
                let runner = MailLimitRunner { _ in throw error }
                let ctx = try context(directory())
                let root = try confined.directory()
                let output = root.appendingPathComponent("result")
                if fallback == .attachmentSavePreview || fallback == .attachmentSaveExecute {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                }
                let outcome = try MailLimitOutcome.capture {
                    switch fallback {
                    case .unread:
                        try UnreadCountsCommand.parse([]).run(scriptFactory: { MailScript(runner: runner) }, directoryFactory: { directory() })
                    case .selected:
                        try SelectedCommand.parse([]).run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .overview:
                        try AnalyticsOverview.parse([]).run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .dashboard:
                        try AnalyticsDashboard.parse(["--out", output.path, "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .attachmentList:
                        try AttachmentsList.parse(["10"]).run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .attachmentSavePreview:
                        try AttachmentsSave.parse(["10", "--dir", output.path, "--dry-run"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .attachmentSaveExecute:
                        try AttachmentsSave.parse(["10", "--dir", output.path, "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .trashPreview:
                        try TestEnvironment.with([TrashEmpty.operatorEnvVar: nil]) {
                            try TrashEmpty.parse(["--account", "Example Account", "--dry-run"])
                                .run(scriptFactory: { MailScript(runner: runner) })
                        }
                    case .deletePreview:
                        try TestEnvironment.with([DeleteCommand.operatorEnvVar: nil]) {
                            try DeleteCommand.parse(["--match-subject", "Hello", "--permanent", "--dry-run"])
                                .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                        }
                    case .exportBody:
                        try ExportCommand.parse(["--account", "Example Account", "--scope", "single_email",
                                                 "--subject", "Hello", "--dir", output.path, "--format", "txt", "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    }
                }
                if marked {
                    try outcome.expectMarked(error)
                    if FileManager.default.fileExists(atPath: output.path) {
                        #expect((try? FileManager.default.contentsOfDirectory(atPath: output.path))?.isEmpty == true)
                    }
                } else if fallback == .attachmentSaveExecute {
                    #expect(outcome.exit == 69)
                    #expect(outcome.envelope["ok"] as? Bool == false)
                } else if fallback == .unread || fallback == .selected {
                    #expect(outcome.exit == 69)
                    let payload = try #require(outcome.envelope["error"] as? [String: Any])
                    #expect(payload["type"] as? String == "upstream_error")
                    #expect(payload["message"] as? String != error.message)
                } else {
                    outcome.expectSuccess()
                }
                #expect(runner.calls.count == 1) // no second candidate, retry, or save
            }
        }
    }

    @Test(arguments: MailLimitFailure.allCases, [true, false])
    func richDraftSaveFailureFollowsExistingWriteAndOpen(failure: MailLimitFailure, marked: Bool) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let error = failure.error(marked: marked)
            let runner = MailLimitRunner { call in
                #expect(call.arguments == ["Synthetic Draft"])
                throw error
            }
            let opener = MailScriptInjectionTests.FakeMailOpener()
            let output = try scratch.directory().appendingPathComponent("draft.eml")
            let outcome = try MailLimitOutcome.capture {
                try DraftRichCommand.parse(["--subject", "Synthetic Draft", "--text-body", "Synthetic body",
                                            "--out", output.path, "--save-as-draft", "--execute"])
                    .run(scriptFactory: { MailScript(runner: runner, opener: opener) }, directoryFactory: { directory() })
            }
            if marked { try outcome.expectMarked(error) }
            else {
                outcome.expectSuccess()
                let data = try #require(outcome.envelope["data"] as? [String: Any])
                #expect(data["saved"] as? Bool == false)
            }
            #expect(FileManager.default.fileExists(atPath: output.path))
            #expect(opener.openedPaths == [output.path])
            #expect(runner.calls.count == 1)
        }
    }

    enum DirectConsumer: CaseIterable, Sendable {
        case doctor, unreadScope, send, reply, forward, richOpen, richHeadless, draft
    }

    @Test(arguments: MailLimitFailure.allCases, DirectConsumer.allCases)
    func directFactoriesCheckBeforeSenderFallbackOrMutation(failure: MailLimitFailure, consumer: DirectConsumer) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for marked in [false, true] {
                let error = failure.error(marked: marked)
                let accountRunner = MailLimitRunner { _ in throw error }
                let failedDirectory = AccountDirectory(runner: accountRunner)
                let ctx = try context(directory())
                let noScript = MailLimitRunner { _ in
                    Issue.record("A failed account lookup must precede any Mail mutation")
                    throw AppleError.upstream("unexpected synthetic mutation")
                }
                let output = try scratch.directory().appendingPathComponent("draft.eml")
                let opener = MailScriptInjectionTests.FakeMailOpener()
                let outcome = try MailLimitOutcome.capture {
                    switch consumer {
                    case .doctor:
                        try MailDoctor.parse([]).run(contextFactory: { ctx }, directoryFactory: { failedDirectory },
                            preflightFactory: { Permissions.Preflight(full_disk_access: true, notes: []) }, locateDBFactory: { nil })
                    case .unreadScope:
                        try UnreadCountsCommand.parse(["--account", "Example Account"])
                            .run(scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { failedDirectory })
                    case .send:
                        try SendCommand.parse(["--account", "Example Account", "--to", "recipient@example.com",
                                               "--subject", "Synthetic subject", "--body", "Synthetic body", "--execute"])
                            .run(scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { failedDirectory })
                    case .reply:
                        try ReplyCommand.parse(["10", "--account", "Example Account", "--body", "Synthetic reply", "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { failedDirectory })
                    case .forward:
                        try ForwardCommand.parse(["10", "--account", "Example Account", "--to", "recipient@example.com", "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { failedDirectory })
                    case .richOpen, .richHeadless:
                        try DraftRichCommand.parse(["--account", "Example Account", "--subject", "Synthetic draft",
                            "--text-body", "Synthetic body", "--out", output.path, "--execute",
                            consumer == .richOpen ? "--open" : "--no-open"])
                            .run(scriptFactory: { MailScript(runner: noScript, opener: opener) }, directoryFactory: { failedDirectory })
                    case .draft:
                        try DraftCommand.parse(["create", "--account", "Example Account", "--subject", "Synthetic draft", "--execute"])
                            .run(scriptFactory: { MailScript(runner: noScript) }, directoryFactory: { failedDirectory })
                    }
                }
                if marked { try outcome.expectMarked(error) }
                else if consumer == .doctor || consumer == .richHeadless { outcome.expectSuccess() }
                else {
                    #expect(outcome.exit == 65)
                    let payload = try #require(outcome.envelope["error"] as? [String: Any])
                    #expect(payload["type"] as? String == "not_found")
                }
                #expect(accountRunner.calls.count == 1)
                #expect(noScript.calls.isEmpty)
                #expect(opener.openedPaths.isEmpty)
                #expect(FileManager.default.fileExists(atPath: output.path) == (!marked && consumer == .richHeadless))
            }
        }
    }

    enum Enrichment: CaseIterable, Sendable { case selected, overview, dashboard, export, template }

    @Test(arguments: MailLimitFailure.allCases, Enrichment.allCases)
    func enrichmentChecksFailedCachedDirectoryBeforeFallback(failure: MailLimitFailure, enrichment: Enrichment) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for marked in [false, true] {
                let error = failure.error(marked: marked)
                let accountRunner = MailLimitRunner { _ in throw error }
                let ctx = try context(AccountDirectory(runner: accountRunner))
                let runner = MailLimitRunner { _ in
                    if enrichment == .selected {
                        return ["synthetic-id", "<msg10@host>", "Fallback subject", "sender@example.com", "0", "1",
                                "2026-01-01T09:00:00", ""].joined(separator: MailScript.US) + MailScript.RS
                    }
                    return "Example Account\(MailScript.US)INBOX\(MailScript.US)1\(MailScript.RS)"
                }
                let output = try confined.directory().appendingPathComponent("result")
                let store = TemplateStore(homeOverride: try scratch.directory().path)
                _ = try store.save(name: "synthetic", body: "Reply to {original_subject}", subject: nil)
                var storeCalls = 0
                let outcome = try MailLimitOutcome.capture {
                    switch enrichment {
                    case .selected:
                        try SelectedCommand.parse(["--no-content"]).run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .overview:
                        try AnalyticsOverview.parse([]).run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .dashboard:
                        try AnalyticsDashboard.parse(["--out", output.path, "--execute"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .export:
                        try ExportCommand.parse(["--account", EnvelopeIndexTests.iCloudUUID, "--scope", "single_email",
                                                 "--subject", "Hello", "--dir", output.path, "--dry-run"])
                            .run(contextFactory: { ctx }, scriptFactory: { MailScript(runner: runner) })
                    case .template:
                        try TemplatesRender.parse(["synthetic", "--message-id", "10"])
                            .run(storeFactory: { storeCalls += 1; return store }, contextFactory: { ctx })
                    }
                }
                if marked { try outcome.expectMarked(error) } else { outcome.expectSuccess() }
                #expect(accountRunner.calls.count == 1)
                #expect(runner.calls.count == ((enrichment == .export || enrichment == .template) ? 0 : 1))
                if enrichment == .template { #expect(storeCalls == (marked ? 0 : 1)) }
                if marked { #expect(!FileManager.default.fileExists(atPath: output.path)) }
            }
        }
    }

    @Test func headlessRichPreviewRetainsLazyDirectoryBoundary() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            var directoryCalls = 0
            let runner = MailLimitRunner { _ in throw MailLimitFailure.overflow.error(marked: true) }
            let output = try scratch.directory().appendingPathComponent("draft.eml")
            let outcome = try MailLimitOutcome.capture {
                try DraftRichCommand.parse(["--account", "Example Account", "--subject", "Synthetic draft",
                                             "--out", output.path, "--no-open", "--dry-run"])
                    .run(scriptFactory: { MailScript(runner: runner) }, directoryFactory: {
                        directoryCalls += 1
                        return AccountDirectory(runner: runner)
                    })
            }
            outcome.expectSuccess()
            #expect(directoryCalls == 0)
            #expect(runner.calls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
}
