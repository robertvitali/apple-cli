import Foundation
import Testing
import ArgumentParser
import TestSupport
@testable import NotesKit
@testable import AppleKit

// Attachment commands and the diagnostics / export / reveal-in-UI commands.
//
// The multi-call wrappers here (`healthCheck`, `getNotesStats`, `exportNotesAsJson`) issue several
// AppleScript round trips whose ORDER is an implementation detail, so these tests answer the fake
// by what the script ASKED for rather than by call index — an order-coupled queue would turn any
// harmless reordering into a red test for no safety benefit.
//
// `doctor` additionally takes a `signatureCheck` seam. Production binds
// `DoctorCmd.binarySignatureCheck`, which shells out to `codesign`; these tests bind a stub, so no
// test in this target spawns a process.

@Suite("Notes attachments")
struct NotesAttachmentCommandTests {
    /// Owns every temp path this suite writes to; swift-testing releases the suite instance after
    /// each test, and `ScratchDirs.deinit` removes exactly the directories it vended.
    private let scratch = ScratchDirs("notes-attachment-cmd")

    private func attachmentRow(id: String, name: String, contentType: String,
                               url: String = "") -> String {
        [id, name, contentType, url, fixtureDate, fixtureDate, "false"].joined(separator: US)
    }

    // MARK: attachments (list)

