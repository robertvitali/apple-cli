import Foundation
import Testing
import ArgumentParser
@testable import NotesKit
@testable import AppleKit

// Every `notes` READ command, driven end to end through the injected boundaries: the envelope it
// writes to stdout, and — on each failure branch — BOTH the `error.type` an agent switches on and
// the process exit code it sees. Asserting only the message would leave the machine-facing half of
// the contract untested, which is the half that actually breaks callers.
//
// Nothing here reaches Notes.app or `NoteStore.sqlite`: `FakeNotesRunner`/`ThrowingNotesRunner`
// answer the AppleScript boundary and `StubNotesStore` the SQLite one. See `NotesInjectionFakes`.

@Suite("Notes read commands — SQLite-backed (get-checklist, get-metadata)")
struct NotesStoreBackedReadCommandTests {

    private func metadata(passwordProtected: Bool? = nil, pinned: Bool? = nil,
                          snippet: String? = nil) -> NotesMetadata {
        var md = NotesMetadata()
        md.password_protected = passwordProtected
        md.pinned = pinned
        md.snippet = snippet
        return md
    }

    // MARK: get-checklist

    @Test func checklistEmitsItemsAndDoneCounts() throws {
        let store = StubNotesStore()
        store.checklistOutcome = NotesStore.ChecklistOutcome(
            items: [NotesStore.ChecklistItem(text: "apple-cli-test buy milk", done: true),
                    NotesStore.ChecklistItem(text: "apple-cli-test walk dog", done: false)],
            error: nil, message: nil)
        let command = try GetChecklistCmd.parse(["--id", fixtureNoteID(1)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(storeFactory: { store })
        })

        #expect(data["checked"] as? Int == 1)
        #expect(data["total"] as? Int == 2)
        let items = try #require(data["items"] as? [[String: Any]])
        #expect(items.first?["text"] as? String == "apple-cli-test buy milk")
        #expect(items.first?["done"] as? Bool == true)
        #expect(store.checklistQueries == [fixtureNoteID(1)])
    }

    @Test func checklistRefusesAPasswordProtectedNoteBeforeReadingAnyChecklistData() throws {
        let store = StubNotesStore()
        store.metadataOutcome = NotesStore.MetadataOutcome(
            metadata: metadata(passwordProtected: true), error: nil, message: nil)
        let command = try GetChecklistCmd.parse(["--id", fixtureNoteID(1)])

        let failure = try captureNotesFailure { try command.run(storeFactory: { store }) }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect((failure.error["message"] as? String)?.contains("password-protected") == true)
        // The refusal has to precede the checklist read, not merely accompany it.
        #expect(store.checklistQueries.isEmpty)
    }

    @Test func checklistMapsEveryStoreErrorToItsOwnTypeAndExitCode() throws {
        let cases: [(NotesStore.ChecklistError, String, Int32)] = [
            (.invalidId, AppleErrorType.validation, AppleExit.usage),
            (.noFDA, AppleErrorType.permissionDenied, AppleExit.permissionDenied),
            (.noChecklists, AppleErrorType.notFound, AppleExit.notFound),
            (.parseError, AppleErrorType.upstream, AppleExit.upstream),
        ]
        for (storeError, type, code) in cases {
            let store = StubNotesStore()
            store.checklistOutcome = NotesStore.ChecklistOutcome(
                items: nil, error: storeError, message: "synthetic \(storeError.rawValue)")
            let command = try GetChecklistCmd.parse(["--id", fixtureNoteID(2)])

            let failure = try captureNotesFailure { try command.run(storeFactory: { store }) }

            #expect(failure.code == code, "exit code for \(storeError.rawValue)")
            #expect(failure.error["type"] as? String == type, "error.type for \(storeError.rawValue)")
            #expect(failure.error["message"] as? String == "synthetic \(storeError.rawValue)")
        }
    }

    @Test func checklistFallsBackToTheCannedMessageWhenTheStoreSuppliesNone() throws {
        let store = StubNotesStore()
        store.checklistOutcome = NotesStore.ChecklistOutcome(items: nil, error: .noFDA, message: nil)
        let command = try GetChecklistCmd.parse(["--id", fixtureNoteID(2)])

        let failure = try captureNotesFailure { try command.run(storeFactory: { store }) }

        #expect(failure.error["message"] as? String == NotesStore.fdaChecklistMessage)
    }

