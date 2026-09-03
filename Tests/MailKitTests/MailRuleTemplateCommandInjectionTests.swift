import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

// EVERY test in this suite runs inside `TestEnvironment.withoutWriteModeOverrides`. These commands
// consult the sandbox through the process environment (`TestMode.sandboxActive` /
// `TestMode.sandboxPrefix` / `TestMode.allowedRecipients`), so a test standing outside a window
// asserts against whatever another suite's open window — or the operator's shell — happens to
// hold. That is not hypothetical: this suite failed 17 of 20 full runs against
// `MailWriteSafetyTests`'s `APPLE_TEST_SANDBOX=qa-fixture` window. Uniform, not case-by-case, so
// the invariant is greppable: one `withoutWriteModeOverrides` per `@Test`.
//
// The pin covers `APPLE_DRY_RUN` as well as the sandbox trio, because every write command here
// first runs `TestMode.validateWriteEnvironment()`, which REFUSES a non-truthy `APPLE_DRY_RUN`
// with exit 64 — so an operator's `APPLE_DRY_RUN=junk` export failed these tests on a validation
// error before they reached the branch under test, and a truthy `APPLE_DRY_RUN=1` would have
// silently turned every `--execute` assertion into a preview.
// `.serialized` pairs with those windows: `TestEnvironment`'s process-wide lock makes each window
// atomic against OTHER suites, and `.serialized` keeps this suite from queueing on itself.
@Suite("Mail rule/template commands with injected dependencies", .serialized)
struct MailRuleTemplateCommandInjectionTests {
    private let scratch = ScratchDirs("mail-rule-template-cmd")
    private func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
    }

    private func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        return try #require(object as? [String: Any])
    }

    private func scriptWithRuleList() -> MailScript {
        let runner = MailScriptInjectionTests.FakeMailRunner()
        runner.untimedResults = ["1\(MailScript.US)apple-cli-test-rule\(MailScript.US)false\(MailScript.RS)"]
        return MailScript(runner: runner)
    }

    private func ruleList(_ name: String = "apple-cli-test-rule", enabled: Bool = false, index: Int = 1) -> String {
        "\(index)\(MailScript.US)\(name)\(MailScript.US)\(enabled ? "true" : "false")\(MailScript.RS)"
    }

    private func ruleScalars(_ name: String = "apple-cli-test-rule",
                             enabled: Bool = false,
                             markRead: Bool = true,
                             markFlagged: Bool = false,
                             matchAll: Bool = true,
                             deleteMessage: Bool = false) -> String {
        [
            enabled ? "true" : "false",
            markRead ? "true" : "false",
            markFlagged ? "true" : "false",
            matchAll ? "true" : "false",
            deleteMessage ? "true" : "false",
            name,
        ].joined(separator: MailScript.US)
    }

    /// The store WRITES template files under `homeOverride`, so this used to leave a directory
    /// tree behind on every run — the exact leak `ScratchDirs` exists to stop. The suite instance
    /// owns the reclaim now (swift-testing builds a fresh one per test).
    private func templateStore() throws -> TemplateStore {
        TemplateStore(homeOverride: try scratch.directory().path)
    }

    @Test func rulesListUsesInjectedScript() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try RulesList.parse([])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { scriptWithRuleList() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["count"] as? Int == 1)
            let rules = try #require(data["rules"] as? [[String: Any]])
            #expect(rules.first?["name"] as? String == "apple-cli-test-rule")
        }
    }

    @Test func rulesCreateDryRunDoesNotReadLiveRules() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try RulesCreate.parse([
                "--name", "apple-cli-test-rule",
                "--condition", "subject:contains:apple-cli-test",
                "--action", "mark_read=true",
                "--dry-run",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { scriptWithRuleList() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["live_blockers"] is [String])
            let rule = try #require(data["rule"] as? [String: Any])
            #expect(rule["name"] as? String == "apple-cli-test-rule")
        }
    }

    @Test func rulesCreateExecuteUsesInjectedScriptAndVerifiesDisabledRule() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                "",
                "ok",
                ruleList("apple-cli-test-created", enabled: false, index: 1),
                "1",
                ruleScalars("apple-cli-test-created", enabled: false, markRead: true, matchAll: true),
                ruleList("apple-cli-test-created", enabled: false, index: 1),
            ]
            let command = try RulesCreate.parse([
                "--name", "apple-cli-test-created",
                "--condition", "subject:contains:apple-cli-test",
                "--action", "mark_read=true",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["rule_index"] as? Int == 1)
            #expect(data["name"] as? String == "apple-cli-test-created")
            #expect(data["enabled"] as? Bool == false)
            #expect(data["match_logic"] as? String == "all")
            #expect(fake.untimedArguments.count == 6)
        }
    }

    @Test func rulesCreateDryRunReportsSandboxBlockers() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try RulesCreate.parse([
                "--name", "real-rule",
                "--condition", "from:contains:sender@example.com",
                "--action", "mark_read=true",
                "--match", "any",
                "--dry-run",
                "--test-mode",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { scriptWithRuleList() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            let blockers = try #require(data["live_blockers"] as? [String])
            #expect(blockers.contains { $0.contains("--match any") })
            #expect(blockers.contains { $0.contains("--name must start") })
            #expect(blockers.contains { $0.contains("self-scoped") || $0.contains("subject condition") })
        }
    }

    @Test func templateCommandsUseInjectedStore() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let store = try templateStore()
            let save = try TemplatesSave.parse([
                "reply",
                "--subject", "Hello {recipient_name}",
                "--body", "Body for {recipient_name}",
                "--execute",
            ])
            let list = try TemplatesList.parse([])
            let get = try TemplatesGet.parse(["reply"])
            let render = try TemplatesRender.parse(["reply", "--var", "recipient_name=Alice"])
            let delete = try TemplatesDelete.parse(["reply", "--dry-run"])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try save.run(storeFactory: { store })
                try list.run(storeFactory: { store })
                try get.run(storeFactory: { store })
                try render.run(storeFactory: { store }, contextFactory: { throw AppleError.notFound("unused") })
                try delete.run(storeFactory: { store })
            }

            let decoded = String(decoding: stdout.data, as: UTF8.self)
            #expect(decoded.contains("\"name\" : \"reply\""))
            #expect(decoded.contains("\"count\" : 1"))
            #expect(decoded.contains("Hello Alice"))
            #expect(decoded.contains("\"would_delete_template\" : \"reply\""))
        }
    }

    @Test func rulesUpdateExecuteMetadataPathUsesInjectedScript() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                ruleList(),
                "",
                "ok",
            ]
            let command = try RulesUpdate.parse([
                "1",
                "--name", "apple-cli-test-renamed",
                "--action", "mark_read=true",
                "--execute",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["recreated"] as? Bool == false)
            #expect(data["rule_index"] as? Int == 1)
            #expect(data["name"] as? String == "apple-cli-test-renamed")
            #expect(fake.untimedArguments.count == 3)
            #expect(fake.untimedArguments.last?.first == "1")
        }
    }

    @Test func rulesUpdateExecuteConditionRecreateUsesInjectedScript() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                ruleList(),
                "",
                ruleScalars(),
                ruleList(),
                "ok",
                "ok",
                ruleList("apple-cli-test-rule"),
                "1",
                ruleScalars(),
                ruleList("apple-cli-test-rule"),
            ]
            let command = try RulesUpdate.parse([
                "1",
                "--condition", "subject:contains:apple-cli-test",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["recreated"] as? Bool == true)
            #expect(data["previous_index"] as? Int == 1)
            #expect(data["conditions_attached"] as? Int == 1)
            #expect(data["match_logic"] as? String == "all")
            #expect(data["actions"] as? [String] == ["mark_read"])
        }
    }

    @Test func rulesUpdateDryRunReportsRecreateBlockersAndWarningsWithoutLiveMail() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try RulesUpdate.parse([
                "1",
                "--name", "real-rule",
                "--condition", "from:contains:sender@example.com",
                "--action", "forward_to=forward@example.com",
                "--action", "delete=true",
                "--match", "any",
                "--enabled",
                "--dry-run",
                "--test-mode",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { scriptWithRuleList() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["would_recreate"] as? Bool == true)
            let blockers = try #require(data["live_blockers"] as? [String])
            #expect(blockers.contains { $0.contains("forward_to") })
            #expect(blockers.contains { $0.contains("--match any") })
            #expect(blockers.contains { $0.contains("--name must keep") })
            #expect(blockers.contains { $0.contains("subject condition") })
            let warnings = try #require(data["warnings"] as? [String])
            #expect(warnings.contains { $0.contains("delete action") || $0.contains("auto-trash") })
            #expect((data["note"] as? String)?.contains("preview only") == true)
        }
    }

    @Test func rulesUpdateDryRunTextReportsInPlaceWithoutLiveMail() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try RulesUpdate.parse([
                "1",
                "--name", "apple-cli-test-renamed",
                "--dry-run",
                "--test-mode",
                "--text",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { scriptWithRuleList() })
            }

            let output = String(decoding: stdout.data, as: UTF8.self)
            #expect(output.contains("Would update rule 1"))
            #expect(output.contains("in-place"))
        }
    }

    @Test func rulesDeleteExecuteUsesInjectedScript() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                ruleList(),
                "ok",
            ]
            let command = try RulesDelete.parse(["1", "--execute"])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["deleted_rule_index"] as? Int == 1)
            #expect(data["deleted_name"] as? String == "apple-cli-test-rule")
        }
    }

    @Test func templatesDeleteExecuteUsesInjectedStore() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let store = try templateStore()
            _ = try store.save(name: "cleanup", body: "Body", subject: nil)
            let command = try TemplatesDelete.parse(["cleanup", "--execute"])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(storeFactory: { store })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["deleted_template"] as? String == "cleanup")
            #expect(data["name"] as? String == "cleanup")
            #expect(data["executed"] as? Bool == true)
            #expect(data["dry_run"] as? Bool == false)
        }
    }

    @Test func rulesEnableDisableExecuteUseInjectedScript() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let enableRunner = MailScriptInjectionTests.FakeMailRunner()
            enableRunner.untimedResults = [
                ruleList(),
                ruleScalars(markRead: false),
                "ok",
            ]
            let enable = try RulesEnable.parse(["1", "--execute"])
            let (enableStreams, enableStdout) = streams()
            try Output.withStreams(enableStreams) {
                try enable.run(scriptFactory: { MailScript(runner: enableRunner) })
            }
            let enableData = try #require(try payload(from: enableStdout)["data"] as? [String: Any])
            #expect(enableData["executed"] as? Bool == true)
            #expect(enableData["enabled"] as? Bool == true)

            let disableRunner = MailScriptInjectionTests.FakeMailRunner()
            disableRunner.untimedResults = [
                ruleList(enabled: true),
                "ok",
            ]
            let disable = try RulesDisable.parse(["1", "--execute"])
            let (disableStreams, disableStdout) = streams()
            try Output.withStreams(disableStreams) {
                try disable.run(scriptFactory: { MailScript(runner: disableRunner) })
            }
            let disableData = try #require(try payload(from: disableStdout)["data"] as? [String: Any])
            #expect(disableData["executed"] as? Bool == true)
            #expect(disableData["enabled"] as? Bool == false)
        }
    }
}
