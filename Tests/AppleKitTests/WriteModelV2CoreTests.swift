import Testing
import Foundation
import ArgumentParser
import TestSupport
@testable import AppleKit

/// Write-model v2 core machinery (docs/write-model-v2.md). Most of this exercises the PURE cores
/// (`parseTruthy`, `resolveExecute`, `encodeSuccess`); the handful of tests that must prove the
/// env-reading wrappers really read the environment do it through `TestEnvironment` windows.
///
/// Raw `setenv`/`unsetenv` is banned here, even on a test-owned variable name. It escapes the
/// process-wide lock every other suite's window takes, so a mutation lands mid-window elsewhere
/// and the restore is not atomic against it. The reader that took the ambient value — rather than
/// a pinned one — is also why `defaultEnvVarIsTheRealOne` used to fail outright when the operator
/// had `APPLE_DRY_RUN` exported: it asserted on the live variable with nothing holding it.
///
/// `.serialized` per `TestEnvironment`'s own instruction: these windows mutate the real
/// environment table, and serializing the suite keeps each one atomic within it.
@Suite("Write-model v2 core — fail-loud env, execute precedence, sandbox envelope", .serialized)
struct WriteModelV2CoreTests {

    // MARK: fail-loud truthy env parsing

    @Test("unset and empty are false")
    func truthyAbsent() throws {
        #expect(try TestMode.parseTruthy(name: "X", raw: nil) == false)
        #expect(try TestMode.parseTruthy(name: "X", raw: "") == false)
    }

    @Test("the three truthy spellings parse true, case-insensitively")
    func truthySpellings() throws {
        for v in ["1", "true", "TRUE", "True", "yes", "YES", "yEs"] {
            #expect(try TestMode.parseTruthy(name: "X", raw: v) == true, "\(v)")
        }
    }

    @Test("ANY other non-empty value refuses with validation_error / exit 64 — never a guess")
    func truthyRejectsEverythingElse() {
        // Deliberately includes falsy-looking spellings: you disable by UNSETTING. A typo'd
        // APPLE_TEST_MODE must refuse the write, not silently run it live; APPLE_DRY_RUN=off
        // must not silently mean "not dry-run".
        for v in ["0", "false", "no", "off", "on", "2", "ture", "yes ", " 1", "enabled"] {
            do {
                _ = try TestMode.parseTruthy(name: "APPLE_TEST_MODE", raw: v)
                Issue.record("accepted \(String(reflecting: v))")
            } catch let e as AppleError {
                #expect(e.type == AppleErrorType.validation)
                #expect(e.exitCode == AppleExit.usage)
                #expect(e.message.contains("APPLE_TEST_MODE"))
            } catch {
                Issue.record("wrong error type for \(String(reflecting: v)): \(error)")
            }
        }
    }

    // MARK: execute precedence (bind-once resolution)