    @Test func checklistTextRenderingMarksDoneItems() throws {
        let store = StubNotesStore()
        store.checklistOutcome = NotesStore.ChecklistOutcome(
            items: [NotesStore.ChecklistItem(text: "done item", done: true),
                    NotesStore.ChecklistItem(text: "open item", done: false)],
            error: nil, message: nil)
        let command = try GetChecklistCmd.parse(["--id", fixtureNoteID(1), "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(storeFactory: { store }) }
        let text = String(decoding: stdout.data, as: UTF8.self)

        #expect(text.contains("Checklist (1/2 done):"))
        #expect(text.contains("[x] done item"))
        #expect(text.contains("[ ] open item"))
    }

    // MARK: get-metadata

    @Test func metadataEmitsTheScalarColumnsTheStoreReturned() throws {
        let store = StubNotesStore()
        store.metadataOutcome = NotesStore.MetadataOutcome(
            metadata: metadata(pinned: true, snippet: "apple-cli-test snippet"), error: nil, message: nil)
        let command = try GetMetadataCmd.parse(["--id", fixtureNoteID(3)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(storeFactory: { store })
        })

        #expect(data["pinned"] as? Bool == true)
        #expect(data["snippet"] as? String == "apple-cli-test snippet")
        #expect(store.metadataQueries == [fixtureNoteID(3)])
    }

    @Test func metadataMapsEveryStoreErrorToItsOwnTypeAndExitCode() throws {
        let cases: [(NotesStore.MetadataError, String, Int32)] = [
            (.invalidId, AppleErrorType.validation, AppleExit.usage),
            (.noFDA, AppleErrorType.permissionDenied, AppleExit.permissionDenied),
            (.notFound, AppleErrorType.notFound, AppleExit.notFound),
            (.queryError, AppleErrorType.upstream, AppleExit.upstream),
        ]
        for (storeError, type, code) in cases {
            let store = StubNotesStore()
            store.metadataOutcome = NotesStore.MetadataOutcome(
                metadata: nil, error: storeError, message: "synthetic \(storeError.rawValue)")
            let command = try GetMetadataCmd.parse(["--id", fixtureNoteID(4)])

            let failure = try captureNotesFailure { try command.run(storeFactory: { store }) }

            #expect(failure.code == code, "exit code for \(storeError.rawValue)")
            #expect(failure.error["type"] as? String == type, "error.type for \(storeError.rawValue)")
        }
    }

    @Test func metadataTextRenderingNamesTheNote() throws {
        let store = StubNotesStore()
        let command = try GetMetadataCmd.parse(["--id", fixtureNoteID(5), "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(storeFactory: { store }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("Metadata read for \(fixtureNoteID(5))"))
    }
}

@Suite("Notes read commands — AppleScript-backed metadata + content")
struct NotesScriptBackedReadCommandTests {

    private func script(_ runner: AppleScriptRunning, store: any NotesStoreReading = StubNotesStore.quiet()) -> NotesScript {
        NotesScript(runner: runner, store: store)
    }

    // MARK: get-by-id

    @Test func getByIdEmitsParsedNoteProperties() throws {
        let runner = FakeNotesRunner(results: [noteRow(title: "apple-cli-test note", id: fixtureNoteID(1), shared: true)])
        let command = try GetByIdCmd.parse(["--id", fixtureNoteID(1)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { script(runner) })
        })

        #expect(data["id"] as? String == fixtureNoteID(1))
        #expect(data["title"] as? String == "apple-cli-test note")
        #expect(data["shared"] as? Bool == true)
        #expect(data["password_protected"] as? Bool == false)
        // The id travelled as argv, never as script text.
        #expect(runner.arguments == [[fixtureNoteID(1)]])
        #expect(runner.scripts.first?.contains(fixtureNoteID(1)) == false)
    }

    @Test func getByIdReportsNotFoundWhenThePropertiesRowIsUnparseable() throws {
        let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
        let command = try GetByIdCmd.parse(["--id", fixtureNoteID(9)])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.code == AppleExit.notFound)
        #expect(failure.error["type"] as? String == AppleErrorType.notFound)
    }

    // MARK: get-details

    @Test func getDetailsAddsTheResolvedAccount() throws {
        let runner = FakeNotesRunner(results: [noteRow(title: "apple-cli-test details", id: fixtureNoteID(2))])
        let command = try GetDetailsCmd.parse(["apple-cli-test details", "--account", "Example Account"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { script(runner) })
        })

        #expect(data["title"] as? String == "apple-cli-test details")
        #expect(data["account"] as? String == "Example Account")
        #expect(runner.arguments.first == ["apple-cli-test details", "Example Account"])
    }

    @Test func getDetailsReportsNotFoundForAnUnparseableRow() throws {
        let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
        let command = try GetDetailsCmd.parse(["missing note"])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("missing note") == true)
    }

