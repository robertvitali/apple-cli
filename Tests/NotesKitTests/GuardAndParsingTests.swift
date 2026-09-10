import Testing
import Foundation
import TestSupport
@testable import NotesKit
@testable import AppleKit

@Suite("AttachmentFS — path-traversal guard")
struct AttachmentFSTests {
    private let scratch = ScratchDirs("attachmentfs")

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

    // --- existence-independent alias normalization ---------------------------------------------
    // `NSString.standardizingPath` strips a leading `/private` ONLY when the stripped path exists,
    // so an EXISTING `/private/var/...` (or `/private/tmp/...`) path compared in the short form
    // while an ABSENT leaf under the same directory kept the long form and fell outside every root
    // — a valid `save-attachment --dry-run` destination was refused (exit 64) purely because the
    // file did not exist yet. The lexical guard must compare both sides in one form regardless of
    // existence; symlink resolution stays with `assertResolvedParentContained`.

    @Test("an absent leaf under a /private alias is accepted exactly like an existing one")
    func absentLeafUnderPrivateAliasMatchesExisting() throws {
        // ScratchDirs vends under $TMPDIR (`/var/folders/...`), which is itself the `/private/var`
        // alias — the same mechanism as `/private/tmp`, with no fixed-path dependence.
        // $TMPDIR may already be spelled in the long form (e.g. `/private/tmp/...`), so derive
        // the pair from whichever spelling ScratchDirs vended rather than blindly prepending.
        let dir = try scratch.directory().path
        let (short, long) = dir.hasPrefix("/private/")
            ? (String(dir.dropFirst("/private".count)), dir)
            : (dir, "/private" + dir)
        let absent = long + "/absent-\(UUID().uuidString).bin"   // absent leaf, long spelling
        // Existing directory in the long spelling against the short-spelled root: accepted before
        // the fix too (standardizingPath stripped /private because the target existed).
        #expect(throws: Never.self) { try AttachmentFS.assertSafeSavePath(long, roots: [short]) }
        // Absent leaf under the SAME directory: must be accepted just the same.
        #expect(throws: Never.self) { try AttachmentFS.assertSafeSavePath(absent, roots: [short]) }
    }

    @Test("an absent /private/tmp destination is inside a /tmp root")
    func absentPrivateTmpLeafInsideTmpRoot() {
        let absent = "/private/tmp/apple-cli-test-\(UUID().uuidString)/absent.bin"
        #expect(throws: Never.self) { try AttachmentFS.assertSafeSavePath(absent, roots: ["/tmp"]) }
    }

