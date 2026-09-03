import Foundation
import Testing
import ArgumentParser
import TestSupport
@testable import NotesKit
@testable import AppleKit

// Branches inside the `NotesScript` wrappers and the shared helpers that the command-level suites
// do not reach on their happy paths: the filtered list/search variants, the nested folder-creation
// leg, the degenerate parse shapes, and the two attachment failure classes.
//
// Same boundaries as the rest of the lane: `FakeNotesRunner` for Notes.app, `StubNotesStore` for
// `NoteStore.sqlite`, `ScratchDirs` for anything on disk.

@Suite("NotesScript wrappers — filters, nesting, and degenerate rows")
struct NotesScriptWrapperBranchTests {

    @Test func bareNotesCommandRequestsHelpRatherThanRunningAnOperation() {
        #expect(throws: CleanExit.self) { try NotesCommand().run() }
    }

    // MARK: list / search filters

    @Test func listWithAFolderAndDateFilterBuildsAScopedQuery() throws {
        let runner = FakeNotesRunner(results: ["apple-cli-test one" + RS])
        let command = try ListCmd.parse([
            "--folder", "Work/Projects", "--modified-since", "2026-01-01", "--account", "Example Account",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) },
                            storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["count"] as? Int == 1)
        // Each path segment travels as its own argv item; the specifier itself references argv.
        #expect(runner.allArguments.contains("Work"))
        #expect(runner.allArguments.contains("Projects"))
        #expect(runner.scripts.first?.contains("Projects") == false)
        // The date threshold is the ONE user-supplied value that legitimately reaches the script
        // SOURCE — `dateVarSetup` renders it as model-derived integers, never as text, so there is
        // no argv item to assert against (unlike every other user parameter in this port). Assert
        // the rendered VALUE, then, not merely that the filter was applied: `contains("thresholdDate")`
        // alone survives any mis-parse of `--modified-since` (wrong year, wrong unit, a timezone
        // slip), which is the bug class this repo keeps hitting on dates.
        let script = try #require(runner.scripts.first)
        #expect(script.contains("set year of thresholdDate to 2026"))
        #expect(script.contains("set month of thresholdDate to 1"))
        #expect(script.contains("set day of thresholdDate to 1"))
        // Local midnight: `parseISODateOrThrow` reads a bare `yyyy-MM-dd` in `TimeZone.current`
        // and `dateVarSetup` decomposes it in the same zone, so this is host-independent.
        #expect(script.contains("set time of thresholdDate to 0"))
    }

    @Test func searchWithAFolderAndDateFilterBuildsAScopedQuery() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try SearchCmd.parse([
            "milk", "--folder", "Work/Projects", "--modified-since", "2026-01-01T08:00:00",
        ])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        #expect(runner.allArguments.contains("milk"))
        #expect(runner.allArguments.contains("Projects"))
        #expect(runner.scripts.first?.contains("milk") == false)
        // Same reasoning as the list case above, on the form that carries a TIME: 08:00:00 local
        // must render as 28800 seconds. A unit slip (minutes, milliseconds) or a UTC pin in either
        // half of the bridge moves this number and nothing else in the suite would notice.
        let script = try #require(runner.scripts.first)
        #expect(script.contains("set year of thresholdDate to 2026"))
        #expect(script.contains("set month of thresholdDate to 1"))
        #expect(script.contains("set day of thresholdDate to 1"))
        #expect(script.contains("set time of thresholdDate to 28800"))
    }

    @Test func theNonPositiveLimitGuardAlsoLivesAtTheScriptWrappers() {
        // Enforced at the sink, not only at the CLI boundary: the emitted `exit repeat` check sits
        // after the append, so limit 0 would behave as 1 for any non-command caller.
        let script = quietScript(ThrowingNotesRunner())
        #expect(throws: AppleError.self) {
            _ = try script.listNotes(account: nil, folder: nil, modifiedSince: nil, limit: 0)
        }
        #expect(throws: AppleError.self) {
            _ = try script.searchNotes(query: "x", searchContent: false, account: nil,
                                       folder: nil, modifiedSince: nil, limit: 0)
        }
    }

    @Test func acceptsIsoDateFormsAndRejectsGarbage() throws {
        // Each accepted form is pinned to an INSTANT, not merely to non-nil: a `!= nil` assertion
        // passes for any regression that parses to the wrong moment (a timezone slip, a
        // format-order change putting a lenient pattern first), which is the exact bug class this
        // repo keeps hitting on dates.
        func instant(_ timeZone: TimeZone, _ components: DateComponents) throws -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return try #require(calendar.date(from: components))
        }
        let utc = try #require(TimeZone(identifier: "UTC"))

        #expect(try parseISODateOrThrow(nil) == nil)
        #expect(try parseISODateOrThrow("") == nil)
        // A bare date and a space-separated stamp are parsed in the CURRENT zone (the fallback
        // DateFormatter sets `timeZone = .current`), so the expectation is built the same way and
        // the test is machine-timezone-agnostic rather than pinned to one offset.
        #expect(try parseISODateOrThrow("2026-01-15")
                == instant(.current, DateComponents(year: 2026, month: 1, day: 15)))
        #expect(try parseISODateOrThrow("2026-01-15 08:30:00")
                == instant(.current, DateComponents(year: 2026, month: 1, day: 15,
                                                    hour: 8, minute: 30, second: 0)))
        // The `Z` form goes through ISO8601DateFormatter and is absolute.
        #expect(try parseISODateOrThrow("2026-01-15T08:30:00Z")
                == instant(utc, DateComponents(year: 2026, month: 1, day: 15,
                                               hour: 8, minute: 30, second: 0)))
        #expect(throws: AppleError.self) { _ = try parseISODateOrThrow("15/01/2026") }
    }

    // MARK: update read-back

    @Test func aPlaintextUpdateWithNoNewTitleReadsTheExistingTitleBack() throws {
        // The body rewrite must keep the note's current first line, so the wrapper fetches it.
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test kept", id: fixtureNoteID(1)), // the command's lookup
            noteRow(title: "apple-cli-test kept", id: fixtureNoteID(1)), // the wrapper's read-back
            "",                                                          // the write
        ])
        let command = try UpdateCmd.parse([
            "--id", fixtureNoteID(1), "--new-content", "fresh body", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["title"] as? String == "apple-cli-test kept")
        #expect(runner.invocationCount == 3, "the plaintext path reads the title back before writing")
        #expect(runner.arguments.last?.last?.contains("apple-cli-test kept") == true)
    }

    // MARK: folder path building

    @Test func aFolderWhoseParentIsMissingRendersAsABareName() {
        // The parent id is not in the result set (a folder outside the queried account), so the
        // path cannot be walked and the name stands alone rather than being dropped.
        let out = ["F2", "Orphan", "MISSING-PARENT", "false"].joined(separator: US) + RS
        let folders = NotesScript.buildFolderPaths(out, account: "Example Account")

        #expect(folders.count == 1)
        #expect(folders.first?.name == "Orphan")
    }

    @Test func aSlashInAFolderNameIsEscapedRatherThanTreatedAsNesting() {
        let out = ["F1", "Q1/Q2", "", "false"].joined(separator: US) + RS
        let folders = NotesScript.buildFolderPaths(out, account: "Example Account")

        #expect(folders.first?.name == "Q1\\/Q2")
        // …and splitting that escaped form round-trips to a single component.
        #expect(NotesScript.splitFolderPath("Q1\\/Q2") == ["Q1/Q2"])
    }

    @Test func createFolderCreatesAnIntermediateSegmentAtItsParent() throws {
        // The first segment exists, the second does not: the wrapper must issue a
        // `make new folder at <parent>` rather than a top-level create.
        let runner = FakeNotesRunner()
        var probes = 0
        runner.handler = { script, _ in
            if script.contains("make new folder") { return "" }
            if script.contains("return id of") {
                probes += 1
                if probes == 1 { return "folder id F1" }   // segment 1 exists
                if probes == 2 { throw AppleError.notFound("no such folder") } // segment 2 missing
                return "folder id F2"                       // final resolution
            }
            return nil
        }
        let command = try CreateFolderCmd.parse(["apple-cli-test a/apple-cli-test b", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["folder"] as? String == "apple-cli-test a/apple-cli-test b")
        let nested = try #require(runner.scripts.first { $0.contains("make new folder at") })
        #expect(nested.contains("folder (item 2 of argv)"), "the parent is referenced through argv")
        #expect(nested.contains("apple-cli-test a") == false)
    }

    // MARK: degenerate account rows

    @Test func anAccountRowWithOnlyANameStillParses() throws {
        // Older Notes releases return a bare name with no separators at all.
        let runner = FakeNotesRunner(results: ["Example Account" + RS])
        let command = try AccountsCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        let accounts = try #require(data["accounts"] as? [[String: Any]])
        #expect(accounts.first?["name"] as? String == "Example Account")
        #expect(accounts.first?["id"] == nil)
        #expect(accounts.first?["upgraded"] == nil)
    }

    // MARK: get-link title-path failure

    @Test func getLinkClassifiesATitlePathFailureFromTheStorePresence() throws {
        let store = StubNotesStore()
        store.link = nil
        store.storeExists = false
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test link", id: fixtureNoteID(2)),
            "   ", // the AppleScript fallback yields nothing
        ])
        let command = try GetNoteLinkCmd.parse(["--title", "apple-cli-test link"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(failure.code == AppleExit.permissionDenied)
        #expect((failure.error["message"] as? String)?.contains("apple-cli-test link") == true)
    }

    // MARK: oversized content

    @Test func contentAboveTheOracleBoundIsRefusedBeforeAnyScriptRuns() throws {
        let runner = ThrowingNotesRunner()
        let oversized = String(repeating: "x", count: NotesLimits.content + 1)
        let command = try CreateCmd.parse(["apple-cli-test note", "--content", oversized, "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("content exceeds maximum length") == true)
        #expect(runner.neverCalled)
    }
}

@Suite("Notes attachment filesystem guards")
struct NotesAttachmentFilesystemGuardTests {
    private let scratch = ScratchDirs("notes-attachment-fs")

    @Test func savingThroughASymlinkedFinalLeafIsRefusedAsASafetyViolation() throws {
        let dir = try scratch.directory()
        let target = dir.appendingPathComponent("real.png")
        try Data("payload".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // Straight at the wrapper: the command refuses earlier, so this is the only way to reach
        // the wrapper's own typed re-check — which exists as defense in depth for other callers.
        let script = NotesScript(runner: ThrowingNotesRunner(), store: StubNotesStore.quiet())
        let error = #expect(throws: AppleError.self) {
            _ = try script.saveAttachmentById(noteId: fixtureNoteID(1), attachmentId: "ATT1",
                                              savePath: link.path)
        }

        #expect(error?.type == AppleErrorType.safetyViolation)
        #expect(error?.exitCode == 77)
    }

    @Test func theCommandRefusesASymlinkedDestinationOnBothPaths() throws {
        let dir = try scratch.directory()
        let target = dir.appendingPathComponent("real.png")
        try Data("payload".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try SaveAttachmentCmd.parse([
                "--note-id", fixtureNoteID(1), "--attachment-id", "ATT1", "--path", link.path, extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                env: pinnedWriteEnv())
            }

            #expect(failure.code == 77, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.safetyViolation)
            #expect(runner.neverCalled)
        }
    }

    @Test func theBase64ReaderRefusesAFileOverItsCap() throws {
        let file = try scratch.directory().appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 64).write(to: file)

        // The cap is a parameter, so the over-limit branch is reachable without writing 25 MB.
        let error = #expect(throws: AttachmentFS.FSError.self) {
            _ = try AttachmentFS.readFileBase64Capped(file.path, maxBytes: 8)
        }
        #expect(error?.description.contains("exceeding the 8-byte fetch limit") == true)
        #expect(error?.description.contains("save-attachment") == true)

        // Under the cap it round-trips.
        #expect(try AttachmentFS.readFileBase64Capped(file.path, maxBytes: 128)
                == Data(repeating: 0x41, count: 64).base64EncodedString())
    }

    @Test func anEmptyOrRelativeDestinationIsRejectedByTheLexicalGuard() {
        #expect(throws: AttachmentFS.FSError.self) { _ = try AttachmentFS.assertSafeSavePath("   ") }
        #expect(throws: AttachmentFS.FSError.self) { _ = try AttachmentFS.assertSafeSavePath("rel.png") }
        #expect(throws: AttachmentFS.FSError.self) { _ = try AttachmentFS.assertSafeSavePath("/etc/x.png") }
    }
}