    // MARK: get (HTML body + hashtags)

    @Test func getByIdPathReturnsStrippedHtmlAndHashtags() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test body", id: fixtureNoteID(3)),
            "<div>hello #alpha and #beta</div>",
        ])
        let command = try GetCmd.parse(["--id", fixtureNoteID(3)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { script(runner) })
        })

        #expect(data["title"] as? String == "apple-cli-test body")
        #expect((data["content"] as? String)?.contains("hello") == true)
        let tags = try #require(data["hashtags"] as? [String])
        #expect(tags.contains("alpha"))
        #expect(tags.contains("beta"))
    }

    @Test func getByTitlePathReturnsBodyForTheNamedNote() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test titled", id: fixtureNoteID(4)),
            "<div>titled body</div>",
        ])
        let command = try GetCmd.parse(["--title", "apple-cli-test titled"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { script(runner) })
        })

        #expect(data["title"] as? String == "apple-cli-test titled")
        #expect((data["content"] as? String)?.contains("titled body") == true)
    }

    @Test func getRefusesAPasswordProtectedNoteOnBothSelectorPaths() throws {
        for args in [["--id", fixtureNoteID(5)], ["--title", "locked note"]] {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "locked note", id: fixtureNoteID(5), passwordProtected: true),
            ], whenExhausted: .empty)
            let command = try GetCmd.parse(args)

            let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

            #expect(failure.code == AppleExit.usage, "exit for \(args)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect((failure.error["message"] as? String)?.contains("password-protected") == true)
        }
    }

    @Test func getReportsNotFoundWhenTheBodyComesBackEmpty() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test empty", id: fixtureNoteID(6)),
            "",
        ])
        let command = try GetCmd.parse(["--id", fixtureNoteID(6)])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("Failed to read content") == true)
    }

    @Test func getRequiresExactlyOneSelector() throws {
        let runner = ThrowingNotesRunner()
        let command = try GetCmd.parse([])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        #expect(runner.neverCalled, "selector validation must precede any AppleScript call")
    }

    // MARK: get-plaintext

    @Test func plaintextByIdAndByTitleBothEmitTheNativeBody() throws {
        for args in [["--id", fixtureNoteID(7)], ["--title", "apple-cli-test plain"]] {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test plain", id: fixtureNoteID(7)),
                "plain text body",
            ])
            let command = try GetPlaintextCmd.parse(args)

            let data = try notesData(try captureNotesEnvelope {
                try command.run(scriptFactory: { script(runner) })
            })

            #expect(data["plaintext"] as? String == "plain text body")
            #expect(data["title"] as? String == "apple-cli-test plain")
        }
    }

    @Test func plaintextReportsNotFoundOnAnEmptyBody() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test plain", id: fixtureNoteID(7)),
            "",
        ])
        let command = try GetPlaintextCmd.parse(["--id", fixtureNoteID(7)])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("Failed to read plaintext") == true)
    }

    @Test func plaintextRefusesAPasswordProtectedNote() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "locked", id: fixtureNoteID(8), passwordProtected: true),
        ], whenExhausted: .empty)
        let command = try GetPlaintextCmd.parse(["--title", "locked"])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { script(runner) }) }

        #expect(failure.error["type"] as? String == AppleErrorType.validation)
    }

    // MARK: get-markdown

    @Test func markdownByIdIsAnnotatedFromTheInjectedStore() throws {
        let store = StubNotesStore()
        store.checklistOutcome = NotesStore.ChecklistOutcome(
            items: [NotesStore.ChecklistItem(text: "task one", done: true)], error: nil, message: nil)
        let runner = FakeNotesRunner(results: ["<div>task one</div>"])
        let command = try GetMarkdownCmd.parse(["--id", fixtureNoteID(9)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) })
        })

        #expect((data["markdown"] as? String)?.contains("task one") == true)
        #expect(store.checklistQueries == [fixtureNoteID(9)], "markdown must read the INJECTED store")
    }

    @Test func markdownByTitleRendersTheBody() throws {
        let runner = FakeNotesRunner(results: [
            "<div>plain paragraph</div>",
            noteRow(title: "apple-cli-test md", id: fixtureNoteID(10)),
        ])
        let command = try GetMarkdownCmd.parse(["--title", "apple-cli-test md"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) })
        })

        #expect((data["markdown"] as? String)?.contains("plain paragraph") == true)
    }

    @Test func markdownReportsNotFoundWhenTheNoteHasNoContent() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try GetMarkdownCmd.parse(["--id", fixtureNoteID(11)])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) })
        }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("no content") == true)
    }

    // MARK: selected

    @Test func selectedEmitsTheUiSelection() throws {
        let row = [fixtureNoteID(12), "apple-cli-test selected", fixtureDate, fixtureDate,
                   "false", "false", "Folder", "Example Account"].joined(separator: US)
        let runner = FakeNotesRunner(results: [row + RS])
        let command = try SelectedCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { script(runner) })
        })

        #expect(data["count"] as? Int == 1)
        let notes = try #require(data["notes"] as? [[String: Any]])
        #expect(notes.first?["title"] as? String == "apple-cli-test selected")
        #expect(notes.first?["folder"] as? String == "Folder")
    }

    @Test func selectedTextRenderingSaysSoWhenNothingIsSelected() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try SelectedCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(scriptFactory: { script(runner) }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No notes selected."))
    }
}