    @Test("--dry-run always wins, over --execute, env, and default")
    func dryRunFlagWins() {
        for execute in [false, true] {
            for env in [false, true] {
                for dflt in [false, true] {
                    #expect(GlobalOptions.resolveExecute(dryRunFlag: true, executeFlag: execute,
                                                         envDryRun: env, defaultDryRun: dflt) == false)
                }
            }
        }
    }

    @Test("--execute beats APPLE_DRY_RUN and the surface default")
    func executeBeatsEnvAndDefault() {
        for env in [false, true] {
            for dflt in [false, true] {
                #expect(GlobalOptions.resolveExecute(dryRunFlag: false, executeFlag: true,
                                                     envDryRun: env, defaultDryRun: dflt) == true)
            }
        }
    }

    @Test("APPLE_DRY_RUN beats the surface default")
    func envBeatsDefault() {
        for dflt in [false, true] {
            #expect(GlobalOptions.resolveExecute(dryRunFlag: false, executeFlag: false,
                                                 envDryRun: true, defaultDryRun: dflt) == false)
        }
    }

    @Test("flagless + no env: general writes execute; the trash surface stays dry-run")
    func surfaceDefaults() {
        #expect(GlobalOptions.resolveExecute(dryRunFlag: false, executeFlag: false,
                                             envDryRun: false, defaultDryRun: false) == true)
        #expect(GlobalOptions.resolveExecute(dryRunFlag: false, executeFlag: false,
                                             envDryRun: false, defaultDryRun: true) == false)
    }

    // MARK: sandbox envelope key

    private struct P: Encodable { let x: Int }

    @Test("sandboxActive: true emits the key; false AND default both omit it byte-identically")
    func sandboxKeyPresence() throws {
        let with = String(decoding: try Output.encodeSuccess(tool: "mail", data: P(x: 1), sandboxActive: true),
                          as: UTF8.self)
        #expect(with.contains("\"sandbox\" : true"))
        let legacyShape = """
        {
          "data" : {
            "x" : 1
          },
          "ok" : true,
          "schema_version" : 1,
          "tool" : "mail"
        }
        """
        // The API must be unable to express `"sandbox": false` — an explicit false and the
        // default must BOTH produce the exact pre-v2 envelope.
        let dflt = String(decoding: try Output.encodeSuccess(tool: "mail", data: P(x: 1)), as: UTF8.self)
        let explicitFalse = String(decoding: try Output.encodeSuccess(tool: "mail", data: P(x: 1),
                                                                      sandboxActive: false), as: UTF8.self)
        #expect(dflt == legacyShape)
        #expect(explicitFalse == legacyShape)
    }

    // MARK: throwing env readers (the fail-loud contract is carried by the signature)

    @Test("truthyEnv reads the live environment: unset false, truthy true, junk throws")
    func truthyEnvLive() throws {
        let name = "APPLE_CLI_TEST_TRUTHY_UNIQ" // unique to this test — no parallel-suite races
        // The reads are hoisted OUT of the windows because `#expect`'s expansion cannot carry a
        // `try` across a closure boundary the compiler infers as non-throwing. Each window still
        // encloses the whole read; only the assertion happens after it closes.
        #expect(try TestEnvironment.with([name: String?.none]) {
            try TestMode.truthyEnv(name)
        } == false)
        #expect(try TestEnvironment.with([name: "yes"]) {
            try TestMode.truthyEnv(name)
        } == true)
        TestEnvironment.with([name: "maybe"]) {
            #expect(throws: AppleError.self) { _ = try TestMode.truthyEnv(name) }
        }
    }

    @Test("willExecute(defaultDryRun:) THROWS on an unparseable APPLE_DRY_RUN — never silent-execute")
    func willExecuteThrowsOnJunkEnv() throws {
        // Owns a UNIQUE variable via the `envVar:` seam, like `truthyEnvLive` above.
        //
        // This test used to setenv the REAL APPLE_DRY_RUN, justified by "nothing else in the
        // swift tier reads it (domains are pre-flip)". The Contacts flip falsified that:
        // `resolveWrite` calls `willExecute`, so ContactsKit's posture suite became a live
        // reader and this test's global mutation raced it — a real 6-in-12 red rate on the
        // full parallel run. Every future domain flip adds another reader, so the seam (not a
        // comment asserting exclusivity) is what keeps this correct.
        let name = "APPLE_CLI_TEST_DRYRUN_UNIQ"
        let g = try GlobalOptions.parse([])
        let e = try GlobalOptions.parse(["--execute"])
        #expect(try TestEnvironment.with([name: String?.none]) {
            try g.willExecute(defaultDryRun: false, envVar: name)
        } == true)
        #expect(try TestEnvironment.with([name: "1"]) {
            try g.willExecute(defaultDryRun: false, envVar: name)
        } == false)
        TestEnvironment.with([name: "ture"]) {
            #expect(throws: AppleError.self) {
                _ = try g.willExecute(defaultDryRun: false, envVar: name)
            }
            // --execute with junk env still throws (validation precedes precedence).
            #expect(throws: AppleError.self) {
                _ = try e.willExecute(defaultDryRun: false, envVar: name)
            }
        }
    }

    @Test("the default envVar IS the real APPLE_DRY_RUN (the seam cannot silently re-point production)")
    func defaultEnvVarIsTheRealOne() throws {
        // The seam above is only safe if the DEFAULT still reads the documented variable —
        // otherwise every production caller would silently consult a test-only name. An explicit
        // `envVar: TestMode.dryRunVar` and the defaulted call must agree, and TestMode.dryRunVar
        // must be the documented spelling.
        //
        // Inside a window rather than against the ambient environment: this used to rely on
        // APPLE_DRY_RUN happening to be unset, so an operator who exported `APPLE_DRY_RUN=junk`
        // made both calls throw and the test fail deterministically, and any exported value at
        // all left it at the mercy of a concurrent suite's window closing mid-comparison. Pinning
        // the write-posture set absent is what makes the agreement a statement about the seam.
        #expect(TestMode.dryRunVar == "APPLE_DRY_RUN")
        let g = try GlobalOptions.parse([])
        let pair = try TestEnvironment.withoutWriteModeOverrides {
            (try g.willExecute(defaultDryRun: false),
             try g.willExecute(defaultDryRun: false, envVar: TestMode.dryRunVar))
        }
        #expect(pair.0 == pair.1)
    }

    @Test("sandboxActive: flag OR truthy env; junk env throws on EVERY path, even with the flag")
    func sandboxActiveThrows() throws {
        // Uses the envVar seam with a test-owned variable: APPLE_TEST_MODE itself is read by
        // 15 v1 gate sites across sibling suites running in parallel, so setting it truthy
        // here could flip a concurrent write-safety assertion (review-caught race).
        let name = "APPLE_CLI_TEST_SANDBOX_UNIQ"
        let unset = try TestEnvironment.with([name: String?.none]) {
            (try TestMode.sandboxActive(flag: true, envVar: name),
             try TestMode.sandboxActive(flag: false, envVar: name))
        }
        #expect(unset.0 == true)
        #expect(unset.1 == false)
        #expect(try TestEnvironment.with([name: "true"]) {
            try TestMode.sandboxActive(flag: false, envVar: name)
        } == true)
        TestEnvironment.with([name: "sandbox"]) {
            #expect(throws: AppleError.self) {
                _ = try TestMode.sandboxActive(flag: false, envVar: name)
            }
            // Validation is EAGER (no || short-circuit): a malformed value refuses even when
            // --test-mode was passed — the fail-loud contract has no flag-shaped hole.
            #expect(throws: AppleError.self) {
                _ = try TestMode.sandboxActive(flag: true, envVar: name)
            }
        }
    }

    @Test("isTruthyEnv is the ONE documented fail-open reader: junk reads false, never throws")
    func isTruthyEnvFailOpenPinned() {
        // Deliberate and confined: isTruthyEnv exists for the few Bool-property contexts that
        // cannot throw (e.g. the Contacts env-gate reader). v2 write-path gates use the THROWING readers, where an
        // unparseable value refuses the command. This test pins the boundary so a future
        // refactor can't silently widen the fail-open surface without touching a test.
        let name = "APPLE_CLI_TEST_TRUTHY_UNIQ2"
        TestEnvironment.with([name: "junk-value"]) {
            #expect(TestMode.isTruthyEnv(name) == false)
        }
    }

}
