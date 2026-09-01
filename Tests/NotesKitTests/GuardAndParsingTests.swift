import Testing
import Foundation
@testable import NotesKit
@testable import AppleKit

@Suite("AttachmentFS — path-traversal guard")
struct AttachmentFSTests {
    @Test("accepts paths under home and temp")
    func accepts() throws {
        let home = NSHomeDirectory()
        #expect(try AttachmentFS.assertSafeSavePath(home + "/Downloads/x.png") == AttachmentFS.resolvedPath(home + "/Downloads/x.png"))
        let tmp = NSTemporaryDirectory() + "y.bin"
        #expect((try? AttachmentFS.assertSafeSavePath(tmp)) != nil)
    }

    @Test("accepts /Volumes and home credential spellings per Notes oracle policy")
    func acceptsVolumesAndHomeCredentialSpelling() throws {
        let homeCredentialPath = NSHomeDirectory() + "/.ssh/apple-cli-test-placeholder.bin"
        #expect(try AttachmentFS.assertSafeSavePath(homeCredentialPath) == AttachmentFS.resolvedPath(homeCredentialPath))
        let volumesPath = "/Volumes/apple-cli-test-drive/file.bin"
        #expect(try AttachmentFS.assertSafeSavePath(volumesPath) == AttachmentFS.resolvedPath(volumesPath))
    }

    @Test("rejects paths outside the allowed roots")
    func rejectsOutside() {
        #expect(throws: AttachmentFS.FSError.self) { try AttachmentFS.assertSafeSavePath("/etc/passwd") }
        #expect(throws: AttachmentFS.FSError.self) { try AttachmentFS.assertSafeSavePath("/usr/local/x") }
    }

    @Test("rejects relative paths")
    func rejectsRelative() {
        #expect(throws: AttachmentFS.FSError.self) { try AttachmentFS.assertSafeSavePath("relative/path.png") }
    }

    @Test("rejects `..` traversal that escapes the home root")
    func rejectsTraversal() {
        let home = "/apple-cli-test/home"
        let traversal = home + "/../outside/file.bin"
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath(traversal, roots: [home])
        }
    }

    @Test("empty path rejected")
    func rejectsEmpty() {
        #expect(throws: AttachmentFS.FSError.self) { try AttachmentFS.assertSafeSavePath("   ") }
    }

    @Test("symlink-aware re-check rejects a symlinked parent that escapes the allowed roots")
    func rejectsSymlinkedParentEscape() throws {
        // Create <tmp>/apple-cli-symtest/link -> /etc, then a dest under link/. The lexical guard
        // passes (path is textually under tmp), but assertResolvedParentContained resolves the
        // symlink to /etc and must reject.
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "apple-cli-symtest-\(UUID().uuidString)"
        let link = base + "/link"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "/etc")
        let dest = link + "/evil.png"
        // Lexical guard: passes (textually under temp).
        #expect((try? AttachmentFS.assertSafeSavePath(dest)) != nil)
        // Symlink-aware guard: the real parent is /etc → rejected.
        #expect(throws: AttachmentFS.FSError.self) { try AttachmentFS.assertResolvedParentContained(dest) }
    }

    @Test("symlink-aware re-check accepts a legitimate parent under an allowed root")
    func acceptsRealParentUnderRoot() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "apple-cli-oktest-\(UUID().uuidString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        // A real (non-symlinked) dir under temp resolves within an allowed root → no throw.
        try AttachmentFS.assertResolvedParentContained(dir + "/file.bin")
    }
}

@Suite("NotesScript — folder path + refs")
struct FolderPathTests {
    @Test("splitFolderPath splits on unescaped slash, unescapes, drops empties")
    func split() {
        #expect(NotesScript.splitFolderPath("Work/Clients/Omnia") == ["Work", "Clients", "Omnia"])
        #expect(NotesScript.splitFolderPath("A//B") == ["A", "B"])
        #expect(NotesScript.splitFolderPath("Escaped\\/Slash") == ["Escaped/Slash"])
        #expect(NotesScript.splitFolderPath("") == [])
    }

    @Test("folderRefExpr builds a reversed argv-referencing specifier")
    func folderRef() {
        let (expr, args) = NotesScript.folderRefExpr(["A", "B", "C"], startIndex: 2)
        // Deepest first: C(item4) of B(item3) of A(item2)
        #expect(expr == "folder (item 4 of argv) of folder (item 3 of argv) of folder (item 2 of argv)")
        #expect(args == ["A", "B", "C"]) // original order appended to argv
    }

