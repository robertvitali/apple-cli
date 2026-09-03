import Foundation
import Testing
import TestSupport

// MARK: - The operator-shell detector

/// THE ambient write-posture canary for the whole test process — one copy, here, because the
/// property it asserts belongs to the PROCESS and not to any domain.
///
/// Every write-posture assertion in the tree (Calendar, Reminders, Mail, Messages) now runs inside
/// a `TestEnvironment` window that pins `APPLE_TEST_MODE` / `APPLE_TEST_SANDBOX` /
/// `APPLE_TEST_RECIPIENTS` / `APPLE_DRY_RUN` absent, so none of those suites depends on a clean
/// ambient environment any more. That robustness has a cost: with `APPLE_DRY_RUN=1` exported the
/// whole tree goes green while the operator's real `apple` invocations preview instead of
/// executing, and nothing says so. This test is that missing signal — a report on the shell the
/// tests were run from, not a dependency of any pin.
///
/// It lives in `AppleKitTests` rather than being duplicated per domain because the assertion is
/// byte-identical wherever it sits: a per-domain copy is N places to update and N failures for one
/// exported variable, saying the same thing N times.
///
/// It reads `AmbientEnvironment.atStartup`, NEVER `getenv`. A `getenv` canary is unmaskable only
/// when it happens to run outside every window, which no test can guarantee in a concurrent suite
/// — inside a window it would read the PIN and pass no matter what the operator exported, i.e. the
/// check would quietly stop checking. The snapshot is captured before any window can exist
/// (`TestEnvironment.with` forces it), so no window can mask it.
///
/// Expected to FAIL under `APPLE_DRY_RUN=1 swift test`, and — measured on the full unfiltered
/// tree, under both `APPLE_DRY_RUN=1` and the fail-loud `APPLE_DRY_RUN=junk` — to be the ONLY
/// failure: every suite that resolves a write posture does so inside a pin, so the pins absorb the
/// export and this canary alone reports it.
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
/// POSTURE the operator is carrying, one `export` away from a value, and the remedy each advice
/// branch prints (unset it, or prefix the individual command) resolves the empty case exactly as it
/// resolves the set one. Keep the strict form; loosening it to `?.isEmpty != false` would make the
/// canary silent for half the shapes it exists to report.
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
    private func advice(for key: String) -> String {
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
            #expect(AmbientEnvironment.atStartup[key] == nil,
                    Comment(rawValue: advice(for: key)))
        }
    }
}
