import Foundation
import Testing
import ArgumentParser
import TestSupport
@testable import NotesKit
@testable import AppleKit

// ONE invariant, asserted for EVERY user-controlled parameter of every Notes command that reaches
// Notes.app: the operator's value travels to osascript as an ARGUMENT and appears in no script
// SOURCE.
//
// Why this file exists separately from the per-command behavior suites: the invariant was
// previously asserted for `create --title` alone (plus a partial folder-name check in the org
// suite), while `FakeNotesRunner` records the script source specifically so it can be asserted
// everywhere. A reader seeing six `*InjectionTests.swift` files reasonably concludes the
// argv-not-source rule is covered per command; before this file, it was covered for one parameter
// of one command. Interpolating user text into AppleScript source is RCE-class, so the breadth of
// the assertion should match the breadth of the risk.
//
// The MATRIX shape is the point. Asserting one parameter per command would still leave the other
// parameters of that command untested while looking like command-level coverage — the same
// over-reading the file was created to fix, one level down. So each case drives its command with a
// DISTINCT `hostilePayload(marker)` in EVERY user-controlled parameter at once and then checks all
// of those markers, which additionally catches a value that reaches argv under the wrong index or
// gets copied into a neighbouring parameter's interpolation.
//
// The payload is shaped to break out of an AppleScript string literal; the MARKER, not the
// breakout characters, is what is searched for. An ESCAPED interpolation would mangle the quotes
// but still leave the marker verbatim in the source, so marker-absence is the strong form.
//
// No case here engages the sandbox, so `guardLiveWrite` is a no-op and the payloads reach the
// script wrappers exactly as an unsandboxed run would deliver them.
//
// DELIBERATELY OUT OF SCOPE (each is a parameter that cannot reach a script as user text, so
// "argv-only" is not the property that protects it — a stronger one already does):
//   * `--format` (create/update/append/export) and `--position` (append): closed enumerations
//     validated Swift-side; the value selects a code path, it is never emitted.
//   * `--limit` (list/search): an `Int`, embedded numerically after validation — the documented
//     exception in `NotesScript`'s header, and covered by the limit-parity suites.
//   * `--limit` (recent): a DIFFERENT reason from the two above, not the same entry. It is never
//     embedded in a script at all — pass 1 enumerates the whole scope unbounded and the cut is
//     Swift-side, so there is no interpolation site to protect. Covered by the recent suite's
//     limit cases.
//   * `--modified-since` (list/search): parsed to a `Date` and emitted as numeric date parts;
//     an unparseable value is refused before any script is built.
//   * `--tags` (create): echo-only. It is copied into the JSON response and never handed to
//     Notes.app at all (the oracle does not persist tags either).
//   * `--ids` (batch-delete/batch-move) and `--id` (get-link): constrained by
//     `NotesScript.isValidNoteId`, an ANCHORED pattern a hostile value cannot satisfy, so such a
//     value never reaches a script in any form. Pinned below as its own assertion rather than
//     assumed.
//   * `get-checklist` / `get-metadata` `--id`: those commands read `NoteStore.sqlite` through the
//     store seam and build no AppleScript, so there is no source for a value to land in. The
//     store side is parameter-bound SQL, covered by the store suites.

/// One row of the matrix: a command, the markers it must carry as argv, and how to drive it.
///
/// `exercise` returns the runner it drove so the assertions read both halves off the same
/// recording. It is a closure rather than data because each command needs its own stubbed replies;
/// what is uniform is the CHECK, not the setup.
private struct ArgvCase {
    let command: String
    let markers: [String]
    let exercise: () throws -> FakeNotesRunner
}

@Suite("Notes — user text travels as argv, never as script source")
struct NotesArgvInvarianceTests {
    /// Owns the destination directory `save-attachment` writes into.
    private let scratch = ScratchDirs("notes-argv-invariance")

