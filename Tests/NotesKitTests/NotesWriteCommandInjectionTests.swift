import Foundation
import Testing
import ArgumentParser
import TestSupport
@testable import NotesKit
@testable import AppleKit

// The five note-mutating commands (create / update / append / delete / move) driven through the
// injected AppleScript boundary, covering for each: the execute path's envelope, the `--dry-run`
// preview, every validation refusal with its exit code AND `error.type`, and the sandbox label
// gate on both paths.
//
// Two invariants are asserted structurally rather than by reading the source:
//
//   * A PREVIEW REACHES NOTHING. Every dry-run test passes `ThrowingNotesRunner`, so if a refactor
//     ever moves an AppleScript call above the `willExecute` branch the test goes red instead of
//     mutating the operator's Notes library.
//   * USER TEXT TRAVELS AS ARGV. `FakeNotesRunner` records the script SOURCE next to the argv, so
//     a hostile title can be asserted to appear in `arguments` and NOT in the script text — the
//     AppleScript-injection invariant this port exists to hold.
//
// The write gate reads no real environment variable: `pinnedWriteEnv()` points it at names nothing
// else in the process touches and pins the sandbox label. See `NotesInjectionFakes`.

@Suite("Notes create")
struct NotesCreateCommandTests {

    @Test func createExecutesAndReportsTheNewNoteId() throws {
        let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(1))"])
        let command = try CreateCmd.parse([
            "apple-cli-test note", "--content", "body text", "--folder", "apple-cli-test folder", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["dry_run"] as? Bool == false, "execute-path envelopes state dry_run explicitly")
        #expect(data["id"] as? String == fixtureNoteID(1))
        #expect(data["title"] as? String == "apple-cli-test note")
    }

    @Test func createPreviewsWithoutTouchingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try CreateCmd.parse([
            "apple-cli-test note", "--content", "body", "--folder", "Work", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["dry_run"] as? Bool == true)
        #expect(data["operation"] as? String == "create-note")
        #expect((data["detail"] as? String)?.contains("in Work") == true)
        #expect(runner.neverCalled)
    }

    @Test func createPassesHostileTitleTextAsArgvAndNeverAsScriptSource() throws {
        // A payload shaped to break out of an AppleScript string literal if it were interpolated.
        let hostile = "apple-cli-test\" & (do shell script \"echo pwned\") & \""
        let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(2))"])
        let command = try CreateCmd.parse([hostile, "--content", "body", "--execute"])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        // The payload reached the runner as an ARGUMENT (inside the generated body HTML)…
        #expect(runner.allArguments.contains { $0.contains("do shell script") })
        // …and the script SOURCE carries none of it.
        #expect(runner.scripts.allSatisfy { !$0.contains("do shell script") })
    }

    @Test func createRefusesInvalidInputBeforeAnyScriptRuns() throws {
        let cases: [([String], String)] = [
            (["t", "--content", "c", "--format", "rtf"], "Invalid --format"),
            ([String(repeating: "t", count: NotesLimits.title + 1), "--content", "c"], "title exceeds maximum"),
            (["t", "--content", "c", "--folder", "///"], "must be a non-empty string"),
            (["t", "--content", "c", "--account", String(repeating: "a", count: NotesLimits.account + 1)],
             "Account name exceeds maximum"),
            (["t", "--content", "c", "--folder", String(repeating: "f", count: NotesLimits.folder + 1)],
             "Folder path exceeds maximum"),
        ]
        for (args, fragment) in cases {
            let runner = ThrowingNotesRunner()
            let command = try CreateCmd.parse(args + ["--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(fragment)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect((failure.error["message"] as? String)?.contains(fragment) == true, "message for \(fragment)")
            #expect(runner.neverCalled, "validation must precede AppleScript for \(fragment)")
        }
    }

    @Test func createSandboxGateRefusesAnUnlabeledTitleOnBothPaths() throws {
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try CreateCmd.parse(["ordinary note", "--content", "c", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("apple-cli-test") == true)
            #expect(runner.neverCalled, "the label gate must fire before AppleScript on \(extra)")
        }
    }

    @Test func createSandboxGateAlsoRefusesAnUnlabeledDestinationFolder() throws {
        let runner = ThrowingNotesRunner()
        let command = try CreateCmd.parse([
            "apple-cli-test note", "--content", "c", "--folder", "Real Folder", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("Real Folder") == true)
        #expect(runner.neverCalled)
    }

    @Test func createInsideTheSandboxStampsTheEnvelope() throws {
        let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(3))"])
        let command = try CreateCmd.parse([
            "apple-cli-test note", "--content", "c", "--test-mode", "--execute",
        ])

        let envelope = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(envelope["sandbox"] as? Bool == true)
    }

    @Test func createTextRenderingMarksTheSandbox() throws {
        let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(4))"])
        let command = try CreateCmd.parse([
            "apple-cli-test note", "--content", "c", "--test-mode", "--execute", "--text",
        ])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(String(decoding: stdout.data, as: UTF8.self).hasPrefix("[sandbox] "))
    }
}

