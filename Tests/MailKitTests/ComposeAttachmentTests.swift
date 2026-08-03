import Testing
import Foundation
import TestSupport
@testable import MailKit
import AppleKit

// Coverage for the compose-side attachment helpers that gate + load files for the live send
// paths (`mail send`/`reply` with --attach and the HTML/.eml route). These touch the filesystem
// (existence / regular-file checks + reads) but not Mail, so they run anywhere without TCC.
@Suite("Compose attachment helpers")
struct ComposeAttachmentTests {

    /// Scratch that is actually reclaimed — this leaked 6 directories per `swift test`.
    private let scratch = ScratchDirs("attach")

    private func tempFile(_ name: String, _ contents: String) throws -> String {
        let url = try scratch.directory().appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("resolveAttachmentPath returns the resolved path for an existing regular file")
    func resolvesExistingFile() throws {
        let path = try tempFile("note.txt", "hello")
        // resolveAttachmentPath resolves symlinks; compare against the resolved form (a no-op on
        // /private-backed temp dirs, but consistent with the sibling tests + correct in general).
        #expect(try resolveAttachmentPath(path) == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    @Test("resolveAttachmentPath rejects a missing file as not_found (exit 65)")
    func rejectsMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-test-\(UUID().uuidString)/nope.txt").path
        let err = #expect(throws: AppleError.self) { _ = try resolveAttachmentPath(missing) }
        #expect(err?.exitCode == 65)
    }

    @Test("resolveAttachmentPath rejects a directory (not a regular file)")
    func rejectsDirectory() throws {
        let dir = try scratch.directory()
        let err = #expect(throws: AppleError.self) { _ = try resolveAttachmentPath(dir.path) }
        #expect(err?.exitCode == 65)
    }

    @Test("resolveAttachmentPath expands a leading tilde")
    func expandsTilde() throws {
        // Create a uniquely-named file directly under $HOME, resolve it via ~, then clean up.
        let name = "apple-cli-test-\(UUID().uuidString).txt"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        // resolveAttachmentPath resolves symlinks (anti-bypass for the sensitive-dir check), so
        // compare against the symlink-resolved home path.
        #expect(try resolveAttachmentPath("~/\(name)") == url.resolvingSymlinksInPath().path)
    }

    @Test("attachmentsFromPaths reads bytes + infers filename/MIME for the .eml route")
    func loadsAttachmentParts() throws {
        let path = try tempFile("report.pdf", "%PDF-1.4 stub")
        let parts = try attachmentsFromPaths([path])
        #expect(parts.count == 1)
        #expect(parts[0].filename == "report.pdf")
        #expect(parts[0].mimeType == "application/pdf")
        #expect(parts[0].data == Data("%PDF-1.4 stub".utf8))
    }

    @Test("resolveAttachmentPath blocks a dangerous executable extension (.sh) — validation, exit 64")
    func blocksDangerousExtension() throws {
        let path = try tempFile("payload.sh", "#!/bin/sh\necho hi")
        let err = #expect(throws: AppleError.self) { _ = try resolveAttachmentPath(path) }
        #expect(err?.exitCode == 64)
    }

    @Test("resolveAttachmentPath blocks a file named literally .command (leading-dot, no basename)")
    func blocksLeadingDotExecutable() throws {
        // NSString.pathExtension is "" for a leading-dot-only name; the endswith match still blocks
        // it (matches s-morgan validate_attachment_type's filename endswith).
        let path = try tempFile(".command", "#!/bin/sh")
        let err = #expect(throws: AppleError.self) { _ = try resolveAttachmentPath(path) }
        #expect(err?.exitCode == 64)
    }

    @Test("resolveAttachmentPath allows an ordinary extension (.pdf)")
    func allowsNormalExtension() throws {
        let path = try tempFile("report.pdf", "%PDF-1.4")
        #expect(try resolveAttachmentPath(path) == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    @Test("sensitiveAttachmentDir flags credential dirs but not ordinary paths")
    func sensitiveDirDetection() {
        let home = "/Users/tester"
        #expect(sensitiveAttachmentDir("\(home)/.ssh/id_rsa", home: home) == "\(home)/.ssh")
        #expect(sensitiveAttachmentDir("\(home)/Library/Keychains/login.keychain-db", home: home) == "\(home)/Library/Keychains")
        #expect(sensitiveAttachmentDir("\(home)/.aws", home: home) == "\(home)/.aws")       // exact dir match
        #expect(sensitiveAttachmentDir("\(home)/Documents/report.pdf", home: home) == nil)
        #expect(sensitiveAttachmentDir("\(home)/.sshfoo/x", home: home) == nil)             // prefix, not a path boundary
    }
}

/// Export writes MESSAGE BODIES to disk, so its destination gets the same guard the attachment
/// reader has — oracle B validates `save_dir` with realpath + home-confinement + a
/// sensitive-directory blocklist (`tools/analytics.py`). The CLI previously accepted any path.
@Suite("Export directory confinement")
struct ExportDirectoryTests {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path }

    @Test func acceptsAPlainDirectoryUnderHome() throws {
        let url = try resolveExportDirectory("~/Desktop")
        #expect(url.path.hasPrefix(home))
    }

    @Test func refusesAnythingOutsideHome() {
        for p in ["/tmp/exports", "/", "/var/root", "/Users/someone-else/Desktop"] {
            #expect(throws: Error.self, "expected \(p) to be refused") {
                _ = try resolveExportDirectory(p)
            }
        }
    }