    /// A runner that answers the `save theAttachment` script by writing bytes to the path it was
    /// handed as argv — the shape `save-attachment` and `fetch-attachment` both need.
    private func savingRunner() -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        runner.handler = { script, argv in
            guard script.contains("save theAttachment"), argv.count >= 3 else { return nil }
            try? Data("synthetic-attachment".utf8).write(to: URL(fileURLWithPath: argv[2]))
            return ["OK", "diagram.png", "public.png"].joined(separator: US)
        }
        return runner
    }

    /// Every user-text-carrying parameter of every Notes command that builds an AppleScript.
    private func cases() -> [ArgvCase] {
        var rows: [ArgvCase] = []

        // MARK: write commands

        rows.append(ArgvCase(command: "notes create", markers: [
            "PWNDCREATETITLE", "PWNDCREATECONTENT", "PWNDCREATEFOLDER", "PWNDCREATEACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: ["note id \(fixtureNoteID(1))"])
            let command = try CreateCmd.parse([
                hostilePayload("PWNDCREATETITLE"),
                "--content", hostilePayload("PWNDCREATECONTENT"),
                "--folder", hostilePayload("PWNDCREATEFOLDER"),
                "--account", hostilePayload("PWNDCREATEACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes update", markers: [
            "PWNDUPDATETITLE", "PWNDUPDATENEWTITLE", "PWNDUPDATENEWCONTENT", "PWNDUPDATEACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test old", id: fixtureNoteID(2)),
                "", // the body write
            ])
            let command = try UpdateCmd.parse([
                "--title", hostilePayload("PWNDUPDATETITLE"),
                "--new-title", hostilePayload("PWNDUPDATENEWTITLE"),
                "--new-content", hostilePayload("PWNDUPDATENEWCONTENT"),
                "--account", hostilePayload("PWNDUPDATEACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes append", markers: [
            "PWNDAPPENDTITLE", "PWNDAPPENDCONTENT", "PWNDSEP", "PWNDAPPENDACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test note", id: fixtureNoteID(3)),
                "<div>existing</div>",
                "", // the body write
            ])
            // The oracle caps the separator at 20 UTF-16 code units, so its payload is the short
            // form of the same breakout shape rather than the full `hostilePayload`.
            let command = try AppendCmd.parse([
                "--title", hostilePayload("PWNDAPPENDTITLE"),
                "--content", hostilePayload("PWNDAPPENDCONTENT"),
                "--separator", "\" & PWNDSEP & \"",
                "--account", hostilePayload("PWNDAPPENDACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes delete", markers: [
            "PWNDDELETETITLE", "PWNDDELETEACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test doomed", id: fixtureNoteID(4)),
                "", // the delete
            ])
            let command = try DeleteCmd.parse([
                "--title", hostilePayload("PWNDDELETETITLE"),
                "--account", hostilePayload("PWNDDELETEACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes move", markers: [
            "PWNDMOVETITLE", "PWNDMOVEFOLDER", "PWNDMOVEACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test movable", id: fixtureNoteID(5)),
                "", // the move
            ])
            let command = try MoveCmd.parse([
                "--title", hostilePayload("PWNDMOVETITLE"),
                "--folder", hostilePayload("PWNDMOVEFOLDER"),
                "--account", hostilePayload("PWNDMOVEACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes create-folder", markers: [
            "PWNDNEWFOLDERNAME", "PWNDNEWFOLDERACCOUNT",
        ]) {
            // Every existence probe answers empty, so the walk finds the segment present and only
            // the probes run — the name still travels as argv, which is what is under test.
            let runner = FakeNotesRunner(whenExhausted: .empty)
            let command = try CreateFolderCmd.parse([
                hostilePayload("PWNDNEWFOLDERNAME"),
                "--account", hostilePayload("PWNDNEWFOLDERACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes delete-folder", markers: [
            "PWNDDELFOLDERNAME", "PWNDDELFOLDERACCOUNT",
        ]) {
            // Unsandboxed, so the cascade enumeration returns before touching anything and the
            // single call is the delete itself.
            let runner = FakeNotesRunner(results: [""])
            let command = try DeleteFolderCmd.parse([
                hostilePayload("PWNDDELFOLDERNAME"),
                "--account", hostilePayload("PWNDDELFOLDERACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes batch-move", markers: [
            "PWNDBATCHFOLDER", "PWNDBATCHACCOUNT",
        ]) {
            // `--ids` is excluded by construction (see the header); the destination folder and the
            // account are the free-text half of this command.
            let runner = FakeNotesRunner(results: ["ok" + RS])
            let command = try BatchMoveCmd.parse([
                "--ids", fixtureNoteID(6),
                "--folder", hostilePayload("PWNDBATCHFOLDER"),
                "--account", hostilePayload("PWNDBATCHACCOUNT"),
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        // MARK: attachment commands

        rows.append(ArgvCase(command: "notes save-attachment", markers: [
            "PWNDSAVENOTEID", "PWNDSAVEATTID", "PWNDSAVEPATH",
        ]) {
            let destination = try self.scratch.directory()
                .appendingPathComponent(hostilePayload("PWNDSAVEPATH") + ".png").path
            let runner = self.savingRunner()
            let command = try SaveAttachmentCmd.parse([
                "--note-id", hostilePayload("PWNDSAVENOTEID"),
                "--attachment-id", hostilePayload("PWNDSAVEATTID"),
                "--path", destination,
                "--execute",
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes fetch-attachment", markers: [
            "PWNDFETCHNOTEID", "PWNDFETCHATTID",
        ]) {
            let runner = self.savingRunner()
            let command = try FetchAttachmentCmd.parse([
                "--note-id", hostilePayload("PWNDFETCHNOTEID"),
                "--attachment-id", hostilePayload("PWNDFETCHATTID"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes show-attachment", markers: [
            "PWNDSHOWATTNOTEID", "PWNDSHOWATTID",
        ]) {
            let runner = FakeNotesRunner(results: [""])
            let command = try ShowAttachmentCmd.parse([
                "--note-id", hostilePayload("PWNDSHOWATTNOTEID"),
                "--attachment-id", hostilePayload("PWNDSHOWATTID"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes attachments", markers: [
            "PWNDATTACHTITLE", "PWNDATTACHACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test attached", id: fixtureNoteID(7)),
                "", // no attachments
            ])
            let command = try AttachmentsCmd.parse([
                "--title", hostilePayload("PWNDATTACHTITLE"),
                "--account", hostilePayload("PWNDATTACHACCOUNT"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        // MARK: reveal-in-UI commands

        rows.append(ArgvCase(command: "notes show-note", markers: ["PWNDSHOWNOTEID"]) {
            let runner = FakeNotesRunner(results: [""])
            let command = try ShowNoteCmd.parse(["--id", hostilePayload("PWNDSHOWNOTEID")])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes show-folder", markers: ["PWNDSHOWFOLDERID"]) {
            let runner = FakeNotesRunner(results: [""])
            let command = try ShowFolderCmd.parse(["--id", hostilePayload("PWNDSHOWFOLDERID")])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes show-account", markers: ["PWNDSHOWACCOUNTID"]) {
            let runner = FakeNotesRunner(results: [""])
            let command = try ShowAccountCmd.parse(["--id", hostilePayload("PWNDSHOWACCOUNTID")])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        // MARK: read commands

        rows.append(ArgvCase(command: "notes search", markers: [
            "PWNDQUERY", "PWNDSEARCHFOLDER", "PWNDSEARCHACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [""]) // no matches
            let command = try SearchCmd.parse([
                hostilePayload("PWNDQUERY"),
                "--folder", hostilePayload("PWNDSEARCHFOLDER"),
                "--account", hostilePayload("PWNDSEARCHACCOUNT"),
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) },
                                storeFactory: { StubNotesStore.quiet() })
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes list", markers: [
            "PWNDLISTFOLDER", "PWNDLISTACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [""]) // no titles
            let command = try ListCmd.parse([
                "--folder", hostilePayload("PWNDLISTFOLDER"),
                "--account", hostilePayload("PWNDLISTACCOUNT"),
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) },
                                storeFactory: { StubNotesStore.quiet() })
            }
            return runner
        })

        // This row exercises PASS 1 only: the empty reply below leaves no winners, so pass 2 is
        // skipped. That is acceptable rather than a gap — pass-2 argv carries nothing but note
        // ids Notes.app itself issued in pass 1, never user text, so "argv-only" is not the
        // property protecting it. A hostile-id row would still make the matrix's coverage match
        // its header claim; noted as a follow-up.
        rows.append(ArgvCase(command: "notes recent", markers: [
            "PWNDRECENTFOLDER", "PWNDRECENTACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [""]) // no notes in scope
            let command = try RecentCmd.parse([
                "--folder", hostilePayload("PWNDRECENTFOLDER"),
                "--account", hostilePayload("PWNDRECENTACCOUNT"),
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) },
                                storeFactory: { StubNotesStore.quiet() })
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes folders", markers: ["PWNDFOLDERSACCOUNT"]) {
            let runner = FakeNotesRunner(results: [""]) // no folders
            let command = try FoldersCmd.parse(["--account", hostilePayload("PWNDFOLDERSACCOUNT")])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) },
                                storeFactory: { StubNotesStore.quiet() })
            }
            return runner
        })

        rows.append(ArgvCase(command: "notes get", markers: [
            "PWNDGETTITLE", "PWNDGETACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test titled", id: fixtureNoteID(8)),
                "<div>titled body</div>",
            ])
            let command = try GetCmd.parse([
                "--title", hostilePayload("PWNDGETTITLE"),
                "--account", hostilePayload("PWNDGETACCOUNT"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes get-plaintext", markers: [
            "PWNDPLAINTITLE", "PWNDPLAINACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test plain", id: fixtureNoteID(9)),
                "<div>plain body</div>",
            ])
            let command = try GetPlaintextCmd.parse([
                "--title", hostilePayload("PWNDPLAINTITLE"),
                "--account", hostilePayload("PWNDPLAINACCOUNT"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes get-markdown", markers: [
            "PWNDMDTITLE", "PWNDMDACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test md", id: fixtureNoteID(10)),
                "<div>md body</div>",
            ])
            let command = try GetMarkdownCmd.parse([
                "--title", hostilePayload("PWNDMDTITLE"),
                "--account", hostilePayload("PWNDMDACCOUNT"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes get-details", markers: [
            "PWNDDETAILSTITLE", "PWNDDETAILSACCOUNT",
        ]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test details", id: fixtureNoteID(11)),
            ])
            let command = try GetDetailsCmd.parse([
                hostilePayload("PWNDDETAILSTITLE"),
                "--account", hostilePayload("PWNDDETAILSACCOUNT"),
            ])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes get-by-id", markers: ["PWNDBYID"]) {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test by id", id: fixtureNoteID(12)),
            ])
            let command = try GetByIdCmd.parse(["--id", hostilePayload("PWNDBYID")])
            _ = try captureNotesEnvelope { try command.run(scriptFactory: { quietScript(runner) }) }
            return runner
        })

        rows.append(ArgvCase(command: "notes get-link", markers: [
            "PWNDLINKTITLE", "PWNDLINKACCOUNT",
        ]) {
            // The store answers the link, so the AppleScript fallback never runs and the single
            // call is the by-title lookup that carries both markers.
            let store = StubNotesStore.quiet()
            store.link = "notes://showNote?identifier=SYNTHETIC"
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test linked", id: fixtureNoteID(13)),
            ])
            let command = try GetNoteLinkCmd.parse([
                "--title", hostilePayload("PWNDLINKTITLE"),
                "--account", hostilePayload("PWNDLINKACCOUNT"),
            ])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                                storeFactory: { store })
            }
            return runner
        })

        return rows
    }

    @Test("every user-controlled parameter of every script-building command travels as argv only")
    func theWholeMatrix() throws {
        let rows = cases()
        // A guard against the matrix silently shrinking under a refactor: the assertions below are
        // vacuously true over an empty array, and a `>=` floor set below the real count lets rows
        // be deleted while still passing — which is the exact failure this line exists to prevent.
        // EXACT, therefore: adding or removing a command from the matrix must be a deliberate edit
        // here, made alongside the exclusion list in this file's header.
        #expect(rows.count == 25, "the matrix must not change size without a deliberate edit")
        for row in rows {
            let runner = try row.exercise()
            #expect(!runner.neverCalled, "\(row.command): the case must actually reach a script")
            for marker in row.markers {
                expectArgvOnly(runner, marker, "\(row.command) [\(marker)]")
            }
        }
    }

    @Test("the id parameters excluded from the matrix are refused before any script is built")
    func structurallyConstrainedIdsNeverReachAScript() throws {
        // The header claims `--ids` and `get-link --id` are protected by something stronger than
        // argv-passing: `isValidNoteId` is anchored (`^…$`), so a value carrying a breakout payload
        // cannot match and never reaches a script in ANY form. Asserted rather than assumed,
        // because "excluded from the matrix" is otherwise indistinguishable from "forgotten".
        let hostileId = hostilePayload("PWNDIDSHAPE")
        #expect(NotesScript.isValidNoteId(hostileId) == false)

        // batch-delete: the invalid id is reported per-item and no script runs at all.
        let batchRunner = ThrowingNotesRunner()
        let batch = try BatchDeleteCmd.parse(["--ids", hostileId, "--execute"])
        _ = try captureNotesFailure {
            try batch.run(scriptFactory: { quietScript(batchRunner) }, env: pinnedWriteEnv())
        }
        #expect(batchRunner.neverCalled, "batch-delete must not reach Notes.app for an invalid id")

        // get-link: `requireSelector` refuses the malformed id up front.
        let linkRunner = ThrowingNotesRunner()
        let link = try GetNoteLinkCmd.parse(["--id", hostileId])
        let failure = try captureNotesFailure {
            try link.run(scriptFactory: { quietScript(linkRunner) },
                         storeFactory: { StubNotesStore.quiet() })
        }
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(linkRunner.neverCalled, "get-link must not reach Notes.app for an invalid id")
    }
}
