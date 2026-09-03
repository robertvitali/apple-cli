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
    private func cascadeRunner(folderRows: [String], notes: [String: [String]]) -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        runner.handler = { script, args in
            if script.contains("set allFolders to every folder") {
                return folderRows.isEmpty ? "" : folderRows.joined(separator: RS) + RS
            }
            if script.contains("set seenIds to {}") {
                let path = args.dropLast().joined(separator: "/")
                let titles = notes[path] ?? []
                return titles.enumerated().map { index, title in
                    [title, fixtureNoteID(900 + index)].joined(separator: US)
                }.joined(separator: RS)
            }
            if script.contains("delete folder (item") { return "" }
            return nil
        }
        return runner
    }

    /// Did the cascade actually reach the irreversible `delete`?
    private func performedTheCascade(_ runner: FakeNotesRunner) -> Bool {
        runner.scripts.contains { $0.contains("delete folder (item") }
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
        // Enumerated under the fetched paths: two `listNotes` calls, one per resolved folder. A
        // gate that had fallen back to the typed path would have asked for `apple-cli-test parent`.
        #expect(runner.allArguments.contains("apple-cli-test Parent"))
        #expect(runner.allArguments.contains("apple-cli-test Child"))
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
            #expect(message.contains("ambiguously"), "the refusal says WHY it refused, for \(extra)")
            #expect(!performedTheCascade(runner), "nothing may be deleted on \(extra)")
        }
    }

    @Test func deleteFolderStillEnumeratesTheTypedPathWhenNothingMatchesEvenLoosely() throws {
        // The other half of the same branch, and the reason it is not simply "refuse when the
        // exact match misses": a folder that does not exist at all is not ambiguous. Nothing in the
        // account matches even under the loose fold, so the gate falls back to the typed path,
        // still enumerates ITS notes, and lets the delete fail upstream as `not_found` — the
        // pre-resolution behavior, kept deliberately. Here that fallback enumeration is what
        // catches the unlabeled note.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "Real Elsewhere")],
            notes: ["apple-cli-test ghost": ["Real Note"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test ghost", "--test-mode", "--execute"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.error["sandbox"] as? Bool == true)
        #expect((failure.error["message"] as? String)?.contains("Real Note") == true,
                "the typed-path fallback still enumerates notes rather than checking nothing")
        #expect(runner.allArguments.contains("apple-cli-test ghost"),
                "the fallback asks Notes.app about the TYPED path")
        #expect(!performedTheCascade(runner))
    }

    @Test func deleteFolderProceedsWhenTheTypedPathIsAbsentAndTheCascadeIsClean() throws {
        // The control for the two above: an absent folder whose typed-path enumeration comes back
        // clean must still reach the delete. Without this, "refuse on a loose match" could be
        // satisfied by refusing everything that does not match exactly — which would make a
        // sandboxed `delete-folder` of a not-yet-created folder impossible.
        let runner = cascadeRunner(
            folderRows: [folderRow(id: "F1", name: "Real Elsewhere")],
            notes: ["Real Elsewhere": ["Real Note"]])
        let command = try DeleteFolderCmd.parse(["apple-cli-test ghost", "--test-mode", "--execute"])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["ok"] as? Bool == true)
        #expect(performedTheCascade(runner))
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
