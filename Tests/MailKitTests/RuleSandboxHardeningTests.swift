import Testing
import AppleKit
@testable import MailKit

/// Pins for the two BLOCKING findings from the 2026-08-19 adversarial review of the newly-wired
/// Mail rule `delete` action:
///
/// F1 — the sandbox's self-scoping invariant (a sandboxed rule is safe purely because it is
///      `--match all` + carries a test-label subject condition) was enforced through an
///      unverified, error-SWALLOWING AppleScript `set`. The AppleScript side is now fail-loud
///      (`MailScript.createRuleScript` / `updateRuleMetaScript`, not independently testable here —
///      no live Mail.app in CI); this file pins the SWIFT-side readback verification added next to
///      it (`RuleLiveGuards.matchLogicMismatch`, called from `RulesCreate.run()` and the
///      condition-replacing branch of `RulesUpdate.run()`).
///
/// F4 — the sandboxed in-place ENABLE-GATE keyed on the CURRENT command's own `--action`, so
///      splitting `rules update <n> --action delete=true` (wire) and a separate `rules enable <n>`
///      (arm) bypassed it entirely. This file pins the fix: `MailScript.readRuleScalars` now
///      reads the rule's REAL `delete message` state back, and `realDeleteEnableWarnings` (the
///      decision both `rules enable`/`rules disable` and `rules update --enabled` now call) gates
///      off that real state.
@Suite("RuleLiveGuards.matchLogicMismatch — F1 create-path match-all/any readback verification")
struct MatchLogicMismatchTests {
    @Test func firesWhenReadbackDisagreesWithRequested() {
        #expect(RuleLiveGuards.matchLogicMismatch(requested: true, readback: false) != nil)
        #expect(RuleLiveGuards.matchLogicMismatch(requested: false, readback: true) != nil)
    }

    @Test func silentWhenReadbackAgreesWithRequested() {
        #expect(RuleLiveGuards.matchLogicMismatch(requested: true, readback: true) == nil)
        #expect(RuleLiveGuards.matchLogicMismatch(requested: false, readback: false) == nil)
    }

    /// The exact scenario F1 was about: a sandboxed create REQUESTS matchAll=true (so its
    /// test-label subject condition always constrains the rule); if Mail's AppleScript silently
    /// left it match-ANY, the readback must catch that specific disagreement.
    @Test func catchesTheSandboxedSilentlyForcedToMatchAnyScenario() {
        let msg = RuleLiveGuards.matchLogicMismatch(requested: true, readback: false)
        #expect(msg != nil)
        #expect(msg?.contains("matchAll=true") == true)
        #expect(msg?.contains("matchAll=false") == true)
        #expect(msg?.contains("self-scoping") == true)
    }
}

@Suite("MailScript.parseRuleScalars — 6-field parse incl. deleteMessage (F4, review-caught 2026-08-19)")
struct ParseRuleScalarsTests {
    private func raw(en: Bool, mr: Bool, mf: Bool, ml: Bool, dm: Bool, name: String) -> String {
        [en, mr, mf, ml, dm].map { $0 ? "true" : "false" }.joined(separator: "\u{1f}") + "\u{1f}" + name
    }

    @Test func parsesAllSixFieldsIncludingDeleteMessage() throws {
        let scalars = try MailScript.parseRuleScalars(
            raw(en: true, mr: false, mf: true, ml: true, dm: true, name: "apple-cli-test-x"))
        #expect(scalars.enabled == true)
        #expect(scalars.markRead == false)
        #expect(scalars.markFlagged == true)
        #expect(scalars.matchAll == true)
        #expect(scalars.deleteMessage == true)
        #expect(scalars.name == "apple-cli-test-x")
    }

    @Test func deleteMessageFalseParsesFalse() throws {
        let scalars = try MailScript.parseRuleScalars(
            raw(en: false, mr: false, mf: false, ml: false, dm: false, name: "x"))
        #expect(scalars.deleteMessage == false)
    }

    /// NAME IS LAST specifically so a name that itself contains the US delimiter still round-trips
    /// (the trailing fields are rejoined). Pins that the field-count bump (5→6, inserting
    /// `deleteMessage` BEFORE the name) kept the rejoin-from-index-5 slicing correct instead of
    /// truncating at the first embedded US or shifting the field boundary by one.
    @Test func nameContainingUnitSeparatorRoundTrips() throws {
        let weirdName = "apple-cli-test\u{1f}weird"
        let scalars = try MailScript.parseRuleScalars(
            raw(en: true, mr: false, mf: false, ml: true, dm: false, name: weirdName))
        #expect(scalars.name == weirdName)
    }

    @Test func tooFewFieldsThrows() {
        #expect(throws: Error.self) {
            _ = try MailScript.parseRuleScalars("true\u{1f}false\u{1f}false\u{1f}true") // only 4 fields
        }
    }
}

@Suite("realDeleteEnableWarnings — the two-command bypass gate (F4, review-caught 2026-08-19)")
struct RealDeleteEnableWarningsTests {
    private func rule(index: Int = 7, name: String = "apple-cli-test-mailbomb") -> MailScript.ScriptRule {
        MailScript.ScriptRule(index: index, name: name, enabled: false)
    }

    /// THE bypass, reproduced directly at the decision level: `rules update <n> --action
    /// delete=true` (a SEPARATE, prior command) leaves the rule's REAL on-disk state carrying
    /// delete; a later `rules enable <n>` (or `rules update <n> --enabled`, no --action at all)
    /// must still refuse — even though THIS call carries no --action to trip the older,
    /// same-command-only `armsRelocatingOrDestructiveAction` gate.
    @Test func sandboxedRefusesWhenRealStateAlreadyCarriesDelete() {
        do {
            _ = try realDeleteEnableWarnings(target: rule(), realDeleteMessage: true, enabling: true, sandboxActive: true)
            Issue.record("expected a mailSafety refusal")
        } catch let e as AppleError {
            #expect(e.type == AppleErrorType.safetyViolation)
            #expect(e.sandbox == true)
            #expect(e.exitCode == AppleExit.permissionDenied)
            #expect(e.message.contains("already carries a live delete action"))
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }

    @Test func unsandboxedWarnsInsteadOfRefusing() throws {
        let warnings = try realDeleteEnableWarnings(target: rule(name: "real-rule"), realDeleteMessage: true,
                                                     enabling: true, sandboxActive: false)
        #expect(warnings == [RuleLiveGuards.deleteActionWarning])
    }

    @Test func noRealDeleteMeansNoWarningAndNoRefusalEvenSandboxed() throws {
        let warnings = try realDeleteEnableWarnings(target: rule(), realDeleteMessage: false,
                                                     enabling: true, sandboxActive: true)
        #expect(warnings.isEmpty)
    }

    /// Disabling a rule only ever REDUCES what it can do — the gate is a no-op regardless of the
    /// rule's real delete state, sandboxed or not.
    @Test func disablingNeverRefusesOrWarnsRegardlessOfRealState() throws {
        for sandboxActive in [true, false] {
            let warnings = try realDeleteEnableWarnings(target: rule(), realDeleteMessage: true,
                                                         enabling: false, sandboxActive: sandboxActive)
            #expect(warnings.isEmpty)
        }
    }
}
