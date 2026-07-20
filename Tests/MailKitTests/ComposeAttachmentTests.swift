import Testing
import Foundation
@testable import MailKit
import AppleKit

// Coverage for the compose-side attachment helpers that gate + load files for the live send
// paths (`mail send`/`reply` with --attach and the HTML/.eml route). These touch the filesystem
// (existence / regular-file checks + reads) but not Mail, so they run anywhere without TCC.
@Suite("Compose attachment helpers")
struct ComposeAttachmentTests {

    private func tempFile(_ name: String, _ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