@Suite("Notes update")
struct NotesUpdateCommandTests {

    @Test func updateByIdReplacesTheBodyAndReportsTheResolvedTitle() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test old", id: fixtureNoteID(1)),
            "", // the body write
        ])
        let command = try UpdateCmd.parse([
            "--id", fixtureNoteID(1), "--new-content", "replacement", "--new-title", "apple-cli-test new", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["dry_run"] as? Bool == false)
        #expect(data["id"] as? String == fixtureNoteID(1))
        #expect(data["title"] as? String == "apple-cli-test new")
    }

    @Test func updateByTitleReportsTheFetchedTitleNotTheTypedOne() throws {
        // AppleScript's by-name lookup is case-insensitive, so the response must carry the note's
        // real name rather than the caller's spelling.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "Apple-Cli-Test Cased", id: fixtureNoteID(2)),
            "",
        ])
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test cased", "--new-content", "replacement", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["title"] as? String == "Apple-Cli-Test Cased")
        #expect(data.keys.contains("id") == false, "the title path carries no id")
    }

    @Test func updateInHtmlFormatDerivesTheReportedTitleFromTheNewBody() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test old", id: fixtureNoteID(3)),
            "",
        ])
        let command = try UpdateCmd.parse([
            "--id", fixtureNoteID(3), "--new-content", "<h1>apple-cli-test derived</h1><p>body</p>",
            "--format", "html", "--new-title", "ignored", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["title"] as? String == "apple-cli-test derived",
                "html format derives the title from the first visible line, ignoring --new-title")
    }

    @Test func updatePreviewDisclosesTheUncheckedSandboxTargetOnTheIdPath() throws {
        let runner = ThrowingNotesRunner()
        let command = try UpdateCmd.parse([
            "--id", fixtureNoteID(4), "--new-content", "c", "--test-mode", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "update-note")
        let detail = try #require(data["detail"] as? String)
        #expect(detail.contains("this preview did not run it"),
                "an id-addressed preview cannot check the target's label and must say so")
        #expect(detail.contains(TestMode.canonicalSandboxPrefix))
        #expect(runner.neverCalled)
    }

    @Test func updatePreviewOnTheTitlePathClaimsNoUncheckedGateForALabeledTarget() throws {
        // The counterpart to the id-path disclosure above, and the contract
        // `bats/hosted/notes.bats` pins: `--title` supplies the target NAME in argv, so the label
        // gate is computable on the preview path and actually RUNS here (an unlabeled title is
        // refused on both paths, below). A preview that got past it therefore has no skipped check
        // to excuse, and claiming one would be a false excuse on the one selector that settles the
        // gate from argv. The execute path's re-check of the FETCHED title is unconditional and
        // separate — see `updateSandboxGateRefusesACaseMismatchedResolvedTitle`.
        let runner = ThrowingNotesRunner()
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test titled", "--new-content", "c", "--test-mode", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(!detail.contains("did not run it"),
                "the typed title WAS checked; the preview must not claim a skipped gate")
        #expect(runner.neverCalled)
    }

    @Test func updateSandboxGateRefusesACaseMismatchedResolvedTitle() throws {
        // The typed selector is labeled and passes the argv check; the note the case-insensitive
        // lookup actually resolves is a REAL note whose name fails the case-sensitive label check.
        // Guarding the typed string instead of the fetched one let this write through.
        let runner = FakeNotesRunner(results: [noteRow(title: "APPLE-CLI-TEST Real", id: fixtureNoteID(8))],
                                     whenExhausted: .empty)
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test real", "--new-content", "c", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("APPLE-CLI-TEST Real") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the body write was refused")
    }

    @Test func updateByTitleWritesThroughTheResolvedIdSoASecondLookupCannotRetarget() throws {
        // Time-of-check/time-of-use: the guard above checks ONE fetched note, but the write used to
        // re-resolve the SAME title, which is a SECOND lookup. Duplicate titles across folders, or
        // a rename landing between the two calls, make the note guarded and the note written
        // different notes. The runner below answers any by-title write with a DECOY note, so a
        // write that re-resolved by title would be visible here.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test target", id: fixtureNoteID(11)), // the guarded resolution
            "",                                                             // the write
        ])
        runner.handler = { script, _ in
            script.contains("set body of note (item 1 of argv)")
                ? noteRow(title: "apple-cli-test DECOY", id: fixtureNoteID(99))
                : nil
        }
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test target", "--new-content", "replacement", "--execute",
        ])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(runner.scripts.allSatisfy { !$0.contains("set body of note (item 1 of argv)") },
                "no second by-title resolution: the decoy was never reachable")
        #expect(runner.scripts.last?.contains("set body of note id (item 1 of argv)") == true,
                "the write addresses the note by its RESOLVED id")
        #expect(runner.arguments.last?.first == fixtureNoteID(11),
                "…and that id is the one the guard actually checked")
    }

    @Test func updateByTitleWritesTheSameBodyBytesAsTheTitleAddressedWriteDid() throws {
        // Addressing by id must not change WHAT is written. `updateNoteById` falls back to a fresh
        // lookup when it has no title, while `updateNote` used the TYPED title — so the caller
        // passes that title explicitly. Same first line, no extra round trip.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test target", id: fixtureNoteID(13)),
            "",
        ])
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test target", "--new-content", "replacement", "--execute",
        ])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(runner.invocationCount == 2, "one resolution, one write — no extra title lookup")
        let written = try #require(runner.arguments.last?.last)
        #expect(written == NotesText.updateNoteBody(effectiveTitle: "apple-cli-test target",
                                                    content: "replacement", html: false),
                "the body bytes are the ones the title-addressed write produced")
    }

    @Test func updateSandboxGateRefusesAnUnlabeledRename() throws {
        let runner = ThrowingNotesRunner()
        let command = try UpdateCmd.parse([
            "--title", "apple-cli-test old", "--new-title", "Real Name", "--new-content", "c",
            "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("Real Name") == true)
        #expect(runner.neverCalled)
    }

    @Test func updateSandboxGateRefusesAnUnlabeledFetchedTitleOnTheIdPath() throws {
        let runner = FakeNotesRunner(results: [noteRow(title: "Real Note", id: fixtureNoteID(5))],
                                     whenExhausted: .empty)
        let command = try UpdateCmd.parse([
            "--id", fixtureNoteID(5), "--new-content", "c", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("Real Note") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the write was refused")
    }

    @Test func updateRefusesAPasswordProtectedNoteOnBothSelectorPaths() throws {
        for args in [["--id", fixtureNoteID(6)], ["--title", "locked"]] {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "locked", id: fixtureNoteID(6), passwordProtected: true),
            ], whenExhausted: .empty)
            let command = try UpdateCmd.parse(args + ["--new-content", "c", "--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(args)")
            #expect((failure.error["message"] as? String)?.contains("password-protected") == true)
        }
    }

    @Test func updateReportsNotFoundWhenTheTargetDoesNotResolve() throws {
        for args in [["--id", fixtureNoteID(7)], ["--title", "gone"]] {
            let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
            let command = try UpdateCmd.parse(args + ["--new-content", "c", "--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.notFound, "exit for \(args)")
            #expect(failure.error["type"] as? String == AppleErrorType.notFound)
        }
    }
}

@Suite("Notes append")
struct NotesAppendCommandTests {

    @Test func appendConcatenatesOntoTheExistingBody() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test note", id: fixtureNoteID(1)),
            "<div>existing</div>",
            "",
        ])
        let command = try AppendCmd.parse([
            "--id", fixtureNoteID(1), "--content", "added line", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(data["dry_run"] as? Bool == false)
        // The write carried BOTH the old body and the new content.
        let written = try #require(runner.arguments.last?.last)
        #expect(written.contains("existing"))
        #expect(written.contains("added line"))
    }

    @Test func appendByTitleReportsTheTypedTitleAndOmitsTheId() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test note", id: fixtureNoteID(2)),
            "<div>existing</div>",
            "",
        ])
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test note", "--content", "added", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["title"] as? String == "apple-cli-test note")
        #expect(data.keys.contains("id") == false)
    }

    @Test func appendByTitleReadsAndWritesTheResolvedIdSoASecondLookupCannotRetarget() throws {
        // Append is the worst case of the by-title re-resolution gap: it READS a body, concatenates,
        // and writes the WHOLE body back. Two lookups landing on different notes (duplicate titles,
        // or a rename between calls) would overwrite one note with another's content. The runner
        // answers any by-title read or write with a DECOY, so either would be visible here.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test note", id: fixtureNoteID(14)), // the guarded resolution
            "<div>guarded body</div>",                                    // the id-addressed read
            "",                                                           // the id-addressed write
        ])
        runner.handler = { script, _ in
            if script.contains("return body of note (item 1 of argv)") { return "<div>DECOY body</div>" }
            if script.contains("set body of note (item 1 of argv)") { return "" }
            return nil
        }
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test note", "--content", "added line", "--execute",
        ])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(runner.scripts.allSatisfy {
            !$0.contains("return body of note (item 1 of argv)")
                && !$0.contains("set body of note (item 1 of argv)")
        }, "no second by-title resolution: neither decoy was reachable")
        let written = try #require(runner.arguments.last?.last)
        #expect(written.contains("guarded body"), "the body appended to is the guarded note's")
        #expect(!written.contains("DECOY"))
        #expect(runner.arguments.last?.first == fixtureNoteID(14),
                "the write addresses the id the guard checked")
    }

    @Test func appendSandboxGateRefusesACaseMismatchedResolvedTitleOnTheTitlePath() throws {
        // The typed selector is labeled and passes the argv check; the note the case-insensitive
        // by-name lookup actually resolves is a REAL note whose name fails the case-sensitive label
        // check. Guarding the typed string instead of the fetched one let this write through.
        let runner = FakeNotesRunner(results: [noteRow(title: "APPLE-CLI-TEST Real", id: fixtureNoteID(15))],
                                     whenExhausted: .empty)
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test real", "--content", "c", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("APPLE-CLI-TEST Real") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the read and write were refused")
    }

    @Test func appendPreviewOnTheTitlePathClaimsNoUncheckedGateForALabeledTarget() throws {
        // `--title` settles the label gate from argv, so a preview that got past it has no skipped
        // check to excuse — the contract `bats/hosted/notes.bats` pins.
        let runner = ThrowingNotesRunner()
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test titled", "--content", "c", "--test-mode", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(!detail.contains("did not run it"))
        #expect(runner.neverCalled)
    }

    @Test func appendPreviewDisclosesPositionAndSeparator() throws {
        let runner = ThrowingNotesRunner()
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test note", "--content", "x", "--position", "before",
            "--separator", "~~~", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(detail.contains("prepend before"), "a preview must not imply an append when --position before prepends")
        #expect(detail.contains("\"~~~\""))
        #expect(runner.neverCalled)
    }

    @Test func appendPreviewNamesTheDefaultSeparatorInWords() throws {
        let runner = ThrowingNotesRunner()
        let command = try AppendCmd.parse(["--title", "apple-cli-test note", "--content", "x", "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(detail.contains("append after"))
        #expect(detail.contains("a blank line"))
    }

    @Test func appendRefusesTheInputTheOracleSchemaRefuses() throws {
        let cases: [([String], String)] = [
            (["--content", ""], "Content to append is required"),
            (["--content", "x", "--position", "sideways"], "Invalid position"),
            (["--content", "x", "--separator", String(repeating: "~", count: 21)], "Separator exceeds maximum"),
            (["--content", "x", "--format", "rtf"], "Invalid --format"),
        ]
        for (args, fragment) in cases {
            let runner = ThrowingNotesRunner()
            let command = try AppendCmd.parse(["--title", "apple-cli-test note"] + args + ["--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(fragment)")
            #expect((failure.error["message"] as? String)?.contains(fragment) == true, "message for \(fragment)")
            #expect(runner.neverCalled)
        }
    }

    @Test func appendMeasuresTheSeparatorBoundInUtf16CodeUnitsLikeZod() throws {
        // 11 emoji = 22 UTF-16 code units but 11 graphemes: over the oracle's bound, and the
        // recurring parity trap in this repo (Swift counts graphemes, the oracle counts units).
        let runner = ThrowingNotesRunner()
        let command = try AppendCmd.parse([
            "--title", "apple-cli-test note", "--content", "x",
            "--separator", String(repeating: "\u{1F600}", count: 11), "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("Separator exceeds maximum") == true)
    }

    @Test func appendRefusesAPasswordProtectedNote() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "locked", id: fixtureNoteID(3), passwordProtected: true),
        ], whenExhausted: .empty)
        let command = try AppendCmd.parse(["--id", fixtureNoteID(3), "--content", "x", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("password-protected") == true)
    }

    @Test func appendSandboxGateRefusesAnUnlabeledFetchedTitleOnTheIdPath() throws {
        // `--id` addressing cannot be label-checked from argv, so the confinement lives on the
        // execute path AFTER the title is read back from Notes.app. That guard is the only thing
        // between a sandboxed `notes append --id <real note>` and a real note — the sandbox is a
        // policy mode over the REAL store, not an isolated one.
        let runner = FakeNotesRunner(results: [noteRow(title: "Real Note", id: fixtureNoteID(5))],
                                     whenExhausted: .empty)
        let command = try AppendCmd.parse([
            "--id", fixtureNoteID(5), "--content", "x", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real Note") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the body read and the write were refused")
    }

    @Test func appendReportsNotFoundOnBothSelectorPaths() throws {
        for args in [["--id", fixtureNoteID(4)], ["--title", "gone"]] {
            let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
            let command = try AppendCmd.parse(args + ["--content", "x", "--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.notFound, "exit for \(args)")
        }
    }
}

@Suite("Notes delete + move")
struct NotesDeleteMoveCommandTests {

    @Test func deleteExecutesAndReportsTheDeletedNote() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test doomed", id: fixtureNoteID(1), shared: true),
            "",
        ])
        let command = try DeleteCmd.parse(["--id", fixtureNoteID(1), "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["dry_run"] as? Bool == false)
        #expect(data["title"] as? String == "apple-cli-test doomed")
        #expect(data["was_shared"] as? Bool == true)
    }

    @Test func deleteByTitleOmitsTheId() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test doomed", id: fixtureNoteID(2)),
            "",
        ])
        let command = try DeleteCmd.parse(["--title", "apple-cli-test doomed", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data.keys.contains("id") == false)
    }

    @Test func deleteByTitleDeletesTheResolvedIdSoASecondLookupCannotRetarget() throws {
        // Same time-of-check/time-of-use window as update and append, on the one verb where getting
        // it wrong destroys a note: the guard checked ONE fetched note, and a second by-title
        // resolution can land on another (duplicate titles, or a rename between the calls). The
        // runner answers any by-title delete with a DECOY, so re-resolution would be visible here.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test doomed", id: fixtureNoteID(16)),
            "",
        ])
        runner.handler = { script, _ in
            script.contains("delete note (item 1 of argv)")
                ? noteRow(title: "apple-cli-test DECOY", id: fixtureNoteID(99))
                : nil
        }
        let command = try DeleteCmd.parse(["--title", "apple-cli-test doomed", "--execute"])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(runner.scripts.allSatisfy { !$0.contains("delete note (item 1 of argv)") },
                "no second by-title resolution: the decoy was never reachable")
        #expect(runner.scripts.last?.contains("delete note id (item 1 of argv)") == true,
                "the delete addresses the note by its RESOLVED id")
        #expect(runner.arguments.last?.first == fixtureNoteID(16),
                "…and that id is the one the guard actually checked")
    }

    @Test func deleteSandboxGateRefusesACaseMismatchedResolvedTitleOnTheTitlePath() throws {
        let runner = FakeNotesRunner(results: [noteRow(title: "APPLE-CLI-TEST Real", id: fixtureNoteID(17))],
                                     whenExhausted: .empty)
        let command = try DeleteCmd.parse([
            "--title", "apple-cli-test real", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("APPLE-CLI-TEST Real") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the delete was refused")
    }

    @Test func deletePreviewOnTheTitlePathClaimsNoUncheckedGateForALabeledTarget() throws {
        let runner = ThrowingNotesRunner()
        let command = try DeleteCmd.parse([
            "--title", "apple-cli-test titled", "--test-mode", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(!detail.contains("did not run it"))
        #expect(runner.neverCalled)
    }

    @Test func deletePreviewSaysTheNoteStaysRecoverable() throws {
        let runner = ThrowingNotesRunner()
        let command = try DeleteCmd.parse(["--id", fixtureNoteID(3), "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "delete-note")
        #expect((data["detail"] as? String)?.contains("Recently Deleted") == true)
        #expect(runner.neverCalled)
    }

    @Test func deleteReportsNotFoundOnBothSelectorPaths() throws {
        for args in [["--id", fixtureNoteID(4)], ["--title", "gone"]] {
            let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
            let command = try DeleteCmd.parse(args + ["--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.notFound, "exit for \(args)")
        }
    }

    @Test func deleteSandboxGateRefusesAnUnlabeledFetchedTitleOnTheIdPath() throws {
        // Same execute-path-only confinement as `update`/`append`, and the one with the highest
        // cost if it is ever dropped: without it a sandboxed `notes delete --id <real note>`
        // deletes a real note.
        let runner = FakeNotesRunner(results: [noteRow(title: "Real Note", id: fixtureNoteID(5))],
                                     whenExhausted: .empty)
        let command = try DeleteCmd.parse(["--id", fixtureNoteID(5), "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real Note") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the delete was refused")
    }

    @Test func deleteRequiresASelector() throws {
        let runner = ThrowingNotesRunner()
        let command = try DeleteCmd.parse(["--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Either --id or --title") == true)
        #expect(runner.neverCalled)
    }

    // MARK: move

    @Test func moveExecutesAndNamesTheDestination() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test movable", id: fixtureNoteID(5)),
            "",
        ])
        let command = try MoveCmd.parse([
            "--id", fixtureNoteID(5), "--folder", "apple-cli-test dest", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["folder"] as? String == "apple-cli-test dest")
        #expect(data["title"] as? String == "apple-cli-test movable")
    }

    @Test func moveByTitleResolvesTheIdFirstAndOmitsItFromTheResponse() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test movable", id: fixtureNoteID(6)),
            "",
        ])
        let command = try MoveCmd.parse([
            "--title", "apple-cli-test movable", "--folder", "apple-cli-test dest", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data.keys.contains("id") == false)
        // The move script addresses the note by the FETCHED id, not by the typed title.
        #expect(runner.arguments.last?.first == fixtureNoteID(6))
    }

    @Test func moveSandboxGateRefusesACaseMismatchedResolvedTitleOnTheTitlePath() throws {
        // Move already addressed by the fetched id, but the LABEL check is the separate half:
        // a labeled typed title can resolve a real note whose actual name is not labeled.
        let runner = FakeNotesRunner(results: [noteRow(title: "APPLE-CLI-TEST Real", id: fixtureNoteID(18))],
                                     whenExhausted: .empty)
        let command = try MoveCmd.parse([
            "--title", "apple-cli-test real", "--folder", "apple-cli-test dest",
            "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("APPLE-CLI-TEST Real") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the move was refused")
    }

    @Test func movePreviewOnTheTitlePathClaimsNoUncheckedGateForALabeledTarget() throws {
        let runner = ThrowingNotesRunner()
        let command = try MoveCmd.parse([
            "--title", "apple-cli-test titled", "--folder", "apple-cli-test dest",
            "--test-mode", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        let detail = try #require(data["detail"] as? String)
        #expect(!detail.contains("did not run it"))
        #expect(runner.neverCalled)
    }

    @Test func moveRefusesAnEmptyDestinationFolder() throws {
        let runner = ThrowingNotesRunner()
        let command = try MoveCmd.parse(["--id", fixtureNoteID(7), "--folder", "///", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("must be a non-empty string") == true)
        #expect(runner.neverCalled)
    }

    @Test func moveSandboxGateRefusesARealDestinationOnBothPaths() throws {
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try MoveCmd.parse([
                "--id", fixtureNoteID(8), "--folder", "Real Folder", "--test-mode", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect((failure.error["message"] as? String)?.contains("Real Folder") == true)
            #expect(runner.neverCalled, "the destination label check runs on \(extra) too")
        }
    }

    @Test func moveSandboxGateRefusesAnUnlabeledCOMPONENTOfANestedDestination() throws {
        // A destination path is not one label: `splitFolderPath` resolves the specifier, so the
        // note would land in the UNLABELED child even though the string starts with the prefix.
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try MoveCmd.parse([
                "--id", fixtureNoteID(12), "--folder", "apple-cli-test parent/Real Folder",
                "--test-mode", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect((failure.error["message"] as? String)?.contains("Real Folder") == true, "message for \(extra)")
            #expect(runner.neverCalled, "the component check runs on \(extra) too")
        }
    }

    @Test func movePreviewNamesTheDestinationWithoutTouchingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try MoveCmd.parse(["--id", fixtureNoteID(9), "--folder", "Archive", "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "move-note")
        #expect((data["detail"] as? String)?.contains("Archive") == true)
        #expect(runner.neverCalled)
    }

    @Test func moveSandboxGateRefusesAnUnlabeledFetchedTitleOnTheIdPath() throws {
        // The DESTINATION is labeled, so the argv-computable half of the gate passes; what must
        // still refuse is the SOURCE note, whose title only the execute path can read back.
        let runner = FakeNotesRunner(results: [noteRow(title: "Real Note", id: fixtureNoteID(11))],
                                     whenExhausted: .empty)
        let command = try MoveCmd.parse([
            "--id", fixtureNoteID(11), "--folder", "apple-cli-test dest", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real Note") == true)
        #expect(runner.invocationCount == 1, "only the lookup ran; the move was refused")
    }

    @Test func moveReportsNotFoundOnBothSelectorPaths() throws {
        for args in [["--id", fixtureNoteID(10)], ["--title", "gone"]] {
            let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
            let command = try MoveCmd.parse(args + ["--folder", "Dest", "--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.notFound, "exit for \(args)")
        }
    }
}

@Suite("Notes write gate — precedence and env plumbing")
struct NotesWriteGateTests {

    @Test func aWriteExecutesByDefaultWhenNeitherFlagIsPassed() throws {
        // Write-model v2 parity: invoking the command mutates, exactly as calling the MCP tool does.
        let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(1))"])
        let command = try CreateCmd.parse(["apple-cli-test note", "--content", "c"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv("default-execute"))
        })

        #expect(data["dry_run"] as? Bool == false)
        #expect(runner.invocationCount == 1)
    }

    @Test func dryRunBeatsExecuteWhenBothArePassed() throws {
        let runner = ThrowingNotesRunner()
        let command = try CreateCmd.parse(["apple-cli-test note", "--content", "c", "--dry-run", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            env: pinnedWriteEnv())
        })

        #expect(data["dry_run"] as? Bool == true)
        #expect(runner.neverCalled)
    }

    /// The three tests below need the env-SET branch, which means a real `setenv`. They use
    /// TEST-OWNED variable names — nothing else in the process reads them — and still route the
    /// mutation through `TestEnvironment.with`, whose process-wide lock is the only thing that
    /// makes concurrent `setenv` calls safe: swift-testing runs suites in parallel, and the
    /// environment is one shared, unsynchronized table regardless of which names are being written.
    @Test func anUnparseableDryRunVariableRefusesTheCommandInsteadOfGuessing() throws {
        let name = "APPLE_NOTESKIT_TESTONLY_BAD_DRY_RUN"
        let env = NotesWriteEnv(testModeVar: "APPLE_NOTESKIT_TESTONLY_UNSET_MODE",
                                dryRunVar: name,
                                sandboxPrefix: TestMode.canonicalSandboxPrefix)
        let runner = ThrowingNotesRunner()
        let command = try CreateCmd.parse(["apple-cli-test note", "--content", "c"])

        let failure = try TestEnvironment.with([name: "maybe"]) {
            try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) }, env: env)
            }
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(runner.neverCalled)
    }

    @Test func aTruthyDryRunVariableRestoresPreviewByDefault() throws {
        let name = "APPLE_NOTESKIT_TESTONLY_ON_DRY_RUN"
        let env = NotesWriteEnv(testModeVar: "APPLE_NOTESKIT_TESTONLY_UNSET_MODE2",
                                dryRunVar: name,
                                sandboxPrefix: TestMode.canonicalSandboxPrefix)
        let runner = ThrowingNotesRunner()
        let command = try CreateCmd.parse(["apple-cli-test note", "--content", "c"])

        let data = try notesData(try TestEnvironment.with([name: "1"]) {
            try captureNotesEnvelope {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) }, env: env)
            }
        })

        #expect(data["dry_run"] as? Bool == true)
        #expect(runner.neverCalled)
    }

    @Test func theSandboxEngagesFromTheEnvironmentVariableAloneWithoutTheFlag() throws {
        let name = "APPLE_NOTESKIT_TESTONLY_ON_TEST_MODE"
        let env = NotesWriteEnv(testModeVar: name,
                                dryRunVar: "APPLE_NOTESKIT_TESTONLY_UNSET_DRY",
                                sandboxPrefix: TestMode.canonicalSandboxPrefix)
        let runner = ThrowingNotesRunner()
        // No --test-mode flag: the variable alone must engage the label gate.
        let command = try CreateCmd.parse(["ordinary note", "--content", "c"])

        let failure = try TestEnvironment.with([name: "yes"]) {
            try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) }, env: env)
            }
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect(runner.neverCalled)
    }

    /// The `env:` DEFAULT ARGUMENT is what the shipped CLI runs on: every `ParsableCommand.run()`
    /// shim calls `run(scriptFactory:)` and names no env, and every other test in this file passes
    /// `pinnedWriteEnv()` explicitly — so the default itself is unobserved unless a test omits it.
    /// This one omits it, and therefore reads the REAL variables; that is the point, and it is why
    /// this is the one place that pins the whole write-posture set through `TestEnvironment`'s
    /// process-wide lock rather than through the seam — the shared `withoutWriteModeOverrides`
    /// window (never a hand-spelled subset), with `APPLE_TEST_MODE` then SET inside it.
    @Test func aWriteCommandOmittingTheEnvArgumentGetsTheLiveEnvironment() throws {
        let command = try CreateCmd.parse(["ordinary note", "--content", "c", "--execute"])
        let engageSandbox: [String: String?] = [TestMode.testModeVar: "1"]

        try TestEnvironment.withoutWriteModeOverrides {
            try TestEnvironment.with(engageSandbox) {
                // The default argument resolves to the same gate `.live` does, for the same options.
                #expect(try resolveNotesWrite(command.global, defaultDryRun: false)
                        == resolveNotesWrite(command.global, defaultDryRun: false, env: .live))

                // …and end to end: with the real APPLE_TEST_MODE set, an unlabeled title must be
                // refused. An env repointed at test-only names would leave the sandbox disengaged
                // and let the write through; a `sandboxPrefix: ""` would vacate the label check.
                let runner = ThrowingNotesRunner()
                let failure = try captureNotesFailure {
                    try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) })
                }

                #expect(failure.code == AppleExit.usage)
                #expect(failure.error["sandbox"] as? Bool == true)
                #expect((failure.error["message"] as? String)?.contains(TestMode.canonicalSandboxPrefix) == true)
                #expect(runner.neverCalled)
            }
        }
    }
}