    @Test func attachmentsListsByIdAndByTitle() throws {
        for args in [["--id", fixtureNoteID(1)], ["--title", "apple-cli-test note"]] {
            let runner = FakeNotesRunner(results: [
                noteRow(title: "apple-cli-test note", id: fixtureNoteID(1)),
                attachmentRow(id: "ATT1", name: "diagram.png", contentType: "public.png") + RS,
            ])
            let command = try AttachmentsCmd.parse(args)

            let data = try notesData(try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(runner) })
            })

            #expect(data["count"] as? Int == 1, "count for \(args)")
            let attachments = try #require(data["attachments"] as? [[String: Any]])
            #expect(attachments.first?["name"] as? String == "diagram.png")
            #expect(attachments.first?["content_type"] as? String == "public.png")
            #expect(attachments.first?["url"] == nil, "an empty URL field is omitted, not emitted as \"\"")
        }
    }

    @Test func attachmentsNormalizesAMissingValueUrl() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test note", id: fixtureNoteID(2)),
            attachmentRow(id: "ATT2", name: "link", contentType: "public.url", url: "missing value") + RS,
        ])
        let command = try AttachmentsCmd.parse(["--id", fixtureNoteID(2)])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        let attachments = try #require(data["attachments"] as? [[String: Any]])
        #expect(attachments.first?["url"] == nil)
    }

    @Test func attachmentsReportsNotFoundWhenTheNoteDoesNotResolve() throws {
        for args in [["--id", fixtureNoteID(3)], ["--title", "gone"]] {
            let runner = FakeNotesRunner(results: [""], whenExhausted: .empty)
            let command = try AttachmentsCmd.parse(args)

            let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

            #expect(failure.code == AppleExit.notFound, "exit for \(args)")
        }
    }

    @Test func attachmentsTextRenderingSaysSoWhenThereAreNone() throws {
        let runner = FakeNotesRunner(results: [
            noteRow(title: "apple-cli-test note", id: fixtureNoteID(4)),
            "",
        ])
        let command = try AttachmentsCmd.parse(["--id", fixtureNoteID(4), "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No attachments."))
    }

    // MARK: save-attachment

    /// A runner that stands in for Notes.app's `save`: it WRITES the bytes at argv item 3, which is
    /// what the post-save existence check inspects. Without that, the success path is unreachable
    /// and only the "Notes reported success but no file was written" branch can be exercised.
    private func savingRunner(bytes: Data = Data("synthetic-attachment".utf8)) -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        runner.handler = { script, argv in
            guard script.contains("save theAttachment"), argv.count >= 3 else { return nil }
            try? bytes.write(to: URL(fileURLWithPath: argv[2]))
            return ["OK", "diagram.png", "public.png"].joined(separator: US)
        }
        return runner
    }

    @Test func saveAttachmentWritesTheFileAndReportsThePath() throws {
        let destination = try scratch.directory().appendingPathComponent("diagram.png").path
        let runner = savingRunner()
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(1), "--attachment-id", "ATT1", "--path", destination, "--execute",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["saved_path"] as? String == destination)
        #expect(data["name"] as? String == "diagram.png")
        #expect(data["dry_run"] as? Bool == false)
        #expect(AttachmentFS.fileExists(destination))
    }

    @Test func saveAttachmentPreviewsWithoutWritingAnything() throws {
        let destination = try scratch.directory().appendingPathComponent("preview.png").path
        let runner = ThrowingNotesRunner()
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(2), "--attachment-id", "ATT2", "--path", destination, "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        #expect(data["operation"] as? String == "save-attachment")
        // The preview names the path the write would actually land on — the normalized spelling
        // `saveAttachmentById` writes — not the raw string. For an already-canonical destination
        // the two coincide; the tilde case below is where they differ.
        #expect((data["detail"] as? String)?.contains(AttachmentFS.resolvedPath(destination)) == true)
        #expect(runner.neverCalled)
        #expect(AttachmentFS.fileExists(destination) == false, "a preview must not write the file")
    }

    @Test func saveAttachmentPreviewShowsTheNormalizedDestination() throws {
        // `--dry-run` used to echo the raw argument while `--execute` wrote the normalized path,
        // so a tilde-spelled destination previewed as `~/…` and landed somewhere else-looking.
        // The preview now shows the path the write will take. Preview only: nothing is written.
        let runner = ThrowingNotesRunner()
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(21), "--attachment-id", "ATT21",
            "--path", "~/apple-cli-test-preview-only.png", "--dry-run",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        })

        let expected = AttachmentFS.resolvedPath(NSHomeDirectory()) + "/apple-cli-test-preview-only.png"
        #expect((data["detail"] as? String)?.contains(expected) == true)
        #expect((data["detail"] as? String)?.contains("~/") == false)
        #expect(runner.neverCalled)
    }

    @Test func saveAttachmentRefusesASymlinkAtTheNormalizedLeafOnBothPaths() throws {
        // The raw-leaf symlink check inspects the operator's spelling; the write goes to the
        // NORMALIZED path, and the two can name different leaves. `dir/absent/../link.bin` is
        // ENOENT as spelled (the kernel resolves `absent` before `..`), so the raw check sees no
        // link — while the normalized `dir/link.bin` IS a symlink that would redirect the bytes.
        // Both leaves are checked now; both paths refuse with the shared final-leaf refusal.
        let dir = try scratch.directory()
        let link = dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("elsewhere.bin"))
        let spelled = dir.appendingPathComponent("absent").appendingPathComponent("..").appendingPathComponent("link.bin").path
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try SaveAttachmentCmd.parse([
                "--note-id", fixtureNoteID(22), "--attachment-id", "ATT22", "--path", spelled, extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.permissionDenied, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.safetyViolation)
            #expect((failure.error["message"] as? String)?.contains("symlink") == true)
            #expect(runner.neverCalled)
        }
    }

    @Test func saveAttachmentRefusesAnOutOfRootsDestinationOnBothPaths() throws {
        // The confinement is pure string math over argv, so it belongs on the preview path too —
        // otherwise `--dry-run` reports clean for a destination `--execute` refuses.
        for extra in ["--execute", "--dry-run"] {
            let runner = ThrowingNotesRunner()
            let command = try SaveAttachmentCmd.parse([
                "--note-id", fixtureNoteID(3), "--attachment-id", "ATT3",
                "--path", "/etc/apple-cli-test.png", extra,
            ])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
            }

            #expect(failure.code == AppleExit.usage, "exit for \(extra)")
            #expect(failure.error["type"] as? String == AppleErrorType.validation,
                    "an out-of-roots destination is bad INPUT, not an upstream failure")
            #expect((failure.error["message"] as? String)?.contains("outside allowed locations") == true)
            #expect(runner.neverCalled)
        }
    }

    @Test func saveAttachmentValidatesTheWriteEnvironmentBeforeThePath() throws {
        // `resolveNotesWrite`'s contract is that BOTH v2 variables are validated EAGERLY, before
        // any work — a typo'd `APPLE_TEST_MODE` must refuse the command rather than be ignored.
        // With the path check running first, a second problem on the same command line masked the
        // malformed environment, which is the one thing the fail-loud contract exists to prevent.
        // The variable name is test-owned, so nothing else in the process reads it.
        let name = "APPLE_NOTESKIT_TESTONLY_SAVE_ATT_BAD_DRY_RUN"
        let env = NotesWriteEnv(testModeVar: "APPLE_NOTESKIT_TESTONLY_SAVE_ATT_UNSET_MODE",
                                dryRunVar: name,
                                sandboxPrefix: TestMode.canonicalSandboxPrefix)
        let runner = ThrowingNotesRunner()
        // The path is ALSO invalid, so the assertion is about which check speaks first.
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(11), "--attachment-id", "ATT11",
            "--path", "/etc/apple-cli-test.png", "--execute",
        ])

        let failure = try TestEnvironment.with([name: "maybe"]) {
            try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }, env: env) }
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == AppleErrorType.validation)
        let message = try #require(failure.error["message"] as? String)
        #expect(message.contains(name), "the malformed environment variable is what is reported")
        #expect(message.contains("outside allowed locations") == false,
                "the path check must not preempt the eager environment validation")
        #expect(runner.neverCalled)
    }

    @Test func saveAttachmentRefusesARelativeDestination() throws {
        let runner = ThrowingNotesRunner()
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(4), "--attachment-id", "ATT4", "--path", "relative.png", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("must be absolute") == true)
        #expect(runner.neverCalled)
    }

    @Test func saveAttachmentSurfacesTheLinkPreviewHintWhenNotesCannotSave() throws {
        let dir = try scratch.directory().path
        let runner = FakeNotesRunner(results: [
            ["ERRSAVE", "no file payload", "https://example.com/page"].joined(separator: US),
        ])
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(5), "--attachment-id", "ATT5",
            "--path", dir + "/link.png", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect(failure.code == AppleExit.upstream)
        let message = try #require(failure.error["message"] as? String)
        #expect(message.contains("no file payload"))
        #expect(message.contains("link preview"))
    }

    @Test func saveAttachmentReportsAMissingAttachment() throws {
        let dir = try scratch.directory().path
        let runner = FakeNotesRunner(results: [["ERR", "attachment not found"].joined(separator: US)])
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(6), "--attachment-id", "ATT6",
            "--path", dir + "/missing.png", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("attachment not found") == true)
    }

    @Test func saveAttachmentRefusesToClaimSuccessWhenNoFileLanded() throws {
        let dir = try scratch.directory().path
        // Notes says OK but writes nothing — the post-save existence check must catch it.
        let runner = FakeNotesRunner(results: [["OK", "diagram.png", "public.png"].joined(separator: US)])
        let command = try SaveAttachmentCmd.parse([
            "--note-id", fixtureNoteID(7), "--attachment-id", "ATT7",
            "--path", dir + "/never-written.png", "--execute",
        ])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { quietScript(runner) }, env: pinnedWriteEnv())
        }

        #expect((failure.error["message"] as? String)?.contains("no file was written") == true)
    }

    // MARK: fetch-attachment

    @Test func fetchAttachmentReturnsBase64Bytes() throws {
        let payload = Data("apple-cli-test bytes".utf8)
        let runner = savingRunner(bytes: payload)
        let command = try FetchAttachmentCmd.parse([
            "--note-id", fixtureNoteID(8), "--attachment-id", "ATT8",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        #expect(data["base64"] as? String == payload.base64EncodedString())
        #expect(data["bytes"] as? Int == payload.count)
        #expect(data["name"] as? String == "diagram.png")
    }

    @Test func fetchAttachmentSurfacesTheUnderlyingSaveFailure() throws {
        let runner = FakeNotesRunner(results: [["ERR", "attachment not found"].joined(separator: US)])
        let command = try FetchAttachmentCmd.parse([
            "--note-id", fixtureNoteID(9), "--attachment-id", "ATT9",
        ])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(failure.code == AppleExit.upstream)
        #expect((failure.error["message"] as? String)?.contains("attachment not found") == true)
    }

    // MARK: show-attachment

    @Test func showAttachmentRevealsAndEchoesItsArguments() throws {
        let runner = FakeNotesRunner(results: ["OK"])
        let command = try ShowAttachmentCmd.parse([
            "--note-id", fixtureNoteID(10), "--attachment-id", "ATT10", "--separately",
        ])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        #expect(data["note_id"] as? String == fixtureNoteID(10))
        #expect(data["attachment_id"] as? String == "ATT10")
        #expect(data["separately"] as? Bool == true)
        #expect(runner.arguments.first == [fixtureNoteID(10), "ATT10"])
        // `separately` is a structural clause, not user data, so it IS in the source.
        #expect(runner.scripts.first?.contains("separately true") == true)
    }

    @Test func showAttachmentReportsNotFound() throws {
        let runner = FakeNotesRunner(results: [["ERR", "attachment not found"].joined(separator: US)])
        let command = try ShowAttachmentCmd.parse([
            "--note-id", fixtureNoteID(11), "--attachment-id", "ATT11",
        ])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(failure.code == AppleExit.notFound)
        #expect((failure.error["message"] as? String)?.contains("ATT11") == true)
    }
}

@Suite("Notes diagnostics, export, and reveal-in-UI")
struct NotesDiagCommandTests {

    private let accountRow = ["A1", "Example Account", "true", "F1", "Notes"].joined(separator: US)

    /// A stub `codesign` verdict, so no test here spawns a process.
    private func signature(_ status: String) -> DoctorCheck {
        DoctorCheck(name: "Binary signature", status: status, detail: "stubbed for the logic tier")
    }

    /// Answers each script by what it asked for. Order-independent by design (see the file header).
    private func healthyRunner(accounts: String? = nil) -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        let accountsOut = accounts ?? (accountRow + RS)
        runner.handler = { script, _ in
            if script.contains("return \"ok\"") { return "ok" }
            if script.contains("return name of account 1") { return "Example Account" }
            if script.contains("repeat with a in accounts") { return accountsOut }
            if script.contains("set noteList to") || script.contains("set out to out") { return "" }
            return nil
        }
        runner.whenExhausted = .empty
        return runner
    }

    // MARK: sync-status

    @Test func syncStatusEmitsTheInjectedStoreSnapshot() throws {
        let store = StubNotesStore()
        var status = NotesSyncStatus()
        status.sync_detected = true
        status.pending_upload = 4
        status.seconds_since_last_change = 2
        status.recent_activity = true
        status.warning = "iCloud sync in progress"
        store.sync = status
        let command = try SyncStatusCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(storeFactory: { store })
        })

        #expect(data["sync_detected"] as? Bool == true)
        #expect(data["pending_upload"] as? Int == 4)
        #expect(data["recent_activity"] as? Bool == true)
    }

    @Test func syncStatusTextRenderingReportsBothStates() throws {
        for (detected, expected) in [(true, "iCloud sync: ACTIVE"), (false, "iCloud sync: idle")] {
            let store = StubNotesStore()
            var status = NotesSyncStatus()
            status.sync_detected = detected
            store.sync = status
            let command = try SyncStatusCmd.parse(["--text"])

            let (streams, stdout) = notesStreams()
            try Output.withStreams(streams) { try command.run(storeFactory: { store }) }

            #expect(String(decoding: stdout.data, as: UTF8.self).contains(expected))
        }
    }

    // MARK: health

    @Test func healthReportsHealthyWithFullDiskAccess() throws {
        let store = StubNotesStore.quiet()
        store.fda = true
        let runner = healthyRunner()
        let command = try HealthCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["healthy"] as? Bool == true)
        #expect(data["full_disk_access"] as? Bool == true)
        let checks = try #require(data["checks"] as? [[String: Any]])
        #expect(checks.map { $0["name"] as? String } == ["notes_app", "permissions", "accounts", "operations"])
    }

    @Test func healthStopsAtTheFirstFailureWhenNotesAppIsUnreachable() throws {
        let store = StubNotesStore.quiet()
        store.fda = false
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in throw AppleError.upstream("Notes.app is not running.") }
        let command = try HealthCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["healthy"] as? Bool == false)
        #expect(data["full_disk_access"] as? Bool == false)
        let checks = try #require(data["checks"] as? [[String: Any]])
        #expect(checks.count == 1, "the probe short-circuits once Notes.app is unreachable")
    }

    @Test func healthReportsAnAutomationPermissionDenial() throws {
        let store = StubNotesStore.quiet()
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("return \"ok\"") { return "ok" }
            throw AppleError.permissionDenied("Automation permission denied.")
        }
        let command = try HealthCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["healthy"] as? Bool == false)
        let checks = try #require(data["checks"] as? [[String: Any]])
        #expect(checks.last?["name"] as? String == "permissions")
        #expect((checks.last?["message"] as? String)?.contains("System Settings") == true)
    }

    @Test func healthReportsNoAccountsConfigured() throws {
        let store = StubNotesStore.quiet()
        let runner = healthyRunner(accounts: "")
        let command = try HealthCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })

        #expect(data["healthy"] as? Bool == false)
        let checks = try #require(data["checks"] as? [[String: Any]])
        #expect(checks.last?["name"] as? String == "accounts")
    }

    @Test func healthTextRenderingCarriesTheFdaFlag() throws {
        let store = StubNotesStore.quiet()
        store.fda = false
        let runner = healthyRunner()
        let command = try HealthCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("FDA: false"))
    }

    // MARK: doctor

    @Test func doctorAggregatesHealthAccountsFdaAndTheSignatureCheck() throws {
        let store = StubNotesStore.quiet()
        store.fda = true
        let runner = healthyRunner()
        let command = try DoctorCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store },
                            signatureCheck: { self.signature("ok") })
        })

        #expect(data["healthy"] as? Bool == true)
        let checks = try #require(data["checks"] as? [[String: Any]])
        let names = checks.compactMap { $0["name"] as? String }
        #expect(names.contains("Accounts"))
        #expect(names.contains("Full Disk Access"))
        #expect(names.contains("Binary signature"))
        #expect(names.contains("Notes.app: notes_app"))
    }

    @Test func doctorWarnsWhenFullDiskAccessIsMissing() throws {
        let store = StubNotesStore.quiet()
        store.fda = false
        let runner = healthyRunner()
        let command = try DoctorCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store },
                            signatureCheck: { self.signature("warn") })
        })

        let checks = try #require(data["checks"] as? [[String: Any]])
        let fda = try #require(checks.first { $0["name"] as? String == "Full Disk Access" })
        #expect(fda["status"] as? String == "warn")
        #expect((fda["detail"] as? String)?.contains("not granted") == true)
    }

    @Test func doctorMarksTheRunUnhealthyWhenAnythingFails() throws {
        let store = StubNotesStore.quiet()
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in throw AppleError.upstream("Notes.app is not running.") }
        let command = try DoctorCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store },
                            signatureCheck: { self.signature("warn") })
        }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("ISSUES FOUND"))
    }

    @Test func doctorReportsWhenAccountsCannotBeListed() throws {
        let store = StubNotesStore.quiet()
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("repeat with a in accounts") {
                throw AppleError.upstream("account enumeration failed")
            }
            if script.contains("return \"ok\"") { return "ok" }
            return ""
        }
        let command = try DoctorCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store },
                            signatureCheck: { self.signature("ok") })
        })

        let checks = try #require(data["checks"] as? [[String: Any]])
        let accounts = try #require(checks.first { $0["name"] as? String == "Accounts" })
        #expect(accounts["status"] as? String == "fail")
        #expect(data["healthy"] as? Bool == false)
    }

    // MARK: doctor — the real signature check's classification

    // Every `doctor` test above binds a STUB `signatureCheck:`, which is correct (the production
    // binding shells out to `codesign`) but left the real check's decision covered by nothing:
    // `DoctorCmd.binarySignatureCheck` is bound only by `DoctorCmd.run()`, so all four of its
    // outcomes were unreachable from the logic tier. `classifySignature` is that decision, split
    // out from the spawn; these are its branches. The spawn itself stays knowingly untested — see
    // the comment on `binarySignatureCheck`.

    @Test func signatureClassifierWarnsOnAnAdHocSignature() {
        let check = DoctorCmd.classifySignature(
            "Executable=/opt/apple\nIdentifier=apple\nSignature=adhoc\n", executable: "/opt/apple")
        #expect(check.name == DoctorCmd.signatureCheckName)
        #expect(check.status == "warn")
        #expect(check.detail.contains("ad-hoc signed"))
        #expect(check.detail.contains("/opt/apple"), "the detail names the binary it inspected")
    }

    @Test func signatureClassifierWarnsWhenNoTeamIdentifierIsSet() {
        // The second ad-hoc tell, and a separate branch: a signature can be present while the Team
        // ID is absent, which loses TCC grants the same way.
        let check = DoctorCmd.classifySignature(
            "Executable=/opt/apple\nTeamIdentifier=not set\n", executable: "/opt/apple")
        #expect(check.status == "warn")
        #expect(check.detail.contains("ad-hoc signed"))
    }

    @Test func signatureClassifierWarnsOnEmptyCodesignOutput() {
        // codesign ran but reported nothing. Not a pass, and not a definite ad-hoc — its own
        // wording, so the operator can tell "could not inspect" from "inspected, and it is ad-hoc".
        let check = DoctorCmd.classifySignature("", executable: "/opt/apple")
        #expect(check.status == "warn")
        #expect(check.detail.contains("could not inspect"))
        #expect(check.detail.contains("ad-hoc") == false)
    }

    @Test func signatureClassifierTreatsWhitespaceOnlyOutputAsNoAnswer() {
        // A lone newline is the same non-answer as "" — it says nothing about the signature. An
        // `isEmpty` check classified it `ok` ("stable signature"), i.e. the most reassuring verdict
        // on a security-posture check, for output that carried no verdict at all.
        for blank in ["\n", "   ", " \n\t\n"] {
            let check = DoctorCmd.classifySignature(blank, executable: "/opt/apple")
            #expect(check.status == "warn", "whitespace-only output must not read as a pass: \(blank.debugDescription)")
            #expect(check.detail.contains("could not inspect"))
        }
    }

    @Test func signatureClassifierDoesNotFireOnANearMissOfEitherAdHocTell() {
        // Honest scope: switching `Signature=adhoc` from `range(of:options: .regularExpression)` to
        // `contains` is not observable from outside — the tell carries no metacharacters, so the
        // two matchers agree on every input. What IS observable, and what this pins, is that
        // neither tell has been loosened into something that fires on a one-character near-miss;
        // that is the regression a future edit adding a `.` or `+` to a tell would produce.
        #expect(DoctorCmd.classifySignature("Signature=adhoc\n", executable: "/opt/apple").status == "warn")
        #expect(DoctorCmd.classifySignature("SignatureXadhoc\n", executable: "/opt/apple").status == "ok")
        #expect(DoctorCmd.classifySignature("TeamIdentifier=not set\n", executable: "/opt/apple").status == "warn")
        #expect(DoctorCmd.classifySignature("TeamIdentifierXnot set\n", executable: "/opt/apple").status == "ok")
    }

    @Test func signatureClassifierPassesAStableSignature() {
        let check = DoctorCmd.classifySignature(
            "Executable=/opt/apple\nAuthority=Developer ID Application: Example\nTeamIdentifier=ABCDE12345\n",
            executable: "/opt/apple")
        #expect(check.status == "ok")
        #expect(check.detail.contains("stable signature"))
    }

    // MARK: stats

    @Test func statsSumsPerFolderCountsAcrossAccounts() throws {
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("repeat with a in accounts") { return self.accountRow + RS }
            if script.contains("count of notes of fldr") {
                return ["Notes", "3"].joined(separator: US) + RS + ["Archive", "2"].joined(separator: US) + RS
            }
            if script.contains("modification date >= d1") {
                return ["1", "4", "9"].joined(separator: US)
            }
            return nil
        }
        let command = try StatsCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        #expect(data["total_notes"] as? Int == 5)
        let recent = try #require(data["recently_modified"] as? [String: Any])
        #expect(recent["last_24h"] as? Int == 1)
        #expect(recent["last_30d"] as? Int == 9)
        let coverage = try #require(data["coverage"] as? [String: Any])
        #expect(coverage["complete"] as? Bool == true)
    }

    @Test func statsFlagsPartialCoverageWhenAnAccountOrTheRecentProbeFails() throws {
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("repeat with a in accounts") {
                return self.accountRow + RS + ["A2", "Second Account", "true", "F2", "Notes"]
                    .joined(separator: US) + RS
            }
            if script.contains("count of notes of fldr") {
                // Fail for the second account only.
                return ["Notes", "1"].joined(separator: US) + RS
            }
            if script.contains("modification date >= d1") {
                throw AppleError.upstream("recent probe failed")
            }
            return nil
        }
        let command = try StatsCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(runner) })
        })

        let coverage = try #require(data["coverage"] as? [String: Any])
        #expect(coverage["complete"] as? Bool == false)
        let warnings = try #require(coverage["warnings"] as? [[String: Any]])
        #expect(warnings.contains { $0["scope"] as? String == "recent-activity" })
    }

    @Test func statsFailsWhenNoAccountCouldBeRead() throws {
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("repeat with a in accounts") { return self.accountRow + RS }
            throw AppleError.upstream("folder scan failed")
        }
        let command = try StatsCmd.parse([])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(failure.code == AppleExit.upstream)
        #expect((failure.error["message"] as? String)?.contains("Failed to read folder stats") == true)
    }

    // MARK: export

    private func exportRunner() -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in
            if script.contains("repeat with a in accounts") { return self.accountRow + RS }
            if script.contains("set allFolders to every folder") {
                return ["F1", "Notes", "", "false"].joined(separator: US) + RS
            }
            if script.contains("set noteProps to") {
                return noteRow(title: "apple-cli-test exported", id: fixtureNoteID(1))
            }
            if script.contains("return body of note") { return "<div>exported body</div>" }
            // listNotes
            return "apple-cli-test exported" + RS
        }
        return runner
    }

    @Test func exportJsonSummarizesTheLibrary() throws {
        let command = try ExportCmd.parse([])

        let data = try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { quietScript(exportRunner()) })
        })

        let summary = try #require(data["summary"] as? [String: Any])
        #expect(summary["total_notes"] as? Int == 1)
        #expect(summary["total_folders"] as? Int == 1)
        #expect(summary["total_accounts"] as? Int == 1)
    }

    @Test func exportMarkdownAndTextRenderTheNoteBodies() throws {
        for (format, fragment) in [("md", "# apple-cli-test exported"), ("txt", "apple-cli-test exported")] {
            let command = try ExportCmd.parse(["--format", format])

            let data = try notesData(try captureNotesEnvelope {
                try command.run(scriptFactory: { quietScript(exportRunner()) })
            })

            #expect(data["format"] as? String == format)
            #expect(data["note_count"] as? Int == 1)
            #expect((data["content"] as? String)?.contains(fragment) == true, "content for \(format)")
        }
    }

    @Test func exportRefusesAnUnknownFormat() throws {
        let command = try ExportCmd.parse(["--format", "pdf"])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(exportRunner()) }) }

        #expect(failure.code == AppleExit.usage)
        #expect((failure.error["message"] as? String)?.contains("expected json|md|txt") == true)
    }

    @Test func exportTextRenderingSummarizesTheCounts() throws {
        let command = try ExportCmd.parse(["--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) { try command.run(scriptFactory: { quietScript(exportRunner()) }) }

        #expect(String(decoding: stdout.data, as: UTF8.self).contains("Exported 1 notes from 1 folders."))
    }

    // MARK: reveal in UI

    @Test func showNoteFolderAndAccountEachRevealByIdViaArgv() throws {
        let noteRunner = FakeNotesRunner(results: [""])
        let note = try ShowNoteCmd.parse(["--id", fixtureNoteID(1)])
        var data = try notesData(try captureNotesEnvelope {
            try note.run(scriptFactory: { quietScript(noteRunner) })
        })
        #expect(data["id"] as? String == fixtureNoteID(1))
        #expect(data["separately"] as? Bool == false)
        #expect(noteRunner.arguments == [[fixtureNoteID(1)]])
        #expect(noteRunner.scripts.first?.contains("show note id") == true)

        let folderRunner = FakeNotesRunner(results: [""])
        let folder = try ShowFolderCmd.parse(["--id", "F1", "--separately"])
        data = try notesData(try captureNotesEnvelope {
            try folder.run(scriptFactory: { quietScript(folderRunner) })
        })
        #expect(data["separately"] as? Bool == true)
        #expect(folderRunner.scripts.first?.contains("show folder id") == true)

        let accountRunner = FakeNotesRunner(results: [""])
        let account = try ShowAccountCmd.parse(["--id", "A1"])
        data = try notesData(try captureNotesEnvelope {
            try account.run(scriptFactory: { quietScript(accountRunner) })
        })
        #expect(data["id"] as? String == "A1")
        #expect(accountRunner.scripts.first?.contains("show account id") == true)
    }

    @Test func showNoteSurfacesAnUpstreamFailure() throws {
        let runner = ThrowingNotesRunner()
        let command = try ShowNoteCmd.parse(["--id", fixtureNoteID(2)])

        let failure = try captureNotesFailure { try command.run(scriptFactory: { quietScript(runner) }) }

        #expect(failure.code == AppleExit.upstream)
    }
}

@Suite("Notes output policy — diagnostics and export boundaries")
struct NotesDiagOutputPolicyTests {
    @Test(arguments: notesPolicyScenarios(["app", "permission", "accounts", "notes", "doctor-accounts", "doctor-health"]))
    func healthAndDoctorKeepPolicyFailures(_ scenario: NotesPolicyScenario) throws {
        let error = scenario.policy.error(marked: scenario.marked)
        let runner = FakeNotesRunner()
        let store = StubNotesStore.quiet()
        var phases: [String] = []
        var accountCalls = 0
        var signatureCalls = 0
        runner.handler = { source, _ in
            let phase: String
            let reply: String
            if source.contains("return \"ok\"") { phase = "app"; reply = "ok" }
            else if source.contains("return name of account 1") { phase = "permission"; reply = "Example Account" }
            else if source.contains("repeat with a in accounts") {
                accountCalls += 1
                phase = accountCalls == 1 ? "accounts" : "doctor-accounts"
                reply = policyAccountRows(["Example Account"])
            } else {
                #expect(source.contains("set end of resultList to noteName"))
                phase = "notes"; reply = ""
            }
            phases.append(phase)
            if phase == scenario.phase || (scenario.phase == "doctor-health" && phase == "app") { throw error }
            return reply
        }
        let run: () throws -> Void = {
            if scenario.phase.hasPrefix("doctor-") {
                let command = try DoctorCmd.parse([])
                try command.run(scriptFactory: { NotesScript(runner: runner, store: store) }, storeFactory: { store },
                    signatureCheck: {
                        signatureCalls += 1
                        return DoctorCheck(name: "Synthetic signature", status: "ok", detail: "synthetic")
                    })
            } else {
                let command = try HealthCmd.parse([])
                try command.run(scriptFactory: { NotesScript(runner: runner, store: store) }, storeFactory: { store })
            }
        }
        let order = ["app", "permission", "accounts", "notes", "doctor-accounts"]
        if scenario.marked {
            try expectNotesPolicyFailure(error, run)
            let failedPhase = scenario.phase == "doctor-health" ? "app" : scenario.phase
            let last = try #require(order.firstIndex(of: failedPhase))
            #expect(phases == Array(order.prefix(last + 1)))
            #expect(signatureCalls == 0)
        } else {
            let data = try notesData(captureNotesEnvelope(run))
            let checks = try #require(data["checks"] as? [[String: Any]])
            switch scenario.phase {
            case "app":
                #expect(phases == ["app"])
                #expect(data["healthy"] as? Bool == false)
                #expect(checks.count == 1)
            case "accounts":
                #expect(phases == Array(order.prefix(3)))
                #expect(data["healthy"] as? Bool == false)
                #expect(checks.last?["name"] as? String == "accounts")
            case "doctor-health":
                #expect(phases == ["app", "accounts"])
                #expect(signatureCalls == 1)
                #expect(data["healthy"] as? Bool == false)
            case "doctor-accounts":
                #expect(phases == order)
                #expect(signatureCalls == 1)
                #expect(checks.contains { $0["name"] as? String == "Accounts" && $0["status"] as? String == "fail" })
            default:
                #expect(phases == Array(order.prefix(4)))
                #expect(data["healthy"] as? Bool == true)
                if scenario.phase == "permission" {
                    #expect(checks[1]["message"] as? String == "Permission check returned an error")
                } else {
                    #expect(checks.last?["message"] as? String == "Basic operations working (0 note(s) in Example Account)")
                }
            }
        }
    }

    @Test(arguments: notesPolicyScenarios(["account", "recent"]))
    func statsKeepPolicyFailuresInsteadOfCoverageWarnings(_ scenario: NotesPolicyScenario) throws {
        let error = scenario.policy.error(marked: scenario.marked)
        let runner = FakeNotesRunner()
        var phases: [String] = []
        runner.handler = { source, args in
            if source.contains("repeat with a in accounts") {
                phases.append("accounts"); return policyAccountRows(["Example One", "Example Two"])
            }
            if source.contains("count of notes of fldr") {
                let account = try #require(args.first)
                phases.append(account)
                if scenario.phase == "account" && account == "Example One" { throw error }
                return ["Notes", "1"].joined(separator: US) + RS
            }
            #expect(source.contains("modification date >= d1"))
            phases.append("recent")
            if scenario.phase == "recent" { throw error }
            return ["1", "1", "1"].joined(separator: US)
        }
        let command = try StatsCmd.parse([])
        let run = { try command.run(scriptFactory: { quietScript(runner) }) }
        if scenario.marked {
            try expectNotesPolicyFailure(error, run)
            #expect(phases == (scenario.phase == "account" ? ["accounts", "Example One"] : ["accounts", "Example One", "Example Two", "recent"]))
        } else {
            let data = try notesData(captureNotesEnvelope(run))
            #expect(phases == ["accounts", "Example One", "Example Two", "recent"])
            let coverage = try #require(data["coverage"] as? [String: Any])
            #expect(coverage["complete"] as? Bool == false)
            let warnings = try #require(coverage["warnings"] as? [[String: Any]])
            #expect(warnings.count == 1)
            #expect(warnings.first?["reason"] as? String == error.message)
            #expect(data["total_notes"] as? Int == (scenario.phase == "account" ? 1 : 2))
            let recent = try #require(data["recently_modified"] as? [String: Any])
            #expect(recent["last_24h"] as? Int == (scenario.phase == "recent" ? 0 : 1))
        }
    }

    @Test(arguments: notesPolicyScenarios(["folders", "titles", "details", "body"]))
    func exportKeepsPolicyFailuresAtEachOptionalLookup(_ scenario: NotesPolicyScenario) throws {
        let error = scenario.policy.error(marked: scenario.marked)
        let runner = FakeNotesRunner()
        var phases: [String] = []
        runner.handler = { source, args in
            if source.contains("repeat with a in accounts") {
                phases.append("accounts"); return policyAccountRows(["Example Account"])
            }
            let phase: String
            let reply: String
            if source.contains("set allFolders to every folder") {
                phase = "folders"; reply = ["F1", "Notes", "", "false"].joined(separator: US) + RS
            } else if source.contains("set noteProps to") {
                let title = try #require(args.first)
                phase = title == "apple-cli-test one" ? "details" : "details-two"
                reply = noteRow(title: title, id: fixtureNoteID(1))
            } else if source.contains("return body of note") {
                phase = args.first == "apple-cli-test one" ? "body" : "body-two"
                reply = "<div>synthetic content</div>"
            } else {
                #expect(source.contains("set end of resultList to noteName"))
                phase = "titles"; reply = "apple-cli-test one" + RS + "apple-cli-test two" + RS
            }
            phases.append(phase)
            if phase == scenario.phase { throw error }
            return reply
        }
        let command = try ExportCmd.parse([])
        let run = { try command.run(scriptFactory: { quietScript(runner) }) }
        let order = ["accounts", "folders", "titles", "details", "body", "details-two", "body-two"]
        if scenario.marked {
            try expectNotesPolicyFailure(error, run)
            let last = try #require(order.firstIndex(of: scenario.phase))
            #expect(phases == Array(order.prefix(last + 1)))
        } else {
            let data = try notesData(captureNotesEnvelope(run))
            let summary = try #require(data["summary"] as? [String: Any])
            switch scenario.phase {
            case "folders":
                #expect(phases == ["accounts", "folders"])
                #expect(summary["total_folders"] as? Int == 0)
            case "titles":
                #expect(phases == ["accounts", "folders", "titles"])
                #expect(summary["total_notes"] as? Int == 0)
            case "details":
                #expect(phases == order.filter { $0 != "body" })
                #expect(summary["total_notes"] as? Int == 1)
            default:
                #expect(phases == order)
                #expect(summary["total_notes"] as? Int == 2)
                let accounts = try #require(data["accounts"] as? [[String: Any]])
                let folders = try #require(accounts.first?["folders"] as? [[String: Any]])
                let notes = try #require(folders.first?["notes"] as? [[String: Any]])
                #expect(notes.first?["content"] as? String == "")
            }
        }
    }
}
