import Foundation
import Testing
import ArgumentParser
@testable import NotesKit
@testable import AppleKit

// Folder / account commands and the two batch commands, driven through the injected AppleScript
// boundary. Same two structural invariants as the write suite: a preview reaches nothing (asserted
// with `ThrowingNotesRunner`), and user text travels as argv, never as script source.

@Suite("Notes folders + accounts")
struct NotesOrgCommandTests {

    private func folderRow(id: String, name: String, parent: String = "", shared: Bool = false) -> String {
        [id, name, parent, String(shared)].joined(separator: US)
    }

    /// A runner that can answer the sandboxed `delete-folder` CASCADE enumeration: one
    /// `listFolders` for the account, one `listNotes` per folder in the cascade, then the delete.
    ///
    /// Answered by SCRIPT rather than by call order, because the number of `listNotes` calls is a
    /// function of how many descendants the folder list contains — an ordered queue would encode
    /// the very shape each test is trying to vary. `notes` is keyed by the resolved folder PATH,
    /// which the enumeration passes as the leading argv items (`folderRefExpr`) with the account
    /// last, so the key is reconstructed the same way the specifier is built.
    /// `unreadable` is the per-folder count of notes Notes.app could not report — the first row
    /// of the cascade enumeration's output (`listCascadeNotes`), zero unless a test says
    /// otherwise. `notes` stays keyed by rendered PATH for readability; the enumeration itself
    /// asks by folder ID (or by typed components when nothing matched), so the fake resolves an
    /// id back to its path through `folderRows`' parent links. `listNotes`'s own script
    /// (`set seenIds to {}`) is still answered for the callers that use it; the gate no longer
    /// does. The folder listing carries Notes.app's count as its leading row.
    private func cascadeRunner(folderRows: [String], notes: [String: [String]],
                               unreadable: [String: Int] = [:],
                               selectedID: String? = nil,
                               selectionOutput: String? = nil) -> FakeNotesRunner {
        let parsed = folderRows.map { $0.components(separatedBy: US) }
        let byId = Dictionary(parsed.map { (Array($0[0].utf8), $0) }, uniquingKeysWith: { a, _ in a })
        func pathOf(_ id: String) -> String? {
            guard let row = byId[Array(id.utf8)] else { return nil }
            let parent = row[2]
            if parent.isEmpty { return row[1] }
            return pathOf(parent).map { $0 + "/" + row[1] } ?? row[1]
        }
        let runner = FakeNotesRunner()
        runner.handler = { script, args in
            if script.contains("set allFolders to every folder") {
                return String(folderRows.count) + RS + folderRows.joined(separator: RS) + (folderRows.isEmpty ? "" : RS)
            }
            if script.contains("set unreadable to 0") {
                let path: String
                if script.contains("folder id (item 1 of argv)"), let byIdPath = pathOf(args[0]) {
                    path = byIdPath
                } else {
                    path = args.dropLast().joined(separator: "/")
                }
                let titles = notes[path] ?? []
                let rows = titles.enumerated().map { index, title in
                    [title, fixtureNoteID(900 + index)].joined(separator: US)
                }.joined(separator: RS)
                let unread = unreadable[path] ?? 0
                // Notes.app's own count: readable + unreadable, as a consistent store reports.
                return String(unread) + RS + String(titles.count + unread) + RS + rows
            }
            if script.contains("set seenIds to {}") {
                let path = args.dropLast().joined(separator: "/")
                let titles = notes[path] ?? []
                return titles.enumerated().map { index, title in
                    [title, fixtureNoteID(900 + index)].joined(separator: US)
                }.joined(separator: RS)
            }
            if Self.isFolderSelection(script) {
                // Adversarial selections are independent of the listing/name matcher. Default
                // fixtures merely choose an ordinary namesake; they do not model Notes Unicode.
                let selected: String
                if let selectedID {
                    selected = selectedID
                } else {
                    let typed = args.dropLast().map { $0.lowercased() }
                    selected = parsed.first { row in
                        guard let path = pathOf(row[0]) else { return false }
                        let parts = path.components(separatedBy: "/").map { $0.lowercased() }
                        return parts.count >= typed.count && Array(parts.suffix(typed.count)) == typed
                    }?.first ?? "UNLISTED"
                }
                // Model what the observed script requests. Otherwise removing framing in
                // production would still get a framed fake response and falsely pass.
                let emitted = Self.requestsFramedFolderSelection(script) ? Self.frameSelectedID(selected) : selected
                let response = selectionOutput ?? emitted
                // Exercise the actual shared stdout decoder. A direct fake String bypasses its
                // trimming and can falsely certify rejection of ID-edge control characters.
                return try AppleScriptRunner.result(of: ScriptOutcome(
                    terminationStatus: 0, standardOutput: Data((response + "\n").utf8),
                    standardError: Data()))
            }
            if Self.isFolderDelete(script) { return "" }
            return nil
        }
        return runner
    }

    private static let selectedIDPrefix = "APPLE_CLI_FOLDER_ID_BEGIN:"
    private static let selectedIDSuffix = ":APPLE_CLI_FOLDER_ID_END"

    private static func frameSelectedID(_ id: String) -> String {
        selectedIDPrefix + id + selectedIDSuffix
    }

    private static func requestsFramedFolderSelection(_ script: String) -> Bool {
        script.contains("return \"\(selectedIDPrefix)\" & (id of ")
            && script.contains(") & \"\(selectedIDSuffix)\"")
    }

    private static func isFolderSelection(_ script: String) -> Bool {
        (script.contains("return id of") || script.contains(selectedIDPrefix)) && !isFolderDelete(script)
    }

    private static func isFolderDelete(_ script: String) -> Bool {
        script.contains("delete folder (item") || script.contains("delete folder id (item")
    }

    private func selectionArguments(_ runner: FakeNotesRunner) -> [[String]] {
        zip(runner.scripts, runner.arguments).filter { Self.isFolderSelection($0.0) }.map { $0.1 }
    }

    private func deletionArguments(_ runner: FakeNotesRunner) -> [[String]] {
        zip(runner.scripts, runner.arguments).filter { Self.isFolderDelete($0.0) }.map { $0.1 }
    }

    private func cascadeEnumerationArguments(_ runner: FakeNotesRunner) -> [[String]] {
        zip(runner.scripts, runner.arguments).filter { $0.0.contains("set unreadable to 0") }.map { $0.1 }
    }

    /// Count either sink: checking only by-name syntax would miss an unauthorized ID delete.
    private func performedTheCascade(_ runner: FakeNotesRunner) -> Bool {
        runner.scripts.contains(where: Self.isFolderDelete)
    }

    // MARK: folders (list)