    @Test("absent /private/tmp and /private/var/folders destinations pass the DEFAULT roots")
    func absentPrivateLeavesPassDefaultRoots() {
        // Production calls with `roots: nil` → allowedSaveRoots(); the bug was an interaction with
        // that exact list, so it must be pinned at the real call shape, not only via injection.
        let id = UUID().uuidString
        #expect(throws: Never.self) {
            try AttachmentFS.assertSafeSavePath("/private/tmp/apple-cli-test-\(id)/absent.bin")
        }
        #expect(throws: Never.self) {
            try AttachmentFS.assertSafeSavePath("/private/var/folders/apple-cli-test-\(id)/absent.bin")
        }
    }

    @Test("both alias spellings of an absent path canonicalize to the same accepted string")
    func aliasSpellingsCanonicalizeIdentically() throws {
        let leaf = "apple-cli-test-\(UUID().uuidString)/absent.bin"
        let long = try AttachmentFS.assertSafeSavePath("/private/tmp/" + leaf, roots: ["/tmp"])
        let short = try AttachmentFS.assertSafeSavePath("/tmp/" + leaf, roots: ["/tmp"])
        #expect(long == short)
        #expect(long == "/tmp/" + leaf)
    }

    @Test("a trailing slash on an injected root does not change containment")
    func trailingSlashRootIsNormalized() {
        let absent = "/private/tmp/apple-cli-test-\(UUID().uuidString)/absent.bin"
        #expect(throws: Never.self) { try AttachmentFS.assertSafeSavePath(absent, roots: ["/tmp/"]) }
    }

    @Test("a tilde destination still expands to the home directory (keeps D12's `~/.ssh` parity)")
    func tildeDestinationExpandsToHome() throws {
        // `NSString.isAbsolutePath` accepts `~…`, and the old normalizer expanded it; the lexical
        // normalizer must keep doing so or every `~/…` destination silently becomes a refusal.
        let leaf = "apple-cli-test-\(UUID().uuidString)/x.bin"
        let viaTilde = try AttachmentFS.assertSafeSavePath("~/" + leaf)
        #expect(viaTilde == AttachmentFS.resolvedPath(NSHomeDirectory()) + "/" + leaf)
    }

    @Test("the alias fold applies only at a path-component boundary (`/private/tmpX` is not `/tmpX`)")
    func aliasFoldRequiresComponentBoundary() {
        // Pins the fold's own boundary check, independent of the root-prefix check: a refactor to
        // `hasPrefix(alias)` would fold `/private/tmpX` → `/tmpX` with every other test still green.
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/private/tmpX/apple-cli-test/a.bin", roots: ["/tmp"])
        }
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/private/varX/folders/apple-cli-test/a.bin", roots: ["/var/folders"])
        }
    }

    @Test("a `/` followed by a combining mark is still a separator, so `..` cannot hide behind it")
    func combiningMarkAfterSlashDoesNotHideTraversal() {
        // `/tmp/../<U+0301>/out.bin`: at the Character level `/` + U+0301 is ONE grapheme that is
        // not equal to "/", so a Character-level split would keep `..` inside a single component
        // and the path would read as still under /tmp. The kernel splits on the byte, and the real
        // target is `/<U+0301>/out.bin` — outside every root. Must be refused.
        let escape = "/tmp/../\u{0301}/out.bin"
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath(escape, roots: ["/tmp"])
        }
        #expect(AttachmentFS.resolvedPath(escape) == "/\u{0301}/out.bin")
    }

    @Test("an unknown `~user` spelling is refused as not-absolute, never anchored at `/`")
    func unknownTildeUserIsNotAbsolute() {
        // `expandingTildeInPath` returns an unknown `~user/…` unchanged; `isAbsolutePath` admits it.
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("~apple-cli-test-nosuchuser/x.bin")
        }
    }

    @Test("a case-variant /private alias spelling is not folded and stays fail-closed")
    func caseVariantAliasIsNotFolded() {
        // Exact-case fold on purpose (as before): on a case-insensitive volume this names the same
        // directory, but refusing it is the safe direction and matches the old behavior.
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/PRIVATE/TMP/apple-cli-test/x.bin", roots: ["/tmp"])
        }
    }

    @Test("`..` traversal through a /private alias still escapes and is rejected")
    func aliasTraversalStillRejected() {
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/private/tmp/../etc/passwd", roots: ["/tmp"])
        }
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/tmp/x/../../etc/passwd", roots: ["/tmp"])
        }
    }

    @Test("a root is a prefix only at a path-component boundary")
    func rootPrefixRequiresComponentBoundary() {
        let root = "/apple-cli-test/root"
        #expect(throws: Never.self) { try AttachmentFS.assertSafeSavePath(root + "/sub/file.bin", roots: [root]) }
        #expect(throws: AttachmentFS.FSError.self) {
            try AttachmentFS.assertSafeSavePath("/apple-cli-test/rootX/file.bin", roots: [root])
        }
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
/// `resolveNotesWrite` reads `APPLE_TEST_MODE` / `APPLE_DRY_RUN` from the PROCESS environment when
/// no seam overrides them, so every pin below runs inside `pinnedEnv` — a window holding the whole
/// write-posture set absent. Previously these read the ambient environment with no window at all
/// and merely ASSERTED it was clean, which left two ways to get a wrong verdict: an operator with
/// `APPLE_DRY_RUN=1` exported turned the default-execute pin red for the wrong reason, and a
/// concurrent suite's open `setenv` window (swift-testing runs these suites in parallel over one
/// process environment) could flip a value mid-assertion, where the clean-env test might not even
/// be the one that observed it. The env-SET branches still belong to the AppleKit core tier, which
/// owns the `envVar:` seams; this window is about making the UNSET branch deterministic here.
@Suite("Notes write-model v2 posture")
struct NotesWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }
    /// Pinned, not read from the env: `TestMode.sandboxPrefix` is backed by APPLE_TEST_SANDBOX,
    /// which MailKitTests setenv()s in parallel inside this same process.
    let P = TestMode.canonicalSandboxPrefix

    /// The whole write-posture set pinned absent — `TestEnvironment.writeModeVariables`, named
    /// once in TestSupport rather than re-spelled here (a hand-rolled sandbox-trio-plus-
    /// `APPLE_DRY_RUN` pin would under-pin the day a fifth variable joins the shared list). The
    /// lock is recursive and process-wide, so the window serializes against every other suite's.
    func pinnedEnv<T>(_ body: () throws -> T) rethrows -> T {
        try TestEnvironment.withoutWriteModeOverrides(body)
    }

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        // Same assertion, now made INSIDE the window the other pins run in: it checks that the
        // window actually delivers an unset pair, rather than hoping the ambient process
        // environment happened to have one.
        pinnedEnv {
            let env = ProcessInfo.processInfo.environment
            #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
            #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
        }
    }

    @Test("DEFAULT PIN: a flagless notes write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        try pinnedEnv {
            let gate = try resolveNotesWrite(opts([]), defaultDryRun: false)
            #expect(gate.willExecute == true)
            #expect(gate.sandboxActive == false)
        }
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        try pinnedEnv {
            let preview = try resolveNotesWrite(opts(["--dry-run"]), defaultDryRun: false)
            let execute = try resolveNotesWrite(opts(["--execute"]), defaultDryRun: false)
            let both = try resolveNotesWrite(opts(["--dry-run", "--execute"]), defaultDryRun: false)
            #expect(preview.willExecute == false)
            #expect(execute.willExecute == true)
            #expect(both.willExecute == false)
        }
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        try pinnedEnv {
            let gate = try resolveNotesWrite(opts(["--test-mode"]), defaultDryRun: false)
            #expect(gate.sandboxActive == true)
            #expect(gate.willExecute == true)
        }
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

    @Test("only --id defers the target check; a typed --title settles it from argv")
    func selectorGuardSplit() throws {
        // A --title write IS argv-checkable, so an obviously-unlabeled name refuses immediately on
        // both paths…
        #expect(throws: AppleError.self) {
            _ = try applyArgvSelectorGuard(.title("Zz A Real Note"), sandboxActive: true, prefix: P)
        }
        // …and a LABELED one has had the gate RUN, not skipped, so the preview discloses nothing.
        // Claiming a skipped check on the one selector that settles it from argv would be a false
        // excuse (pinned end-to-end in `bats/hosted/notes.bats`). The execute path's re-check of the
        // FETCHED title — AppleScript's by-name lookup is case-insensitive, so a labeled spelling
        // can resolve a real note whose actual title fails the case-sensitive check — is a separate,
        // unconditional guard and does not depend on this return value.
        #expect(try applyArgvSelectorGuard(.title(P + " n"), sandboxActive: true, prefix: P) == false)
        // Outside the sandbox there is no check to miss either.
        #expect(try applyArgvSelectorGuard(.title(P + " n"), sandboxActive: false, prefix: P) == false)
        // --id addressing cannot be checked at all without Notes.app, so the preview says so.
        #expect(try applyArgvSelectorGuard(.id("x-coredata://A/ICNote/p1"), sandboxActive: true) == true)
        // ...but only when the sandbox is engaged; otherwise there is no check to miss.
        #expect(try applyArgvSelectorGuard(.id("x-coredata://A/ICNote/p1"), sandboxActive: false) == false)
    }
}