@Suite("Notes read commands — list + search")
struct NotesListSearchCommandTests {

    private func syncingStore(pending: Int) -> StubNotesStore {
        let store = StubNotesStore.quiet()
        var status = NotesSyncStatus()
        status.sync_detected = true
        status.pending_upload = pending
        store.sync = status
        return store
    }

    @Test func listEmitsTitlesAndTheAppliedLimit() throws {
        let runner = FakeNotesRunner(results: ["apple-cli-test one" + RS + "apple-cli-test two" + RS])
        let command = try ListCmd.parse(["--limit", "2"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["count"] as? Int == 2)
        #expect(data["applied_limit"] as? Int == 2)
        #expect(data["sync_warning"] == nil)
    }

    @Test func listSurfacesTheSyncWarningFromTheInjectedStore() throws {
        let runner = FakeNotesRunner(results: ["apple-cli-test one" + RS])
        let store = syncingStore(pending: 3)
        let command = try ListCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect((data["sync_warning"] as? String)?.contains("iCloud sync") == true)
    }

    @Test func listRefusesANonPositiveLimitBeforeReachingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try ListCmd.parse(["--limit", "0"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("greater than 0") == true)
        #expect(runner.neverCalled)
    }

    @Test func listRefusesAMalformedModifiedSinceDate() throws {
        let runner = ThrowingNotesRunner()
        let command = try ListCmd.parse(["--modified-since", "not-a-date"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Invalid date") == true)
        #expect(runner.neverCalled)
    }

    @Test func listTextRenderingAppendsTheLimitSuffixOnlyWhenThereAreResults() throws {
        let runner = FakeNotesRunner(results: ["apple-cli-test one" + RS])
        let command = try ListCmd.parse(["--limit", "5", "--text"])
        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }
        #expect(String(decoding: stdout.data, as: UTF8.self).contains("(limit: 5)"))

        let empty = FakeNotesRunner(results: [""])
        let emptyCommand = try ListCmd.parse(["--limit", "5", "--text"])
        let (emptyStreams, emptyStdout) = notesStreams()
        try Output.withStreams(emptyStreams) {
            try emptyCommand.run(scriptFactory: { NotesScript(runner: empty, store: StubNotesStore.quiet()) },
                                 storeFactory: { StubNotesStore.quiet() })
        }
        #expect(String(decoding: emptyStdout.data, as: UTF8.self).contains("No notes found."))
    }

    // MARK: search

    private func summaryRows(_ count: Int) -> String {
        (0..<count).map { i in
            ["apple-cli-test hit \(i)", fixtureNoteID(100 + i), "Folder", fixtureDate, fixtureDate]
                .joined(separator: US)
        }.joined(separator: RS) + RS
    }

    @Test func searchAppliesTheOracleDefaultLimitAndReportsIt() throws {
        let runner = FakeNotesRunner(results: [summaryRows(2)])
        let command = try SearchCmd.parse(["milk"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["applied_limit"] as? Int == NotesLimits.defaultSearchLimit)
        #expect(data["limit_was_default"] as? Bool == true)
        #expect(data["limit_reached"] as? Bool == false)
        #expect(data["count"] as? Int == 2)
    }

    @Test func searchFlagsTruncationWhenTheResultCountReachesTheLimit() throws {
        let runner = FakeNotesRunner(results: [summaryRows(2)])
        let command = try SearchCmd.parse(["milk", "--limit", "2"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["limit_reached"] as? Bool == true)
        #expect(data["limit_was_default"] as? Bool == false)
    }

    @Test func searchAllRemovesTheLimitEntirely() throws {
        let runner = FakeNotesRunner(results: [summaryRows(1)])
        let command = try SearchCmd.parse(["milk", "--all", "--content"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["applied_limit"] == nil)
        #expect(data["limit_reached"] as? Bool == false)
    }

    @Test func searchRefusesTheInvalidInputTheOracleSchemaRefuses() throws {
        let cases: [([String], String)] = [
            ([""], "Search query is required"),
            ([String(repeating: "x", count: NotesLimits.query + 1)], "maximum length"),
            (["milk", "--all", "--limit", "5"], "mutually exclusive"),
            (["milk", "--limit", "0"], "greater than 0"),
            (["milk", "--modified-since", "yesterday"], "Invalid date"),
        ]
        for (args, fragment) in cases {
            let runner = ThrowingNotesRunner()
            let command = try SearchCmd.parse(args)

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                storeFactory: { StubNotesStore.quiet() })
            }

            #expect(failure.code == AppleExit.usage, "exit for \(fragment)")
            #expect((failure.error["message"] as? String)?.contains(fragment) == true, "message for \(fragment)")
            #expect(runner.neverCalled, "validation must precede AppleScript for \(fragment)")
        }
    }

    @Test func searchTextRenderingCarriesTheLimitDisclosureAndTruncationNote() throws {
        let runner = FakeNotesRunner(results: [summaryRows(2)])
        let command = try SearchCmd.parse(["milk", "--limit", "2", "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }
        let text = String(decoding: stdout.data, as: UTF8.self)

        #expect(text.contains("(limit: 2)"))
        #expect(text.contains("showing the first 2"))
    }

    @Test func searchTextRenderingCarriesNoLimitInfoOnAZeroMatchQuery() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try SearchCmd.parse(["milk", "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }
        let text = String(decoding: stdout.data, as: UTF8.self)

        #expect(text.contains("No matches."))
        #expect(text.contains("limit:") == false, "the oracle returns early before rendering limit info")
    }
}

@Suite("Notes get-link — selector precedence, SQLite-then-AppleScript resolution, failure class")
struct NotesGetLinkCommandTests {

    private let link = "notes://showNote?identifier=AAAAAAAA-1111-2222-3333-444444444444"

    @Test func linkResolvesFromTheStoreWithoutTheAppleScriptFallback() throws {
        let store = StubNotesStore()
        store.link = link
        let runner = FakeNotesRunner(results: [noteRow(title: "apple-cli-test link", id: fixtureNoteID(1))])
        let command = try GetNoteLinkCmd.parse(["--id", fixtureNoteID(1)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["url"] as? String == link)
        #expect(data["id"] as? String == fixtureNoteID(1))
        // One call only: the properties lookup. The `note link` fallback must not have run.
        #expect(runner.invocationCount == 1)
    }

    @Test func linkFallsBackToTheAppleScriptPropertyWhenTheStoreMisses() throws {
        let store = StubNotesStore()
        store.link = nil
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test link", id: fixtureNoteID(2)),
            "  \(link)  ",
        ])
        let command = try GetNoteLinkCmd.parse(["--id", fixtureNoteID(2)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["url"] as? String == link, "the fallback output is trimmed")
        #expect(runner.invocationCount == 2)
    }

    @Test func linkOmitsTheIdKeyOnTheTitlePath() throws {
        let store = StubNotesStore()
        store.link = link
        let runner = FakeNotesRunner(results: [noteRow(title: "apple-cli-test link", id: fixtureNoteID(3))])
        let command = try GetNoteLinkCmd.parse(["--title", "apple-cli-test link"])

        let envelope = try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }
        let data = try notesData(envelope)

        #expect(data["title"] as? String == "apple-cli-test link")
        #expect(data.keys.contains("id") == false, "the oracle omits id on the title path")
        #expect(store.linkQueries == [fixtureNoteID(3)], "the title path resolves via the FETCHED id")
    }

    @Test func linkClassifiesAFailureByWhetherTheStoreFileIsPresent() throws {
        for (exists, type, code) in [(true, AppleErrorType.upstream, AppleExit.upstream),
                                     (false, AppleErrorType.permissionDenied, AppleExit.permissionDenied)] {
            let store = StubNotesStore()
            store.link = nil
            store.storeExists = exists
            // Empty fallback output ⇒ resolveLink returns nil ⇒ the link-failure branch.
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test link", id: fixtureNoteID(4)),
                "   ",
            ])
            let command = try GetNoteLinkCmd.parse(["--id", fixtureNoteID(4)])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                                storeFactory: { store })
            }

            #expect(failure.code == code, "exit for dbExists=\(exists)")
            #expect(failure.error["type"] as? String == type, "type for dbExists=\(exists)")
            #expect((failure.error["message"] as? String)?.contains("Failed to get note link") == true)
        }
    }

    @Test func linkRestoresTheOracleWordingWhenTheLookupThrowsNotFound() throws {
        let store = StubNotesStore()
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in throw AppleError.notFound("Notes could not find the requested item.") }
        let command = try GetNoteLinkCmd.parse(["--id", fixtureNoteID(5)])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(failure.code == AppleExit.notFound)
        #expect(failure.error["message"] as? String == "Note with ID \"\(fixtureNoteID(5))\" not found")
    }

