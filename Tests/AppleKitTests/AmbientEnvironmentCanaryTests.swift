import Foundation
import Testing
import TestSupport

// MARK: - The operator-shell detector

/// The ambient write-posture canary for one test process. Each sharded worker has its own
/// snapshot and lock; workers that exclude AppleKitTests have no canary. A sole-reporter result
/// in one process says nothing about other workers' environments or pin coverage.
///
/// Every write-posture assertion in the tree (Calendar, Reminders, Mail, Messages) now runs inside
/// a `TestEnvironment` window that pins `APPLE_TEST_MODE` / `APPLE_TEST_SANDBOX` /
/// `APPLE_TEST_RECIPIENTS` / `APPLE_DRY_RUN` absent, so none of those suites depends on a clean
/// ambient environment any more. That robustness has a cost: with `APPLE_DRY_RUN=1` exported the
/// whole tree goes green while the operator's real `apple` invocations preview instead of
/// executing, and nothing says so. This test reports the first-touch ambient snapshot; its
/// fidelity to the inherited shell requires no raw mutation before that capture.
///
/// It lives in `AppleKitTests` rather than being duplicated per domain because the assertion is
/// byte-identical wherever it sits: a per-domain copy is N places to update and N failures for one
/// exported variable, saying the same thing N times.
///
/// It reads `AmbientEnvironment.atStartup`, NEVER `getenv`. A `getenv` canary is unmaskable only
/// when it happens to run outside every window, which no test can guarantee in a concurrent suite
/// — inside a window it would read the PIN and pass no matter what the operator exported, i.e. the
/// check would quietly stop checking. Despite its name, `atStartup` initializes lazily on first
/// touch, not at OS process startup. `TestEnvironment.with` forces it before this process's first
/// managed window opens, so those windows cannot mask it. Raw mutation before first touch can
/// already have replaced inherited values; raw mutation afterward can desynchronize the live table.
///
/// Expected to FAIL under `APPLE_DRY_RUN=1 swift test`, and — measured on the full unfiltered
/// tree, under both `APPLE_DRY_RUN=1` and the fail-loud `APPLE_DRY_RUN=junk` — to be the ONLY
/// failure in that process: the measured suites' pins absorb the export and this canary reports
/// it. That observation does not prove future tests or separately filtered/sharded workers are pinned.
///
/// Two readers used to fail alongside it and no longer do, which is worth knowing because a
/// regression in either would look like this canary "gaining" a companion rather than like a lost
/// pin: `NotesKitTests/GuardAndParsingTests.cleanEnvironment` now makes its assertion INSIDE the
/// window the rest of that suite pins with, and `WriteModelV2CoreTests.defaultEnvVarIsTheRealOne`
/// now compares inside `TestEnvironment.withoutWriteModeOverrides` (unpinned, junk values made its
/// `TestMode` reads throw before the comparison ran). If either drops its window, it starts
/// failing again — that is a lost pin in that suite, not a fault here.
///
/// The assertion below is `== nil`, NOT "nil or empty", deliberately. All four variables are inert
/// when exported empty, so an empty export is not a behavior defect — but it is still a shell
/// POSTURE the operator is carrying, one `export` away from a value. The empty case gets its own
/// diagnosis (this variable is inert by itself; unset it) rather than the set case's ("silently
/// previewing"), which would be false for it — and it says nothing about the other variables,
/// each of which gets its own line. Keep the strict form; loosening it to `?.isEmpty != false` would make the canary
/// silent for half the shapes it exists to report.
@Suite("Ambient write-posture canary")
struct AmbientEnvironmentCanaryTests {
    /// Where the advice sends the reader for the standing rule. Appended to every branch so no
    /// remediation is a dead end.
    private static let seeAgents = " — see AGENTS.md \"Toolchain + testing\"."

    /// The per-command shape for each sandbox variable. Naming the variable that actually fired
    /// matters: it reproduces the operator's intent and clears their session-wide export. But
    /// `APPLE_TEST_SANDBOX` and `APPLE_TEST_RECIPIENTS` only CONFIGURE the sandbox (label prefix /
    /// recipient allowlist) — they do NOT engage it; that takes `APPLE_TEST_MODE=1`. So the
    /// sandbox-config examples ride WITH `APPLE_TEST_MODE=1`; printing `APPLE_TEST_SANDBOX=<prefix>
    /// apple …` alone would tell the reader to run a default-LIVE write with no label or recipient
    /// restriction — the exact hazard this canary exists to prevent.
    private func perCommandExample(for key: String) -> String {
        switch key {
        case "APPLE_TEST_SANDBOX": return "APPLE_TEST_MODE=1 APPLE_TEST_SANDBOX=<prefix> apple …"
        case "APPLE_TEST_RECIPIENTS": return "APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS=<list> apple …"
        // A preview example, never a sandbox one: `APPLE_TEST_MODE=1` restricts WHAT a write may
        // touch while the write still executes, which is the opposite of what a reader carrying
        // an `APPLE_DRY_RUN` posture means.
        case "APPLE_DRY_RUN": return "APPLE_DRY_RUN=1 apple …"
        default: return "APPLE_TEST_MODE=1 apple …"
        }
    }