    @Test func foldersRendersNestedPathsFromTheParentChain() throws {
        let out = [folderRow(id: "F1", name: "Parent"),
                   folderRow(id: "F2", name: "Child", parent: "F1", shared: true)].joined(separator: RS) + RS
        let runner = FakeNotesRunner(results: [out])
        let command = try FoldersCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, storeFactory: { StubNotesStore.quiet() })
        })

        #expect(data["count"] as? Int == 2)
        let folders = try #require(data["folders"] as? [[String: Any]])
        #expect(folders.map { $0["name"] as? String } == ["Parent", "Parent/Child"])
        #expect(folders.last?["shared"] as? Bool == true)
    }

    @Test func foldersRendersTheEmptyTextFallback() throws {
        // `--text` with nothing to list: the human stream says so rather than printing a bare
        // heading. This test used to build a `sync_detected` store and then assert nothing about
        // it — the name promised sync-warning coverage the body never delivered. The warning
        // mechanism is `currentSyncWarning`, pinned on the JSON path in
        // `NotesReadCommandInjectionTests.listSurfacesTheSyncWarningFromTheInjectedStore`; this
        // one owns the empty-text fallback alone, so the unread setup is gone.
        let store = StubNotesStore.quiet()
        let runner = FakeNotesRunner(results: [""])
        let command = try FoldersCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No folders."))
    }

    // MARK: create-folder

    @Test func createFolderCreatesTheMissingSegmentAndReportsTheResolvedId() throws {
        let runner = FakeNotesRunner()
        var calls = 0
        runner.handler = { script, _ in
            calls += 1
            if script.contains("make new folder") { return "" }
            // The existence probe: miss first, resolve the created folder afterwards.
            return calls == 1 ? nil : "folder id F9"
        }
        // A miss is signalled by throwing (the probe is wrapped in `try?`).
        runner.results = []
        runner.whenExhausted = .fail
        let command = try CreateFolderCmd.parse(["apple-cli-test folder", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(data["folder"] as? String == "apple-cli-test folder")
        #expect(data["dry_run"] as? Bool == false)
    }

    @Test func createFolderSkipsSegmentsThatAlreadyExist() throws {
        // Every probe succeeds, so nothing is created; only the probes and the final resolve run.
        let runner = FakeNotesRunner(whenExhausted: .empty)
        let command = try CreateFolderCmd.parse(["apple-cli-test a/apple-cli-test b", "--execute"])

        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(runner.scripts.allSatisfy { !$0.contains("make new folder") },
                "an existing segment must not be re-created")
        // Nested paths travel as one argv item per segment, never interpolated into the specifier.
        #expect(runner.allArguments.contains("apple-cli-test a"))
        #expect(runner.allArguments.contains("apple-cli-test b"))
        #expect(runner.scripts.allSatisfy { !$0.contains("apple-cli-test a") })
    }

    @Test func createFolderPreviewsWithoutTouchingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try CreateFolderCmd.parse(["apple-cli-test folder", "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "create-folder")
        #expect(runner.neverCalled)
    }

    @Test func createFolderRefusesAnEmptyOrOversizedName() throws {
        for (name, fragment) in [("///", "must be a non-empty string"),
                                 (String(repeating: "f", count: NotesLimits.folder + 1), "exceeds maximum")] {
            let runner = ThrowingNotesRunner()
            let command = try CreateFolderCmd.parse([name, "--execute"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(fragment)")
            #expect((failure.error["message"] as? String)?.contains(fragment) == true)
            #expect(runner.neverCalled)
        }
    }

    @Test func createFolderSandboxGateRefusesAnUnlabeledNameOnBothPaths() throws {
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try CreateFolderCmd.parse(["Real Folder", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.error["sandbox"] as? Bool == true, "sandbox flag for \(extra)")
            #expect(runner.neverCalled)
        }
    }

    // MARK: delete-folder (the one surface that previews by default)

    @Test func deleteFolderPreviewsByDefaultWithNoFlagAtAll() throws {
        // The ONE deliberate deviation from execute-by-default: this op cascades and is
        // irreversible, so a flagless invocation must not perform it.
        #expect(DeleteFolderCmd.surfaceDefaultDryRun == true)
        let runner = ThrowingNotesRunner()
        let command = try DeleteFolderCmd.parse(["apple-cli-test folder"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv("delete-folder"))
        })

        #expect(data["dry_run"] as? Bool == true)
        #expect(data["operation"] as? String == "delete-folder")
        let detail = try #require(data["detail"] as? String)
        #expect(detail.contains("EVERY NOTE IN IT"))
        #expect(detail.contains("do NOT go to Recently Deleted"))
        #expect(runner.neverCalled)
    }

    @Test func deleteFolderPerformsTheCascadeOnlyWithExecute() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try DeleteFolderCmd.parse(["apple-cli-test folder", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(data["dry_run"] as? Bool == false)
        #expect(runner.invocationCount == 1)
        #expect(runner.allArguments.contains("apple-cli-test folder"))
    }

    @Test func deleteFolderRefusesAnEmptyName() throws {
        let runner = ThrowingNotesRunner()
        let command = try DeleteFolderCmd.parse(["///", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(runner.neverCalled)
    }

    @Test func deleteFolderSandboxGateRefusesARealFolder() throws {
        let runner = ThrowingNotesRunner()
        let command = try DeleteFolderCmd.parse(["Real Folder", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect(runner.neverCalled)
    }

    @Test func deleteFolderSandboxGateRefusesAnUnlabeledCOMPONENTOfANestedPath() throws {
        // The destructive case the whole-string `hasPrefix` missed: the path STARTS with the label,
        // so the gate passed, but `splitFolderPath` resolves the specifier and the folder actually
        // deleted is the unlabeled child — cascading, permanently, over real notes.
        // Asserted on BOTH paths: a preview that reports clean for what execute performs is the
        // same false-clean signal, one invocation earlier.
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try DeleteFolderCmd.parse([
                "apple-cli-test parent/Real Folder", "--test-mode", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real Folder") == true,
                    "the refusal names the offending COMPONENT for \(extra)")
            #expect(runner.neverCalled, "nothing may reach Notes.app on \(extra)")
        }
    }

    @Test func deleteFolderAcceptsANestedPathWhoseComponentsAreAllLabeled() throws {
        // The other half of the component rule: a fully-labeled nested path is still deletable, so
        // the fix confines rather than blocks. Empty of descendants and notes, so this isolates the
        // component rule from the cascade rule exercised below.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F2", name: "apple-cli-test child", parent: "F1")],
            notes: [:])
        let command = try DeleteFolderCmd.parse([
            "apple-cli-test parent/apple-cli-test child", "--test-mode", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
    }

    // MARK: delete-folder — the CASCADE set, not just the typed path

    @Test func deleteFolderSandboxGateRefusesAnUnlabeledNOTEInsideALabeledFolder() throws {
        // The hole the per-COMPONENT rule did not close. `deleteFolder` emits a bare
        // `delete <folderRef>` and Notes cascades it over everything inside, so a target whose own
        // path is fully labeled still erased whatever unlabeled notes it happened to contain —
        // permanently, since the cascaded notes do not reach Recently Deleted. Checking the
        // container without looking inside it is not confinement.
        // Both paths: a preview that reports clean for what execute destroys is the same
        // false-clean signal, one invocation earlier.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test parent")],
                notes: ["apple-cli-test parent": ["apple-cli-test kept", "Real Note"]])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real Note") == true,
                    "the refusal names the unlabeled NOTE the cascade would destroy, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderSandboxGateRefusesAnUnlabeledDESCENDANTFolder() throws {
        // Same rule one level down: the typed path is fully labeled, but an unlabeled SUB-folder
        // (and everything in it) is inside the cascade.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                             folderRow(id: "F2", name: "Real Child", parent: "F1")],
                notes: [:])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real Child") == true,
                    "the refusal names the unlabeled DESCENDANT folder, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderAcceptsAFullyLabeledCascadeAndIgnoresFoldersOutsideIt() throws {
        // Confines rather than blocks: every folder and note the erase would actually take is
        // labeled, so it proceeds — while an unlabeled folder holding a real note somewhere ELSE
        // in the account is outside the cascade and must not refuse it. Without that half, the
        // gate would be unusable on any account that contains real data (i.e. all of them).
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F2", name: "apple-cli-test child", parent: "F1"),
                         folderRow(id: "F3", name: "Real Elsewhere")],
            notes: ["apple-cli-test parent": ["apple-cli-test a"],
                    "apple-cli-test parent/apple-cli-test child": ["apple-cli-test b"],
                    "Real Elsewhere": ["Real Note"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
    }

    // MARK: delete-folder — the cascade is resolved the way AppleScript resolves it (case-insensitively)

    @Test func deleteFolderSandboxGateRefusesAResolvedTargetWhoseFETCHEDNameIsUnlabeled() throws {
        // AppleScript resolves a folder name case-INSENSITIVELY, so a typed `apple-cli-test parent`
        // can resolve a real folder actually named `Apple-CLI-Test Parent`. The typed spelling
        // passes the case-sensitive label check; the folder the erase would destroy does not. Before
        // the fold, the gate compared the typed components to the fetched ones case-SENSITIVELY, so
        // the real folder matched nothing, was never label-checked, and the cascade ran.
        // Both paths, for the usual reason: a preview reporting clean for what execute destroys is
        // the same false-clean signal one invocation earlier.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "Apple-CLI-Test Parent")],
                notes: ["Apple-CLI-Test Parent": ["apple-cli-test kept"]])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Apple-CLI-Test Parent") == true,
                    "the refusal names the FETCHED folder name, not the typed one, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderSandboxGateChecksDescendantsOfACaseDifferingResolvedTarget() throws {
        // The same fold one level down, and the more dangerous half: the resolved target IS labeled
        // (`apple-cli-test Parent` — the case difference is past the prefix), so nothing refuses at
        // the target. Its unlabeled sub-folder only enters the cascade if the descendant match
        // folds case too; a case-sensitive prefix comparison against the typed
        // `apple-cli-test parent` skipped it entirely and the erase destroyed it unexamined.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test Parent"),
                             folderRow(id: "F2", name: "Real Child", parent: "F1")],
                notes: [:])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real Child") == true,
                    "the descendant match must fold case, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderAcceptsACaseDifferingResolvedTargetThatIsGenuinelyLabeled() throws {
        // The control: folding case must not turn into refusing everything. The fetched name differs
        // from the typed one only in case PAST the label, so it is genuinely labeled and the cascade
        // proceeds — and its notes are enumerated under the FETCHED path, which is the point of
        // resolving at all.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test Parent"),
                         folderRow(id: "F2", name: "apple-cli-test Child", parent: "F1")],
            notes: ["apple-cli-test Parent": ["apple-cli-test a"],
                    "apple-cli-test Parent/apple-cli-test Child": ["apple-cli-test b"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
        // Enumerated by the resolved folders' IDS: two cascade enumerations, one per resolved
        // folder. A gate that had fallen back to the typed path would have asked by name for
        // `apple-cli-test parent` instead.
        #expect(runner.allArguments.contains("F1"))
        #expect(runner.allArguments.contains("F2"))
        // The typed name reaches argv once: selection in sandbox, never the ID delete.
        #expect(runner.allArguments.filter { $0 == "apple-cli-test parent" }.count == 1)
    }

    // MARK: delete-folder — what happens when the typed path resolves to NOTHING exactly

    @Test func deleteFolderRefusesWhenTheTypedPathOnlyMatchesLoosely() throws {
        // The fail-OPEN branch this replaces. When no fetched folder matched the typed path
        // EXACTLY, the gate used to fall back to checking the typed path alone: no descendant
        // folder was label-checked at all, while `deleteFolder` still emitted a bare
        // `delete <folderRef>` that Notes cascaded over whatever the specifier actually bound. The
        // subtree was reported clean and destroyed unexamined.
        //
        // A DIACRITIC difference is the shape: the exact fold (case only) misses
        // `apple-cli-test pàrent` for a typed `apple-cli-test parent`, but Notes.app may still
        // resolve one to the other. That is precisely "the gate cannot name what the erase will
        // take", so it refuses instead of quietly narrowing its own scope.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test pàrent"),
                             folderRow(id: "F2", name: "Real Child", parent: "F1")],
                notes: [:])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            let message = (failure.error["message"] as? String) ?? ""
            #expect(message.contains("apple-cli-test pàrent"),
                    "the refusal names the ambiguous fetched folder, for \(extra)")
            #expect(message.contains("only loosely"), "the refusal says WHY it refused, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderRefusesATypedPathNotesAppBindsButDoesNotList() throws {
        // Nothing in the listing matches, yet Notes.app answers the typed specifier: that is a
        // folder the listing does not report — measured live, a deleted folder lingers under its
        // name and is still bindable, even shadowing a live folder of the same name. Its
        // sub-folders are not in the listing, so the cascade cannot be verified: refuse, whether
        // its own notes look clean or not. Both paths.
        for (extra, notes) in [("--execute", ["Real Note"]), ("--dry-run", [] as [String])] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "Real Elsewhere")],
                notes: ["apple-cli-test hidden": notes])
            let command = try DeleteFolderCmd.parse(["apple-cli-test hidden", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("does not report") == true,
                    "the refusal names the unlisted-folder cause, for \(extra)")
            #expect(runner.allArguments.contains("apple-cli-test hidden"),
                    "the gate asked Notes.app about the TYPED path to tell absent from hidden")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderOfAGenuinelyAbsentFolderFailsAsNotFoundBeforeTheDelete() throws {
        // The control: a folder that does not exist at all is not "hidden" — Notes.app cannot
        // enumerate it, and that `not_found` is the answer, one call before the delete would have
        // said the same. Nothing is deleted.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "Real Elsewhere")],
            notes: ["Real Elsewhere": ["Real Note"]])
        runner.handler = { [previous = runner.handler] script, args in
            if script.contains("set unreadable to 0"), args.first == "apple-cli-test absent" {
                throw AppleScriptRunner.RunError.scriptFailed(
                    status: 1, stderr: "Notes got an error: Can\u{2019}t get folder \"apple-cli-test absent\". (-1728)")
            }
            return try previous?(script, args)
        }
        let command = try DeleteFolderCmd.parse(["apple-cli-test absent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.notFound)
        #expect(failure.error["type"] as? String == AppleErrorType.notFound)
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderRefusesWhenTwoFoldersResolveToTheSameTypedPath() throws {
        // Load-bearing and otherwise unpinned: the resolution loop does not `break` on the first
        // hit, so BOTH siblings that fold to the typed name are label-checked and the unlabeled one
        // refuses. A refactor to `first(where:)` or an early `break` would convert this to a
        // fail-open — pick the labeled one, erase the other — with the suite green.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test x"),
                         folderRow(id: "F2", name: "APPLE-CLI-TEST x")],
            notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test x", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("APPLE-CLI-TEST x") == true,
                "an ambiguous resolution refuses on the unlabeled sibling, it does not pick one")
        #expect(!performedTheCascade(runner))
    }

    // MARK: delete-folder — bind the mutation to the verified selected root

    @Test func deleteFolderUsesTheSelectedVerifiedRootRatherThanTheFirstRoot() throws {
        let name = "apple-cli-test selected"
        let account = "Synthetic Account"
        for mode in ["--dry-run", "--execute"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: name),
                             folderRow(id: "F2", name: name)],
                notes: [name: ["apple-cli-test note"]], selectedID: "F2")
            let command = try DeleteFolderCmd.parse([name, "--account", account, "--test-mode", mode])
            let data = try notesData(try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            })

            #expect(selectionArguments(runner) == [[name, account]])
            let selectionScript = try #require(runner.scripts.first(where: Self.isFolderSelection))
            #expect(Self.requestsFramedFolderSelection(selectionScript))
            let enumerated = cascadeEnumerationArguments(runner).compactMap { $0.first }
            #expect(Set(enumerated) == ["F1", "F2"])
            #expect(enumerated.count == 2)
            #expect(data["dry_run"] as? Bool == (mode == "--dry-run"))
            #expect(deletionArguments(runner) == (mode == "--execute" ? [["F2", account]] : []))
            #expect(!runner.scripts.contains { $0.contains("delete folder (item") })
            if mode == "--execute" {
                let selection = try #require(runner.scripts.firstIndex(where: Self.isFolderSelection))
                let deletion = try #require(runner.scripts.firstIndex(where: Self.isFolderDelete))
                #expect(selection < deletion)
                #expect(runner.scripts[deletion].contains("folder id (item 1 of argv)"))
            }
        }
    }

    @Test func deleteFolderPreservesAnOpaqueVerifiedIDExactly() throws {
        let name = "apple-cli-test selected"
        let selected = " synthetic folder id with spaces "
        let account = "Synthetic Account"
        // IDs are opaque. Membership, rather than a guessed CoreData grammar or substring
        // extraction, establishes whether this exact selected scalar was verified.
        for mode in ["--dry-run", "--execute"] {
            let runner = cascadeRunner(folderRows: [folderRow(id: selected, name: name)],
                                       notes: [:], selectedID: selected)
            let command = try DeleteFolderCmd.parse([name, "--account", account, "--test-mode", mode])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(selectionArguments(runner) == [[name, account]])
            #expect(cascadeEnumerationArguments(runner).first?.first == selected)
            #expect(deletionArguments(runner) == (mode == "--execute" ? [[selected, account]] : []))
            #expect(!runner.scripts.contains { $0.contains("delete folder (item") })
            #expect(!runner.scripts.contains { $0.contains(selected) })
        }
    }

    @Test func deleteFolderPreservesAnOpaqueIDBeginningWithACombiningScalar() throws {
        let name = "apple-cli-test selected"
        let selected = "\u{301}opaque-id"
        // The mark can combine with the frame prefix's final colon. Delimiter removal must use
        // bytes, not Character counts that could consume the first scalar of the verified ID.
        let runner = cascadeRunner(folderRows: [folderRow(id: selected, name: name)],
                                   notes: [:], selectedID: selected)
        let command = try DeleteFolderCmd.parse([name, "--test-mode", "--execute"])
        _ = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }
        let deleted = try #require(deletionArguments(runner).first?.first)
        #expect(deleted.utf8.elementsEqual(selected.utf8))
        #expect(selectionArguments(runner).count == 1)
    }

    @Test func deleteFolderRefusesAnActualSelectionOutsideTheVerifiedRootIDs() throws {
        let name = "apple-cli-test selected"
        // F1 is an exact, fully verified root in EVERY case. F2 is checked as a descendant,
        // F3 is listed outside both matching folds, and HIDDEN is absent from the listing.
        // The selected ID is supplied independently: no fixture fold can certify itself.
        let rows = [folderRow(id: "F1", name: name),
                    folderRow(id: "F2", name: "apple-cli-test child", parent: "F1"),
                    folderRow(id: "F3", name: "apple-cli-test unrelated"),
                    folderRow(id: "ID-caf\u{e9}", name: name)]
        for selected in ["HIDDEN", "F3", "F2", "f1", "folder id F1", "prefix folder id F1 suffix",
                         "ID-cafe\u{301}"] {
            for mode in ["--dry-run", "--execute"] {
                let runner = cascadeRunner(folderRows: rows, notes: [:], selectedID: selected)
                let command = try DeleteFolderCmd.parse([name, "--test-mode", mode])
                let failure = try captureNotesFailure {
                    try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
                }

                #expect(failure.code == AppleExit.usage)
                #expect(failure.error["type"] as? String == AppleErrorType.validation)
                #expect(failure.error["sandbox"] as? Bool == true)
                #expect(selectionArguments(runner).count == 1)
                #expect(!performedTheCascade(runner))
                #expect(!(failure.error["message"] as? String ?? "").contains("prefix folder id F1 suffix"))
                if selected == "F2" {
                    #expect(cascadeEnumerationArguments(runner).contains { $0.first == "F2" },
                            "being checked as a descendant must not authorize it as a selected root")
                }
            }
        }
    }

    @Test func deleteFolderRefusesMalformedSelectedIDScalars() throws {
        let name = "apple-cli-test selected"
        let invalid = ["", " ", "F1\nF2", "F1\rF2", "F1" + RS + "F2",
                       "F1" + US + "F2", "F1\u{0}", "\tF1", "F1\t", "\nF1", "F1\n",
                       "F1\u{2028}", "\rF1"]
        for selected in invalid {
            for mode in ["--dry-run", "--execute"] {
                let runner = cascadeRunner(folderRows: [folderRow(id: "F1", name: name)],
                                           notes: [:], selectedID: selected)
                let command = try DeleteFolderCmd.parse([name, "--test-mode", mode])
                let failure = try captureNotesFailure {
                    try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
                }

                #expect(failure.code == AppleExit.upstream)
                #expect(failure.error["type"] as? String == AppleErrorType.upstream)
                #expect(selectionArguments(runner).count == 1)
                #expect(!performedTheCascade(runner))
            }
        }
    }

    @Test func deleteFolderRejectsMalformedSelectedIDFramesAfterTransportDecoding() throws {
        let name = "apple-cli-test selected"
        let good = Self.frameSelectedID("F1")
        let outputs = ["F1", Self.selectedIDPrefix + "F1", "F1" + Self.selectedIDSuffix,
                       "unexpected" + good, good + "unexpected"]
        for output in outputs {
            for mode in ["--dry-run", "--execute"] {
                let runner = cascadeRunner(folderRows: [folderRow(id: "F1", name: name)],
                                           notes: [:], selectedID: "F1", selectionOutput: output)
                let command = try DeleteFolderCmd.parse([name, "--test-mode", mode])
                let failure = try captureNotesFailure {
                    try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
                }

                #expect(failure.code == AppleExit.upstream)
                #expect(failure.error["type"] as? String == AppleErrorType.upstream)
                #expect(selectionArguments(runner).count == 1)
                #expect(!performedTheCascade(runner))
            }
        }
    }

    @Test func deleteFolderKeepsOpaqueEdgeSpacesThroughRootAndChildAncestry() throws {
        let root = " root id "
        let child = " child id "
        let name = "apple-cli-test selected"
        for mode in ["--dry-run", "--execute"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: root, name: name),
                             folderRow(id: child, name: "apple-cli-test child", parent: root)],
                notes: [:], selectedID: root)
            let command = try DeleteFolderCmd.parse([name, "--test-mode", mode])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            let enumerated = cascadeEnumerationArguments(runner).compactMap { $0.first }
            #expect(enumerated.map { Array($0.utf8) } == [Array(root.utf8), Array(child.utf8)])
            #expect(selectionArguments(runner).count == 1)
            if mode == "--execute" {
                let deleted = try #require(deletionArguments(runner).first?.first)
                #expect(deleted.utf8.elementsEqual(root.utf8))
            } else {
                #expect(!performedTheCascade(runner))
            }
        }
    }

    @Test func deleteFolderRefusesCanonicallyEquivalentButByteDistinctParentIDs() throws {
        let name = "apple-cli-test selected"
        let listedRoot = "ID-caf\u{e9}"
        let missingParent = "ID-cafe\u{301}"
        #expect(listedRoot == missingParent, "Swift String considers these canonically equivalent")
        #expect(!listedRoot.utf8.elementsEqual(missingParent.utf8))
        for mode in ["--dry-run", "--execute"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: listedRoot, name: name),
                             folderRow(id: "CHILD", name: "apple-cli-test child", parent: missingParent)],
                notes: [:], selectedID: listedRoot)
            let command = try DeleteFolderCmd.parse([name, "--test-mode", mode])
            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage)
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("could not be placed") == true)
            #expect(!performedTheCascade(runner))
        }
    }

    @Test func cascadeFolderIDsRejectBlankControlsAndCanonicalDuplicates() throws {
        let invalidIDs = ["", " ", "\tF1", "F1\n", "F1" + RS, "F1" + US, "F1\u{0}"]
        for id in invalidIDs {
            let output = "1" + RS + folderRow(id: id, name: "apple-cli-test selected") + RS
            #expect(throws: AppleError.self) { try NotesScript.buildCascadeFolders(output) }
        }
        for parent in [" ", "\tROOT", "ROOT\n", "ROOT\u{0}"] {
            let output = "1" + RS + folderRow(id: "CHILD", name: "apple-cli-test child", parent: parent) + RS
            #expect(throws: AppleError.self) { try NotesScript.buildCascadeFolders(output) }
        }
        // String-keyed ancestry remains safe only if its potentially aliasing listed keys fail
        // closed. A sole byte-distinct missing parent is separately pinned above.
        let duplicates = "2" + RS + [
            folderRow(id: "ID-caf\u{e9}", name: "apple-cli-test first"),
            folderRow(id: "ID-cafe\u{301}", name: "apple-cli-test second"),
        ].joined(separator: RS) + RS
        #expect(throws: AppleError.self) { try NotesScript.buildCascadeFolders(duplicates) }
    }

    @Test func deleteFolderSelectedIDPreservesNestedEscapedPathAndAccountArgv() throws {
        let parent = "apple-cli-test parent/segment"
        let child = "apple-cli-test child \"quote\""
        let typed = "apple-cli-test parent\\/segment/" + child
        let account = "Synthetic \"Account\""
        for mode in ["--dry-run", "--execute"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: parent),
                             folderRow(id: "F2", name: child, parent: "F1")],
                notes: [:], selectedID: "F2")
            let command = try DeleteFolderCmd.parse([typed, "--account", account, "--test-mode", mode])
            _ = try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(selectionArguments(runner) == [[parent, child, account]])
            let selection = try #require(runner.scripts.first(where: Self.isFolderSelection))
            #expect(selection.contains("folder (item 2 of argv) of folder (item 1 of argv)"))
            #expect(selection.contains("tell account (item 3 of argv)"))
            #expect(deletionArguments(runner) == (mode == "--execute" ? [["F2", account]] : []))
            for script in runner.scripts {
                #expect(!script.contains(parent))
                #expect(!script.contains(child))
                #expect(!script.contains(account))
            }
        }
    }

    @Test func deleteFolderSelectedIDReadFailuresNeverReachEitherDeleteSink() throws {
        let cases: [(String, Int32, String)] = [
            ("Notes got an error: Not authorized to send Apple events to Notes.",
             AppleExit.permissionDenied, AppleErrorType.permissionDenied),
            ("Notes got an error: Can’t get folder \"apple-cli-test selected\". (-1728)",
             AppleExit.notFound, AppleErrorType.notFound),
            ("Notes got an error: Application isn’t running. (-600)",
             AppleExit.upstream, AppleErrorType.upstream),
        ]
        for (stderr, code, type) in cases {
            for mode in ["--dry-run", "--execute"] {
                let runner = cascadeRunner(
                    folderRows: [folderRow(id: "F1", name: "apple-cli-test selected")],
                    notes: [:], selectedID: "F1")
                runner.handler = { [previous = runner.handler] script, args in
                    if Self.isFolderSelection(script) {
                        throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: stderr)
                    }
                    return try previous?(script, args)
                }
                let command = try DeleteFolderCmd.parse(["apple-cli-test selected", "--test-mode", mode])
                let failure = try captureNotesFailure {
                    try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
                }

                #expect(failure.code == code)
                #expect(failure.error["type"] as? String == type)
                #expect(selectionArguments(runner).count == 1)
                #expect(!performedTheCascade(runner))
            }
        }
    }

    @Test func deleteFolderSelectedIDMutationNeverRetriesOrFallsBackToName() throws {
        let name = "apple-cli-test selected"
        let runner = cascadeRunner(folderRows: [folderRow(id: "F1", name: name)],
                                   notes: [:], selectedID: "F1")
        runner.handler = { [previous = runner.handler] script, args in
            if script.contains("delete folder id (item") {
                // Retrying a mutation can duplicate a write already applied before this timeout.
                throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "Notes timed out (-1712)")
            }
            return try previous?(script, args)
        }
        let command = try DeleteFolderCmd.parse([name, "--test-mode", "--execute"])
        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.upstream)
        #expect(selectionArguments(runner).count == 1)
        #expect(deletionArguments(runner).count == 1)
        #expect(deletionArguments(runner).first?.first == "F1")
        #expect(!runner.scripts.contains { $0.contains("delete folder (item") })
    }

    // MARK: delete-folder — the cascade fails CLOSED on anything it cannot verify

    @Test func deleteFolderSandboxGateRefusesWhenANoteInTheCascadeCannotBeRead() throws {
        // A note whose name or id Notes.app cannot report used to vanish from the enumeration —
        // never label-checked, still erased. The cascade enumeration now COUNTS it, and the gate
        // refuses on a non-zero count: an unreadable member is a member that cannot be proven
        // labeled, and the erase is irreversible. Both paths, as every cascade refusal.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test parent")],
                notes: ["apple-cli-test parent": ["apple-cli-test kept"]],
                unreadable: ["apple-cli-test parent": 2])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            let message = failure.error["message"] as? String ?? ""
            #expect(message.contains("2 note(s)") && message.contains("could not be read"),
                    "the refusal says how many members could not be verified, for \(extra): \(message)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderSandboxGateRefusesABlankTitledNote() throws {
        // `listNotes` drops a row whose title trims to empty; the cascade enumeration keeps it,
        // and a blank title carries no label, so the ordinary label check refuses it.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent")],
            notes: ["apple-cli-test parent": ["apple-cli-test kept", ""]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("refusing to write to \"\"") == true,
                "the blank title is named as the unlabeled member")
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateLabelChecksTheUntrimmedNoteTitle() throws {
        // A note literally titled `" apple-cli-test x"` (leading space) is NOT labeled: `hasPrefix`
        // is right to refuse it, and only a trim before the check would let it pass. The gate
        // checks the exact string Notes.app reports, so it refuses whether or not Notes.app ever
        // preserves such a title — no dependence on Notes.app's title normalization.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent")],
            notes: ["apple-cli-test parent": [" apple-cli-test leading-space"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("\" apple-cli-test leading-space\"") == true,
                "the refusal names the title exactly as Notes.app holds it, leading space included")
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateLabelChecksTheUntrimmedDescendantFolderName() throws {
        // Same rule for folders: `folders` renders names trimmed, the cascade listing does not.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F2", name: " apple-cli-test child", parent: "F1")],
            notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains(" apple-cli-test child") == true)
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateTreatsADetachedGhostAsARootOutsideOtherCascades() throws {
        // The ghost a cascade delete leaves behind: still enumerated, container unreadable. It has
        // no live parent, so it is not inside THIS cascade — a labeled cleanup elsewhere must
        // still proceed, or every sandboxed delete in the account would be refused for as long as
        // Notes.app keeps the ghost — and neither is its grandchild, which is a descendant of the
        // ghost, not an unplaced folder. Contrast the unplaced-folder refusal below: that one is
        // a parent id Notes.app DID report but did not list, which is unknowable.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F7", name: "Real ghost", parent: NotesScript.detachedParentMarker),
                         folderRow(id: "F8", name: "Real ghost child", parent: "F7"),
                         folderRow(id: "F9", name: "Real ghost grandchild", parent: "F8")],
            notes: ["apple-cli-test parent": ["apple-cli-test kept"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let envelope = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(envelope["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
        // Only the target was enumerated (by id): the ghost subtree is not in this cascade.
        #expect(cascadeEnumerationArguments(runner).filter { ["F1", "F7", "F8", "F9"].contains($0.first ?? "") }.map { $0.first! } == ["F1"])
    }

    @Test func deleteFolderSandboxGateChecksTheSubtreeOfADetachedGhostDeletedByName() throws {
        // The live cleanup path: a bare name specifier binds the ghost, and `delete` cascades over
        // its children. The ghost is the root of its own chain, so typing its name resolves it,
        // its child enters the cascade, and the unlabeled child refuses — the ghost's subtree is
        // not erased unchecked.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F7", name: "apple-cli-test ghost", parent: NotesScript.detachedParentMarker),
                         folderRow(id: "F8", name: "Real ghost child", parent: "F7")],
            notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test ghost", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real ghost child") == true)
        #expect(!performedTheCascade(runner))

        // …and a ghost Notes.app holds under a spelling the typed name only folds to is caught
        // like any resolved target — refused on its FETCHED, unlabeled name — not fallen through
        // to a bare specifier that would bind it unchecked.
        let folded = cascadeRunner(
            folderRows: [folderRow(id: "F7", name: "APPLE-CLI-TEST ghost", parent: NotesScript.detachedParentMarker)],
            notes: [:])
        let typed = try DeleteFolderCmd.parse(["apple-cli-test ghost", "--test-mode", "--execute"])
        let refused = try captureNotesFailure {
            try typed.run(scriptFactory: { quietScript(folded) }, env: pinnedWriteEnv())
        }
        #expect(refused.error["sandbox"] as? Bool == true)
        #expect((refused.error["message"] as? String)?.contains("APPLE-CLI-TEST ghost") == true)
        #expect(!performedTheCascade(folded))
    }

    @Test func deleteFolderSandboxGateRefusesWhenAFolderCannotBePlacedInTheTree() throws {
        // A folder whose parent id Notes.app reports but which is absent from the same listing
        // used to be rendered by its bare name — ancestry stripped — so it could never match as a
        // descendant and went unchecked while the erase still reached it. Now it is a refusal,
        // and a refusal wherever it sits in the account: a folder that cannot be placed in the
        // tree cannot be proven outside the cascade either.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                             folderRow(id: "F9", name: "Orphan", parent: "MISSING")],
                notes: ["apple-cli-test parent": ["apple-cli-test kept"]])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation)
            #expect(failure.error["sandbox"] as? Bool == true)
            let message = failure.error["message"] as? String ?? ""
            #expect(message.contains("\"Orphan\"") && message.contains("could not be placed"),
                    "the refusal names the folder it could not place, for \(extra): \(message)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func listCascadeNotesCountsUnreadableAndKeepsBlankTitles() throws {
        // The enumeration's contract, pinned directly: row 1 = unreadable count, row 2 = the
        // folder's total, then rows; blank titles survive; EVERY reported title is kept (no
        // folding by id — a fold would skip a label check); an empty folder yields no titles.
        let runner = FakeNotesRunner(results: [
            "3" + RS + "6" + RS + [" lead", fixtureNoteID(1)].joined(separator: US)
                + RS + ["", fixtureNoteID(2)].joined(separator: US)
                + RS + ["dup", fixtureNoteID(1)].joined(separator: US),
            "0" + RS + "0" + RS,
        ])
        let script = quietScript(runner)
        let first = try script.listCascadeNotes(account: nil, target: .components(["apple-cli-test parent"]))
        #expect(first.unreadable == 3)
        #expect(first.titles == [" lead", "", "dup"])
        let empty = try script.listCascadeNotes(account: nil, target: .components(["apple-cli-test parent"]))
        #expect(empty.unreadable == 0)
        #expect(empty.titles.isEmpty)
        // The folder path travels as argv (the specifier), never as source.
        #expect(runner.arguments.allSatisfy { $0.first == "apple-cli-test parent" })
        #expect(runner.scripts.allSatisfy { !$0.contains("apple-cli-test parent") })
    }

    @Test func listCascadeNotesRefusesEveryShapeItCannotVerify() throws {
        // Each malformed output is refused as upstream, never read as "nothing there" — and in
        // particular a title carrying an RS or US byte, which re-parses as extra or short rows: an
        // RS-split fragment that starts with the label would pass `hasPrefix` while the real,
        // unlabeled note is destroyed. The total row is the independent cross-check.
        let shapes: [(String, String)] = [
            ("not a count", "no count rows"),
            ("0", "only one count row"),
            ("0" + RS + "1" + RS + "Real client notes" + RS
                + ["apple-cli-test", fixtureNoteID(1)].joined(separator: US),
             "an RS inside a title split it into a short row"),
            ("0" + RS + "1" + RS + ["Real", "apple-cli-test", fixtureNoteID(1)].joined(separator: US),
             "a US inside a title made a three-field row"),
            ("0" + RS + "2" + RS + ["apple-cli-test only", fixtureNoteID(1)].joined(separator: US),
             "fewer rows than the folder's total"),
            ("1" + RS + "1" + RS + ["apple-cli-test extra", fixtureNoteID(1)].joined(separator: US),
             "more rows plus unreadable than the folder's total"),
            ("0" + RS + "1" + RS + "" + RS + ["apple-cli-test hidden", fixtureNoteID(1)].joined(separator: US),
             "a leading RS in a title made an empty fragment before a labeled-looking row"),
            ("0" + RS + "1" + RS + ["apple-cli-test hidden", fixtureNoteID(1)].joined(separator: US) + RS,
             "a trailing RS in a title made an empty fragment after a labeled-looking row"),
            ("2" + RS + "1" + RS,
             "more unreadable than the folder's total"),
            (String(Int.max) + RS + String(Int.max) + RS + ["apple-cli-test t", fixtureNoteID(1)].joined(separator: US),
             "counts at Int.max must be refused, never overflow"),
        ]
        for (output, why) in shapes {
            let runner = FakeNotesRunner(results: [output])
            let error = #expect(throws: AppleError.self, Comment(rawValue: why)) {
                _ = try quietScript(runner).listCascadeNotes(account: nil, target: .components(["apple-cli-test parent"]))
            }
            #expect(try #require(error).exitCode == AppleExit.upstream, Comment(rawValue: why))
            #expect(try #require(error).message.contains("cannot be verified"), Comment(rawValue: why))
        }
    }

    @Test func cascadeGateRefusesAPathWithNoComponentsOnItsOwn() throws {
        // `/` splits to no components. The command's front door (`requireNonEmptyFolderName`)
        // refuses it first in production, so this pins the GATE directly: it must refuse on its
        // own, with the sandbox envelope, before reaching Notes.app — a fail-closed gate does not
        // lean on a caller's precheck.
        let runner = ThrowingNotesRunner()
        let error = #expect(throws: AppleError.self) {
            try guardLiveFolderCascade("/", account: nil, script: quietScript(runner),
                                       sandboxActive: true, prefix: TestMode.canonicalSandboxPrefix)
        }
        #expect(try #require(error).exitCode == AppleExit.usage)
        #expect(try #require(error).message == "Invalid folder name: \"/\"")
        #expect(try #require(error).sandbox == true)
        #expect(runner.neverCalled)
    }

    private func listing(_ rows: [String]) -> String {
        String(rows.count) + RS + rows.joined(separator: RS)
    }

    @Test func buildCascadeFoldersReturnsChainsReportsUnplacedFoldersAndRefusesMalformedRows() throws {
        let rows = [folderRow(id: "F1", name: " apple-cli-test parent "),
                    folderRow(id: "F2", name: "child", parent: "F1"),
                    folderRow(id: "F9", name: "Orphan", parent: "MISSING")]
        let parsed = try NotesScript.buildCascadeFolders(listing(rows))
        // Untrimmed names, as component chains — never a rendered path.
        #expect(parsed.folders.map(\.components) == [[" apple-cli-test parent "], [" apple-cli-test parent ", "child"]])
        #expect(parsed.unresolvedAncestry == ["Orphan"])
        // The listing surface still trims and renders paths, and skips the count row.
        #expect(NotesScript.buildFolderPaths(listing(rows), account: "A").map(\.name)
                == ["apple-cli-test parent", "apple-cli-test parent/child", "Orphan"])
        // An unplaced folder AND each of its descendants are named (the operator sees the leaf),
        // once each by id; a parent chain that loops is an unresolved ancestry, not a recursion —
        // for the gate AND for the listing, which must not crash on it.
        let looped = [folderRow(id: "F1", name: "A", parent: "F2"),
                      folderRow(id: "F2", name: "B", parent: "F1"),
                      folderRow(id: "F9", name: "Orphan", parent: "MISSING"),
                      folderRow(id: "F10", name: "OrphanChild", parent: "F9"),
                      folderRow(id: "F11", name: "OrphanGrandchild", parent: "F10")]
        let cyclic = try NotesScript.buildCascadeFolders(listing(looped))
        #expect(Set(cyclic.unresolvedAncestry) == ["A", "B", "Orphan", "OrphanChild", "OrphanGrandchild"])
        #expect(cyclic.folders.isEmpty)
        #expect(NotesScript.buildFolderPaths(listing(looped), account: "A").count == 5)
        // A folder whose container read FAILED (the listing's detached marker) has no live parent:
        // it is the ROOT of its own chain, its descendants chain through it at any depth, and
        // nothing about it is an unresolved ancestry.
        let detached = [folderRow(id: "F1", name: "apple-cli-test parent"),
                        folderRow(id: "F7", name: "apple-cli-test ghost", parent: NotesScript.detachedParentMarker),
                        folderRow(id: "F8", name: "ghost child", parent: "F7"),
                        folderRow(id: "F9", name: "ghost grandchild", parent: "F8")]
        let ghosted = try NotesScript.buildCascadeFolders(listing(detached))
        #expect(ghosted.folders.map(\.components) == [["apple-cli-test parent"], ["apple-cli-test ghost"],
                                                       ["apple-cli-test ghost", "ghost child"],
                                                       ["apple-cli-test ghost", "ghost child", "ghost grandchild"]])
        #expect(ghosted.unresolvedAncestry.isEmpty)
        // …and the listing surface renders it by its bare name rather than failing.
        #expect(NotesScript.buildFolderPaths(listing(detached), account: "A").map(\.name)
                == ["apple-cli-test parent", "apple-cli-test ghost", "apple-cli-test ghost/ghost child",
                    "apple-cli-test ghost/ghost child/ghost grandchild"])
        // A name the script withheld (framing byte) is an unresolved ancestry under the
        // placeholder for the gate, and the placeholder for the listing.
        let withheld = [folderRow(id: "F1", name: "apple-cli-test parent"),
                        folderRow(id: "F5", name: "", parent: NotesScript.unreadableNameMarker)]
        #expect(try NotesScript.buildCascadeFolders(listing(withheld)).unresolvedAncestry
                == [NotesScript.unreadableNamePlaceholder])
        #expect(NotesScript.buildFolderPaths(listing(withheld), account: "A").map(\.name)
                == ["apple-cli-test parent", NotesScript.unreadableNamePlaceholder])
        // A name containing `/` stays ONE component; the listing's `\/` rendering is not involved.
        let slashed = [folderRow(id: "F1", name: "apple-cli-test a/b"),
                       folderRow(id: "F2", name: "apple-cli-test c", parent: "F1")]
        #expect(try NotesScript.buildCascadeFolders(listing(slashed)).folders.map(\.components)
                == [["apple-cli-test a/b"], ["apple-cli-test a/b", "apple-cli-test c"]])
        // Every shape the strict parser refuses, as upstream: no count row; a row that is not
        // exactly four fields; a repeated id (a first-wins lookup would shadow descendants);
        // a count that does not match the rows (a forged row would change it).
        let bad: [(String, String)] = [
            (folderRow(id: "F1", name: "x"), "no count row"),
            (listing(["F1" + US + "only-two"]), "two fields"),
            (listing([folderRow(id: "F1", name: "x") + US + "extra"]), "five fields"),
            (listing([folderRow(id: "F1", name: "x"), folderRow(id: "F1", name: "y")]), "repeated id"),
            ("2" + RS + folderRow(id: "F1", name: "x"), "fewer rows than the count"),
            ("1" + RS + folderRow(id: "F1", name: "x") + RS + folderRow(id: "F2", name: "y"), "more rows than the count"),
        ]
        for (out, why) in bad {
            let error = #expect(throws: AppleError.self, Comment(rawValue: why)) { _ = try NotesScript.buildCascadeFolders(out) }
            #expect(try #require(error).exitCode == AppleExit.upstream, Comment(rawValue: why))
        }
    }

    @Test func deleteFolderEnumeratesCaseVariantSiblingsByIdNotByName() throws {
        // Two sibling folders whose names differ only in case fold to the SAME chain. A name-bound
        // specifier would enumerate whichever AppleScript picks — twice — and the other never,
        // while the cascade destroys both. Enumerating by id reaches each exactly once, so the
        // unlabeled note in the second sibling is found and refuses.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F2", name: "apple-cli-test a", parent: "F1"),
                         folderRow(id: "F3", name: "apple-cli-test A", parent: "F1")],
            notes: ["apple-cli-test parent/apple-cli-test a": ["apple-cli-test fine"],
                    "apple-cli-test parent/apple-cli-test A": ["Real note in the other sibling"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Real note in the other sibling") == true)
        // Each cascade folder was asked for BY ID, and each id exactly once.
        let idQueries = cascadeEnumerationArguments(runner).filter { ["F1", "F2", "F3"].contains($0.first ?? "") }.map { $0.first! }
        #expect(Set(idQueries) == ["F1", "F2", "F3"])
        #expect(idQueries.count == 3)
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateFindsANestedRootBoundByItsBareName() throws {
        // Measured 2026-09-09: under `tell account`, a bare `folder "x"` binds a folder named x at
        // ANY depth. A typed `apple-cli-test child` therefore binds `apple-cli-test parent/
        // apple-cli-test child`, and the delete cascades over the grandchild. A gate matching from
        // the account root never saw the nested root, fell to the typed-specifier fallback, and
        // checked only the child's own notes — the grandchild was erased unchecked. The chain is
        // now matched end-anchored, so the nested root and its subtree enter the cascade.
        let rows = [folderRow(id: "F1", name: "apple-cli-test parent"),
                    folderRow(id: "F2", name: "apple-cli-test child", parent: "F1"),
                    folderRow(id: "F3", name: "Real grandchild", parent: "F2")]
        for mode in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(folderRows: rows, notes: [:])
            let command = try DeleteFolderCmd.parse(["apple-cli-test child", "--test-mode", mode])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, Comment(rawValue: mode))
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real grandchild") == true, Comment(rawValue: mode))
            #expect(!performedTheCascade(runner))
        }

        // Fully labeled: the nested root and its subtree are enumerated by id — and the parent
        // ABOVE the root is not, because the erase does not reach it.
        let labeled = [folderRow(id: "F1", name: "apple-cli-test parent"),
                       folderRow(id: "F2", name: "apple-cli-test child", parent: "F1"),
                       folderRow(id: "F3", name: "apple-cli-test grandchild", parent: "F2")]
        let runner = cascadeRunner(folderRows: labeled, notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test child", "--test-mode", "--execute"])

        let envelope = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(envelope["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
        let idQueries = cascadeEnumerationArguments(runner).filter { ["F1", "F2", "F3"].contains($0.first ?? "") }.map { $0.first! }
        #expect(Set(idQueries) == ["F2", "F3"])
        #expect(idQueries.count == 2)
    }

    @Test func deleteFolderSandboxGateChecksEveryFolderTheTypedPathCouldBind() throws {
        // A top-level `apple-cli-test x` AND a nested `apple-cli-test parent/apple-cli-test x`.
        // The gate cannot know which one `folder "apple-cli-test x"` binds, so both are roots and
        // both subtrees are checked; the unlabeled note under the nested one refuses.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test x"),
                         folderRow(id: "F2", name: "apple-cli-test parent"),
                         folderRow(id: "F3", name: "apple-cli-test x", parent: "F2")],
            notes: ["apple-cli-test x": ["apple-cli-test fine"],
                    "apple-cli-test parent/apple-cli-test x": ["Real note under the nested namesake"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test x", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Real note under the nested namesake") == true)
        let idQueries = cascadeEnumerationArguments(runner).filter { ["F1", "F2", "F3"].contains($0.first ?? "") }.map { $0.first! }
        #expect(Set(idQueries) == ["F1", "F3"])
        #expect(!performedTheCascade(runner))

        // A nested root under an UNLABELED real parent: the typed name binds it all the same, and
        // the parent's fetched name refuses before any note is read.
        let unlabeledAncestor = cascadeRunner(
            folderRows: [folderRow(id: "F2", name: "Real parent"),
                         folderRow(id: "F3", name: "apple-cli-test x", parent: "F2")],
            notes: [:])
        let ancestorFailure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(unlabeledAncestor) }, env: pinnedWriteEnv())
        }
        #expect((ancestorFailure.error["message"] as? String)?.contains("Real parent") == true)
        #expect(!performedTheCascade(unlabeledAncestor))
    }

    @Test func deleteFolderSandboxGateDoesNotLetAMultiComponentPathSkipALevel() throws {
        // Measured 2026-09-09: `folder "b" of folder "a"` binds only a DIRECT child of a (skipping
        // a level is -1728). So a typed `apple-cli-test a/apple-cli-test b` must not treat
        // `apple-cli-test a/Real q/apple-cli-test b` as a root — the window is contiguous. Nothing
        // in the listing ends with the typed chain, nothing matches loosely, so the gate asks
        // Notes.app for the typed specifier. The measured answer is -1728, which is `not_found`
        // — the same thing the delete would have said — and no listed folder is enumerated.
        let rows = [folderRow(id: "F1", name: "apple-cli-test a"),
                    folderRow(id: "F2", name: "Real q", parent: "F1"),
                    folderRow(id: "F3", name: "apple-cli-test b", parent: "F2")]
        let runner = cascadeRunner(folderRows: rows, notes: [:])
        runner.handler = { [previous = runner.handler] script, args in
            if script.contains("set unreadable to 0"), !script.contains("folder id (item 1 of argv)") {
                throw AppleScriptRunner.RunError.scriptFailed(
                    status: 1, stderr: "Notes got an error: Can\u{2019}t get folder \"apple-cli-test b\". (-1728)")
            }
            return try previous?(script, args)
        }
        let command = try DeleteFolderCmd.parse(["apple-cli-test a/apple-cli-test b", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.notFound)
        #expect(failure.error["type"] as? String == AppleErrorType.notFound)
        #expect(cascadeEnumerationArguments(runner).filter { ["F1", "F2", "F3"].contains($0.first ?? "") }.isEmpty)
        #expect(!performedTheCascade(runner))

        // Were Notes.app ever to bind it anyway (a hidden deleted folder under that name), the
        // bindable-but-unlisted refusal applies, exactly as for a single component.
        let bindable = cascadeRunner(folderRows: rows, notes: [:])
        let refusal = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(bindable) }, env: pinnedWriteEnv())
        }
        #expect(refusal.code == AppleExit.usage)
        #expect(refusal.error["sandbox"] as? Bool == true)
        #expect((refusal.error["message"] as? String)?.contains("does not report") == true)
        #expect(!performedTheCascade(bindable))
    }

    @Test func deleteFolderSandboxGateRefusesAFolderWhoseNameWasWithheld() throws {
        // The listing withholds a name carrying a framing byte and marks the row; the gate
        // refuses under the placeholder, wherever the folder sits, because a name it cannot read
        // is a name it cannot prove labeled.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test parent"),
                         folderRow(id: "F5", name: "", parent: NotesScript.unreadableNameMarker)],
            notes: ["apple-cli-test parent": []])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--dry-run"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains(NotesScript.unreadableNamePlaceholder) == true)
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateChecksTheChildOfABackslashTerminatedTarget() throws {
        // The rendered-path trap: `folders` renders `apple-cli-test parent\` + `/Real Child` as
        // `apple-cli-test parent\/Real Child`, which `splitFolderPath` reads back as ONE component
        // (the `\/` escape), so the child never matched as a descendant and the cascade erased it
        // unchecked. The gate now matches component chains built from parent ids, so the child
        // is inside the cascade and refuses.
        for extra in ["--execute", "--dry-run"] {
            let runner = cascadeRunner(
                folderRows: [folderRow(id: "F1", name: "apple-cli-test parent\\"),
                             folderRow(id: "F2", name: "Real Child", parent: "F1")],
                notes: [:])
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent\\", "--test-mode", extra])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["sandbox"] as? Bool == true)
            #expect((failure.error["message"] as? String)?.contains("Real Child") == true,
                    "the child of a backslash-terminated target is in the cascade, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderRefusesWhenTheTypedPathMatchesOnlyUpToSurroundingWhitespace() throws {
        // Fetched names are untrimmed now, so a folder Notes.app holds as `" apple-cli-test parent"`
        // no longer matches the typed `apple-cli-test parent` exactly. It must then be caught by
        // the LOOSE fold as ambiguous — not fall through to the typed path and drop its
        // descendants from the check.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: " apple-cli-test parent"),
                         folderRow(id: "F2", name: "Real Child", parent: "F1")],
            notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("matches it only loosely") == true)
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderSandboxGateHandlesRootsThatArePrefixesOfOneAnother() throws {
        // `apple-cli-test x` and `apple-cli-test x/apple-cli-test x` both end with the typed
        // chain, so both are roots; the nested one is also a descendant of the outer one. It must
        // enter the cascade exactly once, and the matching must be component-wise — a string
        // suffix would also admit `Real yapple-cli-test x`, which shares no component.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test x"),
                         folderRow(id: "F2", name: "apple-cli-test x", parent: "F1"),
                         folderRow(id: "F3", name: "apple-cli-test x", parent: "F2"),
                         folderRow(id: "F4", name: "Real yapple-cli-test x")],
            notes: [:])
        let command = try DeleteFolderCmd.parse(["apple-cli-test x", "--test-mode", "--execute"])

        let envelope = try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(envelope["ok"] as? Bool == true)
        let idQueries = cascadeEnumerationArguments(runner).filter { ["F1", "F2", "F3", "F4"].contains($0.first ?? "") }.map { $0.first! }
        #expect(idQueries.sorted() == ["F1", "F2", "F3"])
    }

    @Test func deleteFolderSandboxGateRefusesALooseNamesakeEvenWhenAnExactRootExists() throws {
        // An exact root (`apple-cli-test x`) AND a nested folder that matches only under the
        // loose fold (a diacritic variant). The gate cannot tell which one the specifier binds,
        // so the loose-only namesake refuses the delete — it is not skipped just because an exact
        // match was found. Used to be checked only when nothing matched exactly.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "apple-cli-test x"),
                         folderRow(id: "F2", name: "Real parent"),
                         folderRow(id: "F3", name: "apple-cli-test \u{78}\u{301}", parent: "F2")],
            notes: ["apple-cli-test x": ["apple-cli-test fine"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test x", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("matches it only loosely") == true)
        #expect(!performedTheCascade(runner))
    }

    // MARK: delete-folder — a sandboxed PREVIEW can now fail upstream, with the documented codes

    @Test func deleteFolderSandboxedPreviewSurfacesTheDocumentedExitCodes() throws {
        // A CHARACTERIZATION pin, not a regression test: the CHANGELOG promises three codes for a
        // sandboxed `--dry-run` whose cascade enumeration reaches Notes.app and fails, and the
        // mapping (`NotesScript.mapError`) was verified by reading but never pinned end-to-end
        // through the command. This drives each stderr shape through the real command and asserts
        // the envelope — and that nothing was deleted, since a preview that failed to enumerate
        // must not fall through to the erase.
        let cases: [(stderr: String, code: Int32, type: String)] = [
            ("Notes got an error: Not authorized to send Apple events to Notes.",
             AppleExit.permissionDenied, AppleErrorType.permissionDenied),
            ("Notes got an error: Can\u{2019}t get folder \"apple-cli-test parent\". (-1728)",
             AppleExit.notFound, AppleErrorType.notFound),
            ("Notes got an error: Application isn\u{2019}t running. (-600)",
             AppleExit.upstream, AppleErrorType.upstream),
        ]
        for (stderr, code, type) in cases {
            let runner = FakeNotesRunner()
            runner.handler = { script, _ in
                if script.contains("set allFolders to every folder") {
                    throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: stderr)
                }
                return nil
            }
            let command = try DeleteFolderCmd.parse(["apple-cli-test parent", "--test-mode", "--dry-run"])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == code, "exit for stderr \(stderr)")
            #expect(failure.error["type"] as? String == type, "type for stderr \(stderr)")
            #expect(!performedTheCascade(runner))
        }
    }

    @Test func deleteFolderOutsideTheSandboxEnumeratesNothing() throws {
        // The enumeration is a SANDBOX gate, not a new cost on the ordinary path: outside the
        // sandbox the command must still reach Notes.app exactly once, for the delete.
        let runner = cascadeRunner(folderRows: [], notes: [:])
        let command = try DeleteFolderCmd.parse(["Real Folder", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(runner.invocationCount == 1, "no folder or note enumeration outside the sandbox")
        #expect(performedTheCascade(runner))
        #expect(selectionArguments(runner).isEmpty)
        #expect(runner.scripts[0].contains("delete folder (item"))
        #expect(deletionArguments(runner).first?.first == "Real Folder")
    }

    @Test func deleteFolderLabelChecksAgainstTheCanonicalPrefixNotTheOverridableOne() throws {
        // `APPLE_TEST_SANDBOX` is caller-redefinable, and AppleKit's rule is that widening the
        // override must not widen what an IRREVERSIBLE op may erase. `folders delete` is the only
        // Notes op in that class, so it checks `TestMode.canonicalSandboxPrefix` and refuses a name
        // the widened label would have allowed…
        let widened = NotesWriteEnv(testModeVar: "APPLE_NOTESKIT_TESTONLY_UNSET_MODE3",
                                    dryRunVar: "APPLE_NOTESKIT_TESTONLY_UNSET_DRY3",
                                    sandboxPrefix: "qa-fixture")
        let runner = ThrowingNotesRunner()
        let command = try DeleteFolderCmd.parse(["qa-fixture folder", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: widened)
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains(TestMode.canonicalSandboxPrefix) == true)
        #expect(runner.neverCalled)

        // …while a recoverable surface keeps honoring the override, which is what makes the
        // distinction deliberate rather than an accident of which constant was in scope.
        let createRunner = FakeNotesRunner(whenExhausted: .empty)
        let createCommand = try CreateFolderCmd.parse(["qa-fixture folder", "--test-mode", "--execute"])

        _ = try captureNotesEnvelope {
            try createCommand.run(scriptFactory: { quietScript(createRunner) }, env: widened)
        }

        #expect(createRunner.invocationCount > 0)
    }

    @Test func createFolderSandboxGateRefusesAnUnlabeledCOMPONENTOfANestedPath() throws {
        // Same component rule on the creating side: each segment of a nested path becomes its own
        // folder, so an unlabeled segment creates unlabeled data inside the sandbox.
        let runner = ThrowingNotesRunner()
        let command = try CreateFolderCmd.parse([
            "apple-cli-test parent/Real Child", "--test-mode", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("Real Child") == true)
        #expect(runner.neverCalled)
    }

    // MARK: accounts / default-location / shared

    @Test func accountsEmitsIdNameUpgradedAndDefaultFolder() throws {
        let row = ["A1", "Example Account", "true", "F1", "Notes"].joined(separator: US)
        let runner = FakeNotesRunner(results: [row + RS])
        let command = try AccountsCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        #expect(data["count"] as? Int == 1)
        let accounts = try #require(data["accounts"] as? [[String: Any]])
        #expect(accounts.first?["name"] as? String == "Example Account")
        #expect(accounts.first?["upgraded"] as? Bool == true)
        #expect(accounts.first?["default_folder"] as? String == "Notes")
    }

    @Test func accountsTextRenderingSaysSoWhenThereAreNone() throws {
        let runner = FakeNotesRunner(results: [""])
        let command = try AccountsCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No accounts."))
    }

    @Test func defaultLocationEmitsBothHalves() throws {
        let out = ["A1", "Example Account", "true", "F1", "Notes", "false"].joined(separator: US)
        let runner = FakeNotesRunner(results: [out])
        let command = try DefaultLocationCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        let account = try #require(data["account"] as? [String: Any])
        let folder = try #require(data["folder"] as? [String: Any])
        #expect(account["name"] as? String == "Example Account")
        #expect(folder["name"] as? String == "Notes")
    }

    @Test func defaultLocationReportsUpstreamOnAShortRow() throws {
        let runner = FakeNotesRunner(results: ["A1" + US + "Example Account"])
        let command = try DefaultLocationCmd.parse([])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(failure.code == AppleExit.upstream)
        #expect(failure.error["type"] as? String == AppleErrorType.upstream)
    }

    @Test func sharedListsCollaboratedNotesPerAccount() throws {
        let accountRow = ["A1", "Example Account", "true", "F1", "Notes"].joined(separator: US)
        let sharedRow = ["apple-cli-test shared", fixtureNoteID(1), fixtureDate, fixtureDate, "true", "false"]
            .joined(separator: US)
        let runner = FakeNotesRunner(results: [accountRow + RS, sharedRow + RS])
        let command = try SharedCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        #expect(data["count"] as? Int == 1)
        let notes = try #require(data["notes"] as? [[String: Any]])
        #expect(notes.first?["title"] as? String == "apple-cli-test shared")
        #expect(notes.first?["account"] as? String == "Example Account")
        #expect(notes.first?["shared"] as? Bool == true)
    }

    @Test func sharedTextRenderingSaysSoWhenThereAreNone() throws {
        let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
        let command = try SharedCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No shared notes."))
    }
}

@Suite("Notes batch-delete + batch-move")
struct NotesBatchCommandTests {

    private func statuses(_ values: [String]) -> String {
        values.joined(separator: RS) + RS
    }

    // MARK: batch-delete

    @Test func batchDeleteReportsPerItemOutcomes() throws {
        let runner = FakeNotesRunner(results: [statuses(["ok", "missing"])])
        let command = try BatchDeleteCmd.parse([
            "--ids", fixtureNoteID(1), fixtureNoteID(2), "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["succeeded"] as? Int == 1)
        #expect(data["failed"] as? Int == 1)
        #expect(data["ok"] as? Bool == false, "a partial batch is a success envelope carrying ok:false")
        let results = try #require(data["results"] as? [[String: Any]])
        #expect(results.last?["error"] as? String == NotesScript.BatchFailure.notFound)
    }

    @Test func batchDeleteMarksMalformedIdsWithoutRunningThemThroughNotes() throws {
        let runner = FakeNotesRunner(results: [statuses(["ok"])])
        let command = try BatchDeleteCmd.parse([
            "--ids", fixtureNoteID(1), "not-an-id", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        let results = try #require(data["results"] as? [[String: Any]])
        #expect(results.last?["error"] as? String == NotesScript.BatchFailure.invalidId)
        #expect(runner.allArguments.contains("not-an-id") == false,
                "a malformed id never reaches the AppleScript loop")
    }

    @Test func batchDeleteWhereNothingSucceededIsAnErrorEnvelopeNotASuccess() throws {
        // The defect this pins: a batch where every id failed used to emit ok:true and exit 0.
        let runner = FakeNotesRunner(results: [statuses(["missing", "fail"])])
        let command = try BatchDeleteCmd.parse([
            "--ids", fixtureNoteID(1), fixtureNoteID(2), "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.upstream)
        #expect(failure.error["type"] as? String == AppleErrorType.upstream)
        #expect(failure.envelope["ok"] as? Bool == false)
        let message = try #require(failure.error["message"] as? String)
        #expect(message.contains("Batch delete: 0 succeeded, 2 failed"))
        #expect(message.contains(NotesScript.BatchFailure.notFound))
        #expect(message.contains(NotesScript.BatchFailure.deleteFailed))
    }

    @Test func batchDeletePreviewsWithoutTouchingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try BatchDeleteCmd.parse(["--ids", fixtureNoteID(1), "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "batch-delete-notes")
        #expect((data["detail"] as? String)?.contains("Recently Deleted") == true)
        #expect(runner.neverCalled)
    }

    @Test func batchDeleteSandboxPreviewDisclosesTheUncheckedTargets() throws {
        let runner = ThrowingNotesRunner()
        let command = try BatchDeleteCmd.parse(["--ids", fixtureNoteID(1), "--test-mode", "--dry-run"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect((data["detail"] as? String)?.contains("this preview did not run it") == true)
        #expect(runner.neverCalled)
    }

    // NOTE: the `--ids` empty-list guard is NOT exercised from argv, because it cannot be reached
    // that way — `@Option(parsing: .upToNextOption) var ids: [String]` has no default, so
    // ArgumentParser rejects a missing or valueless `--ids` before `run()` is entered. The guard
    // stays as defense in depth for any future non-argv caller; it is deliberately left uncovered
    // rather than reached through a contrived construction that no real invocation performs.
    @Test func batchDeleteRefusesAnOversizedIdList() throws {
        let runner = ThrowingNotesRunner()
        let many = try BatchDeleteCmd.parse(["--ids"] + (1...501).map { fixtureNoteID($0) } + ["--execute"])
        let manyFailure = try captureNotesFailure {
            try many.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }
        #expect(manyFailure.code == AppleExit.usage)
        #expect((manyFailure.error["message"] as? String)?.contains("Too many ids") == true)
        #expect(runner.neverCalled)
    }

    @Test func batchDeleteInTheSandboxAbortsBeforeMutatingWhenATargetIsUnlabeled() throws {
        // The pre-flight resolves each id and refuses on the first unlabeled title, so no delete
        // script runs at all.
        let runner = FakeNotesRunner(results: [noteRow(title: "Real Note", id: fixtureNoteID(1))],
                                     whenExhausted: .empty)
        let command = try BatchDeleteCmd.parse(["--ids", fixtureNoteID(1), "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real Note") == true)
        #expect(runner.invocationCount == 1, "only the verification lookup ran")
    }

    @Test func batchDeleteInTheSandboxAbortsWhenATargetCannotBeResolved() throws {
        let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
        let command = try BatchDeleteCmd.parse(["--ids", fixtureNoteID(2), "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("Batch aborted") == true)
    }

    // MARK: batch-move

    @Test func batchMoveReportsPerItemOutcomesAndNamesTheDestination() throws {
        let runner = FakeNotesRunner(results: [statuses(["ok", "pw"])])
        let command = try BatchMoveCmd.parse([
            "--ids", fixtureNoteID(1), fixtureNoteID(2),
            "--folder", "apple-cli-test dest", "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["folder"] as? String == "apple-cli-test dest")
        #expect(data["succeeded"] as? Int == 1)
        let results = try #require(data["results"] as? [[String: Any]])
        #expect(results.last?["error"] as? String == NotesScript.BatchFailure.passwordProtected)
    }

    @Test func batchMoveWhereNothingSucceededNamesTheDestinationInTheError() throws {
        let runner = FakeNotesRunner(results: [statuses(["fail"])])
        let command = try BatchMoveCmd.parse([
            "--ids", fixtureNoteID(1), "--folder", "apple-cli-test dest", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        let message = try #require(failure.error["message"] as? String)
        #expect(message.contains("Batch move to \"apple-cli-test dest\": 0 succeeded, 1 failed"))
        #expect(message.contains(NotesScript.BatchFailure.moveFailed))
    }

    @Test func batchMovePreviewsWithoutTouchingNotes() throws {
        let runner = ThrowingNotesRunner()
        let command = try BatchMoveCmd.parse([
            "--ids", fixtureNoteID(1), "--folder", "Archive", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "batch-move-notes")
        #expect((data["detail"] as? String)?.contains("Archive") == true)
        #expect(runner.neverCalled)
    }

    @Test func batchMoveRefusesAnEmptyFolderOrOversizedList() throws {
        let runner = ThrowingNotesRunner()
        let cases: [([String], String)] = [
            (["--ids", fixtureNoteID(1), "--folder", "///"], "must be a non-empty string"),
        ]
        for (args, fragment) in cases {
            let command = try BatchMoveCmd.parse(args + ["--execute"])
            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }
            #expect(failure.code == AppleExit.usage, "exit for \(fragment)")
            #expect((failure.error["message"] as? String)?.contains(fragment) == true)
        }

        let many = try BatchMoveCmd.parse(
            ["--ids"] + (1...501).map { fixtureNoteID($0) } + ["--folder", "Dest", "--execute"])
        let manyFailure = try captureNotesFailure {
            try many.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }
        #expect((manyFailure.error["message"] as? String)?.contains("Too many ids") == true)
        #expect(runner.neverCalled)
    }

    @Test func batchMoveSandboxGateRefusesARealDestinationOnBothPaths() throws {
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try BatchMoveCmd.parse([
                "--ids", fixtureNoteID(1), "--folder", "Real Folder", "--test-mode", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect((failure.error["message"] as? String)?.contains("Real Folder") == true, "for \(extra)")
            #expect(runner.neverCalled)
        }
    }

    @Test func batchMoveSandboxGateRefusesAnUnlabeledComponentBeforeReachingNotes() throws {
        // A labeled first component must not admit the unlabeled child. Both preview and
        // execution refuse before constructing the script or fetching/moving any notes.
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            var factoryCalls = 0
            let command = try BatchMoveCmd.parse([
                "--ids", fixtureNoteID(1), "--folder", "apple-cli-test parent/Real Child",
                "--test-mode", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: {
                    factoryCalls += 1
                    return quietScript(runner)
                }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation, "type for \(extra)")
            #expect(failure.error["sandbox"] as? Bool == true, "sandbox for \(extra)")
            #expect((failure.error["message"] as? String)?.contains("\"Real Child\"") == true,
                    "the refused component for \(extra)")
            #expect(factoryCalls == 0, "no script construction for \(extra)")
            #expect(runner.neverCalled, "no Notes calls for \(extra)")
        }
    }

    @Test func aWholeScriptFailureStampsEveryItemWithTheUpstreamMessage() throws {
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in throw AppleError.upstream("Notes.app is not running.") }
        let command = try BatchDeleteCmd.parse([
            "--ids", fixtureNoteID(1), fixtureNoteID(2), "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.upstream)
        #expect((failure.error["message"] as? String)?.contains("Notes.app is not running.") == true)
    }
}

@Suite("Notes output policy — folder, shared and batch boundaries")
struct NotesOrgOutputPolicyTests {
    @Test(arguments: notesPolicyScenarios(["existence", "readback"]))
    func folderExistenceAndFinalReadbackKeepPolicyFailures(_ scenario: NotesPolicyScenario) throws {
        let policy = scenario.policy, marked = scenario.marked
        let finalReadback = scenario.phase == "readback"
        let error = policy.error(marked: marked)
        let runner = FakeNotesRunner()
        var phases: [String] = []
        var reads = 0
        runner.handler = { source, _ in
            if source.contains("make new folder") { phases.append("make"); return "folder id F1" }
            #expect(source.contains("return id of folder"))
            reads += 1
            phases.append("read")
            if finalReadback && reads == 1 { throw AppleError.notFound("synthetic absence") }
            if !finalReadback && reads > 1 { return "folder id F1" }
            throw error
        }
        let name = finalReadback ? "apple-cli-test folder" : "apple-cli-test folder/apple-cli-test child"
        let command = try CreateFolderCmd.parse([name])
        let run = { try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv("policy-folder")) }
        if marked {
            try expectNotesPolicyFailure(error, run)
            #expect(phases == (finalReadback ? ["read", "make", "read"] : ["read"]))
        } else {
            _ = try notesData(captureNotesEnvelope(run))
            #expect(phases == (finalReadback ? ["read", "make", "read"] : ["read", "make", "read", "read"]))
        }
    }

    @Test(arguments: notesPolicyScenarios(["shared"]))
    func sharedAccountFailureStopsOnlyForPolicyOrigin(_ scenario: NotesPolicyScenario) throws {
        let policy = scenario.policy, marked = scenario.marked
        let error = policy.error(marked: marked)
        let runner = FakeNotesRunner()
        var phases: [String] = []
        runner.handler = { source, args in
            if source.contains("repeat with a in accounts") {
                phases.append("accounts"); return policyAccountRows(["Example One", "Example Two"])
            }
            #expect(source.contains("if shared of n is true"))
            let account = try #require(args.first)
            phases.append(account)
            if account == "Example One" { throw error }
            return noteRow(title: "apple-cli-test shared", id: fixtureNoteID(2), shared: true) + RS
        }
        let command = try SharedCmd.parse([])
        let run = { try command.run(scriptFactory: { quietScript(runner) }) }
        if marked {
            try expectNotesPolicyFailure(error, run)
            #expect(phases == ["accounts", "Example One"])
        } else {
            let data = try notesData(captureNotesEnvelope(run))
            #expect(data["count"] as? Int == 1)
            #expect(phases == ["accounts", "Example One", "Example Two"])
        }
    }

    @Test(arguments: notesPolicyScenarios(["delete", "move"]))
    func batchWholeScriptFailurePreservesPolicyInsteadOfClaimingPerItemFailure(_ scenario: NotesPolicyScenario) throws {
        let policy = scenario.policy, marked = scenario.marked
        let move = scenario.phase == "move"
        let error = policy.error(marked: marked)
        let runner = FakeNotesRunner()
        var attemptedMutation = false
        runner.handler = { source, _ in
            #expect(source.contains(move ? "move noteRef" : "delete noteRef"))
            attemptedMutation = true // The synthetic mutation may have happened before throwing.
            throw error
        }
        let run: () throws -> Void = {
            if move {
                let command = try BatchMoveCmd.parse(["--ids", fixtureNoteID(1), "--folder", "apple-cli-test destination"])
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv("policy-batch"))
            } else {
                let command = try BatchDeleteCmd.parse(["--ids", fixtureNoteID(1)])
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv("policy-batch"))
            }
        }
        if marked {
            try expectNotesPolicyFailure(error, run)
        } else {
            let failure = try captureNotesFailure(run)
            #expect(failure.code == AppleExit.upstream)
            #expect(failure.error["type"] as? String == AppleErrorType.upstream)
            let scope = move ? "move to \"apple-cli-test destination\"" : "delete"
            #expect(failure.error["message"] as? String == "Batch \(scope): 0 succeeded, 1 failed\n\nFailures:\n  - \(fixtureNoteID(1)): \(error.message)")
        }
        #expect(attemptedMutation)
        #expect(runner.invocationCount == 1)
    }
}