    @Test func linkUsesTheOracleTitleMissWording() throws {
        let store = StubNotesStore()
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in throw AppleError.notFound("Notes could not find the requested item.") }
        let command = try GetNoteLinkCmd.parse(["--title", "no such note"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(failure.error["message"] as? String == GetNoteLinkCmd.titleNotFound("no such note"))
    }

    @Test func linkRefusesAPasswordProtectedNoteOnBothPaths() throws {
        for args in [["--id", fixtureNoteID(6)], ["--title", "locked"]] {
            let store = StubNotesStore()
            store.link = link
            let runner = FakeNotesRunner(results: [
                noteRow(title: "locked", id: fixtureNoteID(6), passwordProtected: true),
            ], whenExhausted: .empty)
            let command = try GetNoteLinkCmd.parse(args)

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                                storeFactory: { store })
            }

            #expect(failure.code == AppleExit.usage, "exit for \(args)")
            #expect((failure.error["message"] as? String)?.contains("password-protected") == true)
        }
    }

    @Test func linkSelectorValidationMatchesTheOracleTruthiness() throws {
        // A malformed id is a validation error even when a title is also supplied: the oracle runs
        // `sanitizeId` first, so the id wins and never falls through to the title.
        let store = StubNotesStore()
        let runner = ThrowingNotesRunner()
        let malformed = try GetNoteLinkCmd.parse(["--id", "not-an-id", "--title", "fallback"])

        let failure = try captureNotesFailure {
            try malformed.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                              storeFactory: { store })
        }
        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Invalid note ID format") == true)
        #expect(runner.neverCalled)

        // Neither selector is a different validation error, with the oracle's wording.
        let neither = try GetNoteLinkCmd.parse([])
        let missing = try captureNotesFailure {
            try neither.run(scriptFactory: { NotesScript(runner: ThrowingNotesRunner(), store: store) },
                            storeFactory: { store })
        }
        #expect(missing.error["message"] as? String == "Either 'id' or 'title' is required")

        // An EMPTY id is absent under JS truthiness, so a supplied title takes over.
        #expect(throws: Never.self) {
            _ = try GetNoteLinkCmd.requireSelector(id: "", title: "fallback")
        }
    }

    @Test func linkTextRenderingPrintsTheBareUrl() throws {
        let store = StubNotesStore()
        store.link = link
        let runner = FakeNotesRunner(results: [noteRow(title: "apple-cli-test link", id: fixtureNoteID(7))])
        let command = try GetNoteLinkCmd.parse(["--id", fixtureNoteID(7), "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(String(decoding: stdout.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == link)
    }
}