@Suite("Protobuf + gzip decoding edges")
struct NotesProtobufEdgeTests {

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    @Test func fixedWidthWireTypesAreSkippedRatherThanMisreadAsLengths() {
        // fixed32 (wire type 5) then a varint field: the decoder must step over 4 bytes exactly.
        let fixed32 = varint(UInt64(1 << 3 | 5)) + [0xDE, 0xAD, 0xBE, 0xEF]
        let trailing = varint(UInt64(2 << 3 | 0)) + varint(7)
        let fields32 = Protobuf.decodeMessage(fixed32 + trailing)
        #expect(Protobuf.varintValue(Protobuf.field(fields32, 2)) == 7)

        // fixed64 (wire type 1): 8 bytes.
        let fixed64 = varint(UInt64(1 << 3 | 1)) + [UInt8](repeating: 0x11, count: 8)
        let fields64 = Protobuf.decodeMessage(fixed64 + trailing)
        #expect(Protobuf.varintValue(Protobuf.field(fields64, 2)) == 7)
    }

    @Test func anUnknownWireTypeStopsTheWalkWithWhatWasAlreadyRead() {
        let good = varint(UInt64(1 << 3 | 0)) + varint(5)
        let unknown = varint(UInt64(2 << 3 | 3)) // start-group: not handled
        let fields = Protobuf.decodeMessage(good + unknown + [0x00])

        #expect(Protobuf.varintValue(Protobuf.field(fields, 1)) == 5)
        #expect(Protobuf.field(fields, 2) == nil)
    }

