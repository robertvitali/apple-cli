import Foundation
import Testing
import ArgumentParser
@testable import MailKit
@testable import AppleKit
import TestSupport

@Suite("Mail output-limit rule phases", .serialized)
struct MailOutputLimitRuleTests {
    enum Phase: CaseIterable, Sendable {
        case createDisabled, createdReadback, conditionCount, matchReadback, enable, finalReadback, cleanupCount, cleanupMatch
    }

    @Test(arguments: MailLimitFailure.allCases, Phase.allCases)
    func createAndRecreateStopAtExactPolicyPhase(failure: MailLimitFailure, phase: Phase) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for recreate in [false, true] {
                for marked in [false, true] {
                    let error = failure.error(marked: marked)
                    let name = "apple-cli-test-rule"
                    var created = false
                    var postCreateLists = 0
                    var phases: [String] = []
                    let target: String
                    switch phase {
                    case .createDisabled: target = "create_disabled"
                    case .createdReadback: target = "created_readback"
                    case .conditionCount: target = "condition_count"
                    case .matchReadback: target = "match_readback"
                    case .enable: target = "enable"
                    case .finalReadback: target = "final_readback"
                    case .cleanupCount, .cleanupMatch: target = "cleanup"
                    }
                    let runner = MailLimitRunner { call in
                        let current: String
                        let response: String
                        if call.script.contains("repeat with r in rules") {
                            if created {
                                postCreateLists += 1
                                current = postCreateLists == 1 ? "created_readback" : "final_readback"
                            } else { current = "initial_list" }
                            response = created || recreate ? "1\(MailScript.US)\(name)\(MailScript.US)true\(MailScript.RS)" : ""
                        } else if call.arguments.count == 8 && call.arguments.first == name {
                            current = "create_disabled"
                            #expect(call.arguments[1] == "0")
                            created = true
                            response = "ok"
                        } else if call.script.contains("delete (rule idx)") {
                            current = created ? "cleanup" : "delete_old"
                            response = "ok"
                        } else if call.script.contains("count of rule conditions") {
                            current = "condition_count"
                            response = phase == .cleanupCount ? "0" : "1"
                        } else if call.script.contains("set ml to all conditions must be met of r") {
                            current = created ? "match_readback" : "old_scalars"
                            let match = created && phase == .cleanupMatch ? "false" : "true"
                            response = ["true", "true", "false", match, "false", name].joined(separator: MailScript.US)
                        } else if call.script.contains("set bad to {}") {
                            current = "supported_actions"
                            response = ""
                        } else if call.arguments.count == 12 {
                            current = "enable"
                            #expect(call.arguments[3] == "1")
                            #expect(call.arguments[4] == "1")
                            response = "ok"
                        } else {
                            Issue.record("Unexpected synthetic rule phase")
                            throw AppleError.upstream("unexpected synthetic rule phase")
                        }
                        phases.append(current)
                        if current == target { throw error }
                        return response
                    }
                    let outcome = try MailLimitOutcome.capture {
                        if recreate {
                            try RulesUpdate.parse(["1", "--condition", "subject:contains:apple-cli-test", "--execute"])
                                .run(scriptFactory: { MailScript(runner: runner) })
                        } else {
                            try RulesCreate.parse(["--name", name, "--condition", "subject:contains:apple-cli-test",
                                                   "--action", "mark_read=true", "--execute"])
                                .run(scriptFactory: { MailScript(runner: runner) })
                        }
                    }
                    #expect(phases.contains("create_disabled"))
                    #expect(phases.filter { $0 == target }.count == 1)
                    if marked {
                        try outcome.expectMarked(error)
                        #expect(phases.last == target) // no cleanup, lookup, or enable after failure
                        if phase == .enable || phase == .finalReadback {
                            #expect(phases.contains("enable"))
                            let payload = outcome.envelope["error"] as? [String: Any]
                            let message = payload?["message"] as? String ?? ""
                            #expect(!message.contains("NOT enabled"))
                            #expect(!message.contains("remains disabled"))
                            #expect(!message.contains("removed the malformed rule"))
                        } else {
                            #expect(!phases.contains("enable"))
                        }
                    } else if phase == .finalReadback {
                        outcome.expectSuccess() // same text without origin preserves index fallback
                        #expect(phases.last == "final_readback")
                    } else {
                        #expect(outcome.envelope["ok"] as? Bool == false)
                        #expect(outcome.exit != 0)
                        let payload = try #require(outcome.envelope["error"] as? [String: Any])
                        if phase == .cleanupCount || phase == .cleanupMatch || phase == .matchReadback
                            || (phase == .conditionCount && !recreate) {
                            #expect(phases.last == "cleanup")
                            #expect(outcome.exit == 69)
                            #expect(payload["message"] as? String != error.message)
                        } else if phase == .createDisabled && recreate {
                            #expect(outcome.exit == 69)
                            #expect((payload["message"] as? String)?.contains("the rule is GONE") == true)
                        } else if phase == .createdReadback && !recreate {
                            #expect(outcome.exit == 69)
                            #expect((payload["message"] as? String)?.contains("NOT enabled") == true)
                        } else {
                            #expect(outcome.exit == error.exitCode)
                            #expect(payload["message"] as? String == error.message)
                        }
                    }
                    #expect(runner.calls.count == phases.count)
                }
            }
        }
    }

    @Test(arguments: MailLimitFailure.allCases, [true, false])
    func supportedActionsAndRuleListKeepTheirOrdinaryMappings(failure: MailLimitFailure, marked: Bool) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let error = failure.error(marked: marked)
            let runner = MailLimitRunner { _ in throw error }
            let script = MailScript(runner: runner)
            // Avoid the nested #expect(throws:) closure at the Swift 6.3.3
            // SendNonSendable crash site; retain the same error assertions.
            var observed: AppleError?
            do {
                try script.checkSupportedActions(index: 1)
                Issue.record("Expected supported-actions verification to fail")
            } catch let error as AppleError {
                observed = error
            }
            if let observed {
                #expect(AppleScriptRunner.isOutputLimitError(observed) == marked)
                #expect(observed.exitCode == (marked ? error.exitCode : 77))
                if marked { #expect(observed.message == error.message) }
                else { #expect(observed.message.contains("refusing to update")) }
            }
            let outcome = try MailLimitOutcome.capture {
                try RulesList.parse([]).run(scriptFactory: { MailScript(runner: runner) })
            }
            if marked { try outcome.expectMarked(error) }
            else {
                #expect(outcome.exit == 69)
                let payload = try #require(outcome.envelope["error"] as? [String: Any])
                #expect((payload["message"] as? String)?.contains("could not read Mail rules") == true)
            }
            #expect(runner.calls.count == 2)
        }
    }
}
