import Testing
import Foundation
import ArgumentParser
@testable import AppleKit

/// Write-model v2 core machinery (docs/write-model-v2.md). These tests exercise the PURE
/// cores (`parseTruthy`, `resolveExecute`, `encodeSuccess`) so no test mutates process env —
/// the env-reading wrappers are one-line `ProcessInfo` reads over these.
@Suite("Write-model v2 core — fail-loud env, execute precedence, sandbox envelope")
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
        unsetenv(name)
        #expect(try TestMode.truthyEnv(name) == false)
        setenv(name, "yes", 1)
        #expect(try TestMode.truthyEnv(name) == true)
        setenv(name, "maybe", 1)
        #expect(throws: AppleError.self) { _ = try TestMode.truthyEnv(name) }
        unsetenv(name)
    }

    @Test("willExecute(defaultDryRun:) THROWS on an unparseable APPLE_DRY_RUN — never silent-execute")
    func willExecuteThrowsOnJunkEnv() throws {
        // This test owns APPLE_DRY_RUN for its duration. Nothing else in the swift tier
        // reads it (domains are pre-flip), and bats runs in separate processes.
        defer { unsetenv(TestMode.dryRunVar) }
        let g = try GlobalOptions.parse([])
        unsetenv(TestMode.dryRunVar)
        #expect(try g.willExecute(defaultDryRun: false) == true)
        setenv(TestMode.dryRunVar, "1", 1)
        #expect(try g.willExecute(defaultDryRun: false) == false)
        setenv(TestMode.dryRunVar, "ture", 1)
        #expect(throws: AppleError.self) { _ = try g.willExecute(defaultDryRun: false) }
        // --execute with junk env still throws (validation precedes precedence).
        let e = try GlobalOptions.parse(["--execute"])
        #expect(throws: AppleError.self) { _ = try e.willExecute(defaultDryRun: false) }
    }

    @Test("sandboxActive: flag OR truthy env; junk env throws on EVERY path, even with the flag")
    func sandboxActiveThrows() throws {
        // Uses the envVar seam with a test-owned variable: APPLE_TEST_MODE itself is read by
        // 15 v1 gate sites across sibling suites running in parallel, so setting it truthy
        // here could flip a concurrent write-safety assertion (review-caught race).
        let name = "APPLE_CLI_TEST_SANDBOX_UNIQ"
        defer { unsetenv(name) }
        unsetenv(name)
        #expect(try TestMode.sandboxActive(flag: true, envVar: name) == true)
        #expect(try TestMode.sandboxActive(flag: false, envVar: name) == false)
        setenv(name, "true", 1)
        #expect(try TestMode.sandboxActive(flag: false, envVar: name) == true)
        setenv(name, "sandbox", 1)
        #expect(throws: AppleError.self) { _ = try TestMode.sandboxActive(flag: false, envVar: name) }
        // Validation is EAGER (no || short-circuit): a malformed value refuses even when
        // --test-mode was passed — the fail-loud contract has no flag-shaped hole.
        #expect(throws: AppleError.self) { _ = try TestMode.sandboxActive(flag: true, envVar: name) }
    }

    @Test("isTruthyEnv is the ONE documented fail-open reader: junk reads false, never throws")
    func isTruthyEnvFailOpenPinned() {
        // Deliberate and confined: isTruthyEnv exists for Bool-property contexts that cannot
        // throw (TestMode.isEnabled). v2 write-path gates use the THROWING readers, where an
        // unparseable value refuses the command. This test pins the boundary so a future
        // refactor can't silently widen the fail-open surface without touching a test.
        let name = "APPLE_CLI_TEST_TRUTHY_UNIQ2"
        setenv(name, "junk-value", 1)
        #expect(TestMode.isTruthyEnv(name) == false)
        unsetenv(name)
    }

    // MARK: v1 property (deprecated, deleted at the final flip; semantics frozen until then)

    @Test("the v1 willExecute property still requires --execute and yields to --dry-run")
    func v1PropertyUnchanged() throws {
        // Deprecation warnings HERE are expected — this test pins the frozen v1 semantics.
        #expect(try GlobalOptions.parse([]).willExecute == false)
        #expect(try GlobalOptions.parse(["--execute"]).willExecute == true)
        #expect(try GlobalOptions.parse(["--execute", "--dry-run"]).willExecute == false)
    }
}