    /// Remediation differs by variable, and telling an agent the wrong one is worse than silence.
    /// `APPLE_DRY_RUN` exported is a pure defect for the operator — their writes silently preview
    /// — but the remedy is NOT for an agent to unset it: an agent that clears the operator's
    /// preview-by-default posture converts every subsequent write from a preview into a real
    /// mutation, which is the strictly worse failure. So that branch says REPORT, do not unset.
    /// The sandbox trio is different again: the sandbox is the default posture every agent is told
    /// to work in, so the advice is to keep engaging it, just per command rather than by export.
    /// Never tell an agent to disarm its sandbox.
    private func advice(for key: String, value: String) -> String {
        // An EMPTY export is inert: `TestMode.truthyEnv` treats `""` as unset, so THIS variable
        // changes nothing. The posture is still reported (see the suite doc), but the diagnosis
        // must claim only what the empty value does — telling an agent that writes are "silently
        // previewing" when they may be executing live is the inverse of the truth. It also must
        // not claim what the OTHER variables are doing: with `APPLE_DRY_RUN=` and
        // `APPLE_TEST_MODE=1` both exported, the sandbox IS engaged; each variable gets its own
        // report line, so the empty one speaks for itself alone.
        if value.isEmpty {
            return "\(key) is exported EMPTY in the shell running the tests. An empty value is "
                + "inert — `apple` treats \(key) as unset, so this variable has no effect by itself "
                + "— but it is a shell posture one `export` away from a value. Unset it "
                + "(`unset \(key)`) and set the variable per command when you mean it "
                + "(`\(perCommandExample(for: key))`)"
                + Self.seeAgents
        }
        if key == "APPLE_DRY_RUN" {
            return "APPLE_DRY_RUN is exported in the shell running the tests. The pins make the "
                + "suite immune to it, but your real `apple` runs are NOT — every write you issue "
                + "is silently previewing instead of executing. If you are an AGENT, REPORT this "
                + "and do not unset it: removing it turns the operator's previews into real "
                + "writes. The operator unsets it when they intend writes to execute"
                + Self.seeAgents
        }
        return "\(key) is exported in the shell running the tests. The pins make the suite immune "
            + "to it, but a session-wide export is the wrong shape: set it per command "
            + "(`\(perCommandExample(for: key))`) so the sandbox applies exactly where you intend. "
            + "An export also skews these tests' view of the ambient process"
            + Self.seeAgents
    }

    @Test("ambient canary: the operator's shell exported no write-posture variable")
    func ambientEnvironmentCarriesNoWritePostureOverride() {
        for key in TestEnvironment.writeModeVariables {
            let value = AmbientEnvironment.atStartup[key]
            #expect(value == nil, Comment(rawValue: advice(for: key, value: value ?? "")))
        }
    }

    /// The three diagnoses are distinct claims about the operator's shell, and each must say
    /// only what is true of its case: an empty export is inert (not "previewing"), a set
    /// `APPLE_DRY_RUN` is a preview posture an agent must REPORT rather than unset, and a set
    /// sandbox variable is a per-command shape. Pinned here because the advice is the payload —
    /// the assertion above never fails on a clean shell, so nothing else reads these strings.
    @Test("the advice names the case it diagnoses: empty is inert, set is previewing")
    func adviceMatchesTheExportedShape() {
        let empty = advice(for: "APPLE_DRY_RUN", value: "")
        #expect(empty.contains("exported EMPTY"))
        #expect(empty.contains("no effect by itself"))
        #expect(!empty.contains("previewing"), "the empty case says nothing about previewing")
        #expect(empty.contains("unset APPLE_DRY_RUN"))
        // The per-command example for a dry-run posture is a PREVIEW, never a sandbox execute.
        #expect(empty.contains("APPLE_DRY_RUN=1 apple"))
        #expect(!empty.contains("APPLE_TEST_MODE=1"))

        let set = advice(for: "APPLE_DRY_RUN", value: "1")
        #expect(set.contains("silently previewing"))
        #expect(set.contains("do not unset it"))

        let sandbox = advice(for: "APPLE_TEST_SANDBOX", value: "x")
        #expect(sandbox.contains("APPLE_TEST_MODE=1 APPLE_TEST_SANDBOX=<prefix> apple"))
        let emptySandbox = advice(for: "APPLE_TEST_SANDBOX", value: "")
        #expect(emptySandbox.contains("no effect by itself"))
        // …and it does not speak for the other variables (APPLE_TEST_MODE=1 may be exported too).
        #expect(!emptySandbox.contains("NOT engaged"))
    }
}