    @Test func aTruncatedVarintDecodesToNil() {
        // Every byte has the continuation bit set and the buffer ends — there is no terminator.
        #expect(Protobuf.decodeVarint([0x80, 0x80, 0x80], 0) == nil)
        #expect(Protobuf.decodeMessage([0x80, 0x80, 0x80]).isEmpty)
    }

    @Test func typedAccessorsReturnNilForTheWrongShape() {
        let fields = Protobuf.decodeMessage(varint(UInt64(1 << 3 | 0)) + varint(9))
        #expect(Protobuf.field(fields, 4) == nil)
        #expect(Protobuf.stringValue(Protobuf.field(fields, 1)) == nil)
        #expect(Protobuf.bytesValue(Protobuf.field(fields, 1)) == nil)
        #expect(Protobuf.embeddedMessage(Protobuf.field(fields, 1)) == nil)
        #expect(Protobuf.varintValue(nil) == nil)
        #expect(Protobuf.fields(fields, 4).isEmpty)
    }

    @Test func theGzipHeaderWalkerStepsOverTheOptionalExtraAndNameFields() {
        // FEXTRA|FNAME|FCOMMENT set, then a deliberately truncated deflate body: the header walk
        // has to consume the optional sections before it can fail on the body, which is what makes
        // this a test of the header walk rather than of the inflater.
        var stream: [UInt8] = [0x1F, 0x8B, 0x08, 0x04 | 0x08 | 0x10, 0, 0, 0, 0, 0, 0]
        stream += [0x02, 0x00, 0xAA, 0xBB]      // FEXTRA: 2-byte payload
        stream += Array("name".utf8) + [0x00]   // FNAME
        stream += Array("comment".utf8) + [0x00] // FCOMMENT
        // No deflate payload at all.

        #expect(throws: (any Error).self) { _ = try Gzip.inflate(stream) }

        // A stream whose FNAME is unterminated fails in the same walk.
        var unterminated: [UInt8] = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0]
        unterminated += Array("no-terminator".utf8)
        #expect(throws: (any Error).self) { _ = try Gzip.inflate(unterminated) }
    }

    @Test func aNonGzipBufferIsRejected() {
        #expect(throws: (any Error).self) { _ = try Gzip.inflate([0x00, 0x01, 0x02]) }
        #expect(throws: (any Error).self) { _ = try Gzip.inflate([]) }
    }
}