    @Test("buildFolderPaths resolves nested paths via parentId")
    func buildPaths() {
        // Two rows: root "Work" (id w, no parent), child "Clients" (id c, parent w).
        let out = "w\u{1F}Work\u{1F}\u{1F}false\u{1E}c\u{1F}Clients\u{1F}w\u{1F}false"
        let folders = NotesScript.buildFolderPaths(out, account: "iCloud")
        let names = Set(folders.map { $0.name })
        #expect(names.contains("Work"))
        #expect(names.contains("Work/Clients"))
    }
}

@Suite("NotesScript — id validation + parsing")
struct ScriptParsingTests {
    @Test("isValidNoteId accepts coredata + temp ids, rejects junk")
    func idValidation() {
        #expect(NotesScript.isValidNoteId("x-coredata://ABC-123/ICNote/p58"))
        #expect(NotesScript.isValidNoteId("temp-123-4"))
        #expect(!NotesScript.isValidNoteId("bogus"))
        #expect(!NotesScript.isValidNoteId("x-coredata://ABC/ICNote/pX"))
        #expect(!NotesScript.isValidNoteId("'; do shell script \"rm -rf\" --"))
    }

    @Test("parseDate reads y-mo-d-h-mi-s numeric parts")
    func parseDate() {
        let d = NotesScript.parseDate("2025-3-14-9-30-5")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        #expect(c.year == 2025 && c.month == 3 && c.day == 14 && c.hour == 9 && c.minute == 30 && c.second == 5)
    }

    @Test("parseNoteProps splits the 6-field row")
    func noteProps() {
        let row = "My Title\u{1F}x-coredata://A/ICNote/p1\u{1F}2025-1-1-0-0-0\u{1F}2025-1-2-0-0-0\u{1F}false\u{1F}true"
        let note = NotesScript.parseNoteProps(row)
        #expect(note?.title == "My Title")
        #expect(note?.id == "x-coredata://A/ICNote/p1")
        #expect(note?.shared == false)
        #expect(note?.passwordProtected == true)
    }

    @Test("extractId pulls a coredata id after 'note id'")
    func extractId() {
        #expect(NotesScript.extractId("note id x-coredata://A/ICNote/p5", prefix: "note") == "x-coredata://A/ICNote/p5")
        #expect(NotesScript.extractId("folder id x-coredata://A/ICFolder/p7 more", prefix: "folder") == "x-coredata://A/ICFolder/p7")
    }

    @Test("parseSummaries dedupes by id, drops empty titles, sets account")
    func summaries() {
        let out = "One\u{1F}id1\u{1F}Work\u{1E}Two\u{1F}id2\u{1F}Home\u{1E}One\u{1F}id1\u{1F}Work"
        let summaries = NotesScript.parseSummaries(out, account: "iCloud")
        #expect(summaries.count == 2)
        #expect(summaries[0].title == "One" && summaries[0].id == "id1" && summaries[0].folder == "Work")
        #expect(summaries[0].account == "iCloud") // real account field carried through
    }

    @Test("parseAttachments maps fields, normalizes missing url")
    func attachments() {
        let row = "attId\u{1F}photo.png\u{1F}public.png\u{1F}missing value\u{1F}2025-1-1-0-0-0\u{1F}2025-1-1-0-0-0\u{1F}false"
        let atts = NotesScript.parseAttachments(row)
        #expect(atts.count == 1)
        #expect(atts[0].id == "attId" && atts[0].name == "photo.png" && atts[0].content_type == "public.png")
        #expect(atts[0].url == nil) // "missing value" normalized to nil
        #expect(atts[0].shared == false)
    }

    @Test("mapBatchStatus maps status tokens to results")
    func batchStatus() {
        #expect(NotesScript.mapBatchStatus("id", "ok", op: "delete").success)
        #expect(NotesScript.mapBatchStatus("id", "pw", op: "delete").error == "Note is password-protected")
        #expect(NotesScript.mapBatchStatus("id", "missing", op: "move").error == "Note not found")
        #expect(NotesScript.mapBatchStatus("id", "fail", op: "move").error == "Move failed")
    }
}

// MARK: - Write-model v2 posture (docs/write-model-v2.md)