    /// Every directory on oracle B's list, plus the extras this CLI already blocks for attachments.
    @Test func refusesTheSensitiveDirectories() {
        for p in ["~/.ssh", "~/.gnupg", "~/.config", "~/.aws", "~/.claude",
                  "~/Library/Keychains", "~/Library/LaunchAgents", "~/Library/LaunchDaemons"] {
            #expect(throws: Error.self, "expected \(p) to be refused") {
                _ = try resolveExportDirectory(p)
            }
        }
        // A nested path INSIDE a blocked directory is refused too, not just the directory itself.
        #expect(throws: Error.self) { _ = try resolveExportDirectory("~/.ssh/backup/mail") }
    }

    /// `..` traversal must be resolved BEFORE the home check, else it escapes.
    @Test func resolvesTraversalBeforeChecking() {
        #expect(throws: Error.self) { _ = try resolveExportDirectory("~/Desktop/../../../tmp") }
    }
}

/// The guard `export` and `attachments save` now share. `attachments save` previously applied
/// NEITHER check and documented its destination as "TRUSTED", so
/// `--out ~/.ssh/authorized_keys --execute` would have overwritten an SSH key with attachment
/// bytes — a divergence in the less-safe direction from both oracles.
@Suite("Shared write-destination confinement")
struct WriteDestinationConfinementTests {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path }

    @Test func acceptsOrdinaryPathsUnderHome() throws {
        #expect(try confineWriteDestination("~/Desktop", action: "save attachments into").path.hasPrefix(home))
        // $HOME itself is allowed, matching the oracle (manage.py:201).
        #expect(try confineWriteDestination("~", action: "save attachments into").path == home)
    }

    @Test func refusesOutsideHome() {
        for p in ["/tmp/x", "/etc", "/private/etc", "/", "/Users/someone-else/Desktop"] {
            #expect(throws: Error.self, "expected \(p) to be refused") {
                _ = try confineWriteDestination(p, action: "save attachments into")
            }
        }
    }

    @Test func refusesSensitiveDirectoriesAndTheirContents() {
        for p in ["~/.ssh", "~/.gnupg", "~/.config", "~/.aws", "~/.claude",
                  "~/Library/Keychains", "~/Library/LaunchAgents", "~/Library/LaunchDaemons",
                  "~/.ssh/authorized_keys", "~/.aws/credentials"] {
            #expect(throws: Error.self, "expected \(p) to be refused") {
                _ = try confineWriteDestination(p, action: "save attachments into")
            }
        }
    }

    @Test func resolvesTraversalBeforeChecking() {
        #expect(throws: Error.self) {
            _ = try confineWriteDestination("~/Desktop/../../../tmp", action: "save attachments into")
        }
    }

    /// A near-miss must NOT be refused — the blocklist matches on a path boundary, not a prefix.
    @Test func doesNotOverBlockLookalikeNames() throws {
        #expect(try confineWriteDestination("~/.sshfoo", action: "x").path.hasPrefix(home))
        #expect(try confineWriteDestination("~/Documents/aws", action: "x").path.hasPrefix(home))
    }

    /// The refusal message must name the action, so the same guard reads correctly on every
    /// surface that calls it.
    @Test func refusalNamesTheAction() {
        do {
            _ = try confineWriteDestination("/etc", action: "export messages into")
            Issue.record("expected a refusal")
        } catch {
            #expect("\(error)".contains("export messages into"))
        }
    }

    // MARK: bypasses found by review — each of these was live-confirmed ACCEPTED before the fix

    /// The default macOS volume is case-insensitive APFS, and `resolvingSymlinksInPath()` only
    /// canonicalizes case for components that ALREADY EXIST — so a case-sensitive comparison fails
    /// OPEN for a file that does not exist yet. That is precisely the "plant a new
    /// ~/.ssh/authorized_keys" case: `--out ~/.SSH/authorized_keys` returned ok:true while the
    /// lowercase spelling was refused.
    @Test func refusesCaseVariantsOfSensitiveDirectories() {
        for p in ["~/.SSH/authorized_keys", "~/.SsH/newkeyfile", "~/.SSH", "~/.AWS/credentials",
                  "~/Library/KEYCHAINS/login.keychain-db", "~/.Config/x"] {
            #expect(throws: Error.self, "expected \(p) to be refused") {
                _ = try confineWriteDestination(p, action: "save attachments into")
            }
        }
    }

    /// The confined path is later serialized into an ASCII-delimited blob for AppleScript (RS
    /// 0x1E between records, US 0x1F between fields). A path carrying those bytes passes every
    /// path check as ONE string and is re-parsed downstream as TWO records — the second targeting
    /// a destination that never passed confinement. Live-confirmed as ok:true before the fix.
    @Test func refusesControlCharactersInThePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forged = "\(home)/ok\u{1E}0\u{1F}\(home)/.ssh/authorized_keys"
        #expect(throws: Error.self, "RS/US forged record must be refused") {
            _ = try confineWriteDestination(forged, action: "save an attachment to")
        }
        for scalar in ["\u{00}", "\n", "\r", "\t", "\u{1E}", "\u{1F}", "\u{7F}"] {
            #expect(throws: Error.self, "control char must be refused") {
                _ = try confineWriteDestination("\(home)/ok\(scalar)evil", action: "x")
            }
        }
    }

    /// Oracle A's `save_attachments` has NO confinement, so /tmp and /Volumes/* are legitimate
    /// destinations; refusing them unconditionally would DROP that capability. The opt-out
    /// restores oracle-A reach — but the credential blocklist is ABSOLUTE and must survive it.
    @Test func allowOutsideHomeRelaxesOnlyTheHomeRule() throws {
        #expect(throws: Error.self) { _ = try confineWriteDestination("/tmp/x", action: "x") }
        #expect(try confineWriteDestination("/tmp/x", action: "x", allowOutsideHome: true).path.hasSuffix("/x"))
        // Blocklist still wins, opt-out or not.
        for p in ["~/.ssh", "~/.SSH/authorized_keys", "~/.aws/credentials"] {
            #expect(throws: Error.self, "blocklist must survive the opt-out: \(p)") {
                _ = try confineWriteDestination(p, action: "x", allowOutsideHome: true)
            }
        }
        // Control-character rejection also survives the opt-out.
        #expect(throws: Error.self) {
            _ = try confineWriteDestination("/tmp/a\u{1F}b", action: "x", allowOutsideHome: true)
        }
    }
}