/// Pins the v2 DECISION `resolveNotesWrite` makes, which nothing else can catch. The bats tier
/// cannot assert "a flagless notes write executes" without actually mutating the operator's
/// notes, and the AppleKit core tier only proves the precedence chain, not that THIS domain
/// opted into it. Review of the flip found the whole change was pinned by no test in either
/// tier — flipping `defaultDryRun` back to `true` left every suite green. This is that pin.
///
/// These read the real process environment and assume `APPLE_TEST_MODE` / `APPLE_DRY_RUN` are
/// unset (asserted below, so a polluted env fails legibly). The env-SET branches belong to the
/// AppleKit core tier, which owns the `envVar:` seams — mutating process env here would race the
/// parallel suites, which is exactly the 6-in-12 flake the Contacts flip had to fix.
@Suite("Notes write-model v2 posture")
struct NotesWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }
    /// Pinned, not read from the env: `TestMode.sandboxPrefix` is backed by APPLE_TEST_SANDBOX,
    /// which MailKitTests setenv()s in parallel inside this same process.
    let P = TestMode.canonicalSandboxPrefix

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
        #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
    }

    @Test("DEFAULT PIN: a flagless notes write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        let gate = try resolveNotesWrite(opts([]), defaultDryRun: false)
        #expect(gate.willExecute == true)
        #expect(gate.sandboxActive == false)
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        #expect(try resolveNotesWrite(opts(["--dry-run"]), defaultDryRun: false).willExecute == false)
        #expect(try resolveNotesWrite(opts(["--execute"]), defaultDryRun: false).willExecute == true)
        #expect(try resolveNotesWrite(opts(["--dry-run", "--execute"]), defaultDryRun: false).willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        let gate = try resolveNotesWrite(opts(["--test-mode"]), defaultDryRun: false)
        #expect(gate.sandboxActive == true)
        #expect(gate.willExecute == true)
    }

    @Test("LIFT PIN: guardLiveWrite confines ONLY inside the sandbox")
    func guardIsSandboxOnly() throws {
        // Unsandboxed, an unlabeled target is allowed — that IS the v2 flip (the oracle writes
        // whatever it is handed). A throw here means the gate was re-tightened.
        try guardLiveWrite(labeledName: "Zz A Real Note", sandboxActive: false, prefix: P)
        // Sandboxed, the same name is refused...
        #expect(throws: AppleError.self) {
            try guardLiveWrite(labeledName: "Zz A Real Note", sandboxActive: true, prefix: P)
        }
        // ...and a labeled one passes.
        try guardLiveWrite(labeledName: P + " note", sandboxActive: true, prefix: P)
        // A nil name is a no-op in both modes (v1 used it to assert test mode; v2 does not).
        try guardLiveWrite(labeledName: nil, sandboxActive: true, prefix: P)
    }

    /// Q14: the Notes sandbox refusal must stamp `error.sandbox` like the other five domains, so an
    /// agent can machine-distinguish it from an always-on validation error. Pins the flag directly
    /// (the write-model posture test above only checks that a throw happens); revert-red on the
    /// `sandbox: true` arg at `NotesCommand.guardLiveWrite`.
    @Test("guardLiveWrite sandbox refusal carries error.sandbox = true")
    func guardMarksSandbox() {
        let err = #expect(throws: AppleError.self) {
            try guardLiveWrite(labeledName: "Zz A Real Note", sandboxActive: true, prefix: P)
        }
        #expect(err?.sandbox == true)
        // The unsandboxed no-op path never throws, so there is no error to (wrongly) mark there.
    }

    @Test("--title addressing is checked from argv; --id addressing defers to the execute path")
    func selectorGuardSplit() throws {
        // A --title write is fully argv-checkable, so it refuses in the sandbox with nothing
        // left to disclose — and must NOT claim it skipped a check.
        #expect(throws: AppleError.self) {
            _ = try applyArgvSelectorGuard(.title("Zz A Real Note"), sandboxActive: true, prefix: P)
        }
        #expect(try applyArgvSelectorGuard(.title(P + " n"), sandboxActive: true, prefix: P) == false)
        // --id addressing genuinely cannot be checked without Notes.app, so the preview says so.
        #expect(try applyArgvSelectorGuard(.id("x-coredata://A/ICNote/p1"), sandboxActive: true) == true)
        // ...but only when the sandbox is engaged; otherwise there is no check to miss.
        #expect(try applyArgvSelectorGuard(.id("x-coredata://A/ICNote/p1"), sandboxActive: false) == false)
    }
}
