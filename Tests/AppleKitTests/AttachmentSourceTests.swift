import Testing
import Foundation
import TestSupport
@testable import AppleKit

/// The shared outbound-attachment guard — the one both `mail send --attach` and
/// `messages send --file` go through. Mail's own suite (`ComposeAttachmentTests`) pins the
/// behaviour it inherited; these are the cases the promotion into `AppleKit` was asked to prove,
/// driven directly against the shared entry point.
///
/// Every path here is synthetic: a scratch directory, or a fake `$HOME` built inside one. Nothing
/// reads or writes the operator's real `~/.ssh`, and no assertion depends on their machine.
@Suite("Shared outbound-attachment guard")
struct AttachmentSourceTests {
    private let scratch = ScratchDirs("attachment-source")

    // MARK: sensitive-directory containment

    /// `sensitiveWriteDir` is the blocklist the resolver consults, and it is pure — so the
    /// containment rule can be pinned against a synthetic `$HOME` with no real credential
    /// directory involved. The three shapes below are exactly what the resolver asks it:
    /// a file inside a credential directory, the directory itself, and a lookalike that must NOT
    /// be blocked.
    @Test func theBlocklistCoversEveryCredentialDirectoryTheResolverConsults() {
        let home = "/Users/apple-cli-test-user"
        for dir in [".ssh", ".gnupg", ".config", ".aws", ".claude",
                    "Library/Keychains", "Library/LaunchAgents", "Library/LaunchDaemons"] {
            #expect(sensitiveWriteDir("\(home)/\(dir)/secret", home: home) == "\(home)/\(dir)")
            #expect(sensitiveWriteDir("\(home)/\(dir)", home: home) == "\(home)/\(dir)")
        }
        #expect(sensitiveWriteDir("\(home)/Documents/report.pdf", home: home) == nil)
        #expect(sensitiveWriteDir("\(home)/.sshfoo/x", home: home) == nil)
    }

    /// A DIRECT path into a credential directory is refused as a `safety_violation` (77), not as
    /// a plain validation error: it is a deliberate policy refusal, and under write-model v2 —
    /// where an unsandboxed send reaches any recipient — this blocklist IS the containment for
    /// attachment content.
    @Test func refusesAFileInsideASensitiveDirectory() throws {
        let (home, real) = try fakeHome()
        let secret = home.appendingPathComponent(".ssh/id_ed25519")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"),
                                                withIntermediateDirectories: true)
        try "synthetic-key-material".write(to: secret, atomically: true, encoding: .utf8)

        let error = refusal(for: secret.path, home: real)
        #expect(error?.type == AppleErrorType.safetyViolation)
        #expect(error?.exitCode == AppleExit.permissionDenied)
        #expect(error?.message.contains("sensitive directory") == true)
    }

    /// THE BYPASS THE ORDERING EXISTS TO CLOSE: an ordinary-looking path whose PARENT is a symlink
    /// into a credential directory. Checking the literal alone accepts it; resolving symlinks
    /// first is what catches it, which is why the resolver resolves before it checks.
    @Test func refusesAPathWhoseParentSymlinksIntoASensitiveDirectory() throws {
        let (home, real) = try fakeHome()
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "synthetic-key-material".write(to: ssh.appendingPathComponent("id_ed25519"),
                                           atomically: true, encoding: .utf8)
        // ~/Documents/keys -> ~/.ssh
        let documents = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let link = documents.appendingPathComponent("keys")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ssh)

        let innocent = link.appendingPathComponent("id_ed25519").path
        // The literal spelling is not under a blocked directory at all…
        #expect(sensitiveWriteDir(innocent, home: real) == nil)
        // …but the resolver refuses it, because it checks the resolved path.
        let error = refusal(for: innocent, home: real)
        #expect(error?.type == AppleErrorType.safetyViolation)
    }

    /// THE MIRROR BYPASS: the credential directory is ITSELF a symlink (a stow-managed
    /// `~/.ssh` -> `~/dotfiles/ssh`). Now the RESOLVED path is innocent and the literal is the
    /// guilty one, so checking only the resolved path would accept it. The resolver checks both.
    @Test func refusesWhenTheSensitiveDirectoryIsItselfASymlink() throws {
        let (home, real) = try fakeHome()
        let store = home.appendingPathComponent("dotfiles/ssh")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try "synthetic-key-material".write(to: store.appendingPathComponent("id_ed25519"),
                                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".ssh"),
                                                   withDestinationURL: store)

        let viaLink = home.appendingPathComponent(".ssh/id_ed25519").path
        // The resolved path is an ordinary dotfiles location…
        #expect(sensitiveWriteDir(URL(fileURLWithPath: viaLink).resolvingSymlinksInPath().path,
                                  home: real) == nil)
        // …and the literal spelling is what catches it.
        #expect(sensitiveWriteDir(viaLink, home: real) != nil)
        #expect(refusal(for: viaLink, home: real)?.type == AppleErrorType.safetyViolation)
    }

    // MARK: symlinks, verbatim spellings, and the returned path

    /// The resolver RESOLVES a final-component symlink and returns the real path. Before the
    /// promotion the Messages copy asked `URL.isRegularFile` about the LINK, which answers false,
    /// so a symlink to an ordinary file was refused as "not a regular file" while four documents
    /// promised it was sent.
    @Test func resolvesAFinalComponentSymlinkToItsTarget() throws {
        let dir = try scratch.directory()
        let target = dir.appendingPathComponent("apple-cli-test-target.txt")
        try "synthetic".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("apple-cli-test-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = try AttachmentSource.resolve(link.path)
        #expect(resolved == target.resolvingSymlinksInPath().path)
        #expect(try String(contentsOfFile: resolved, encoding: .utf8) == "synthetic")
    }

    /// NO TRIMMING. `report ` (one trailing space) is a legal macOS filename, so trimming would
    /// stat, resolve and send a neighbouring `report` instead — silently, with the caller told the
    /// path the CLI picked. The fixture PAIR is what proves it: both files exist, so a trimming
    /// implementation passes every existence check and simply sends the wrong bytes.
    @Test func aTrailingSpaceSelectsTheTrailingSpaceFile() throws {
        let dir = try scratch.directory()
        let plain = dir.path + "/apple-cli-test-report"
        let spaced = dir.path + "/apple-cli-test-report "
        try "plain".write(toFile: plain, atomically: true, encoding: .utf8)
        try "spaced".write(toFile: spaced, atomically: true, encoding: .utf8)

        let resolved = try AttachmentSource.resolve(spaced)
        #expect(resolved.hasSuffix("apple-cli-test-report "))
        #expect(try String(contentsOfFile: resolved, encoding: .utf8) == "spaced")
        #expect(try String(contentsOfFile: AttachmentSource.resolve(plain), encoding: .utf8) == "plain")
    }

    @Test func aLeadingSpaceIsPartOfTheFilename() throws {
        let dir = try scratch.directory()
        let spaced = dir.path + "/ apple-cli-test-leading"
        try "leading".write(toFile: spaced, atomically: true, encoding: .utf8)
        #expect(try AttachmentSource.resolve(spaced).hasSuffix("/ apple-cli-test-leading"))
        // Trimmed, this names nothing — a trimming implementation would refuse a real file.
        #expect(throws: AppleError.self) {
            _ = try AttachmentSource.resolve(dir.path + "/apple-cli-test-leading")
        }
    }

    /// `..` is resolved rather than handed to AppleScript verbatim.
    @Test func resolvesTraversal() throws {
        let dir = try scratch.directory()
        let file = dir.appendingPathComponent("apple-cli-test-note.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        #expect(try AttachmentSource.resolve(dir.path + "/sub/../apple-cli-test-note.txt")
            == AttachmentSource.resolve(file.path))
    }

    // MARK: the remaining refusal classes, with their exit codes

    @Test func refusesAMissingFileAndADirectoryAsNotFound() throws {
        let dir = try scratch.directory()
        for path in [dir.appendingPathComponent("no-such-file.txt").path, dir.path] {
            let error = refusal(for: path, home: nil)
            #expect(error?.type == AppleErrorType.notFound)
            #expect(error?.exitCode == AppleExit.notFound)
        }
    }

    @Test func refusesAnEmptyOrWhitespaceOnlyPath() {
        for path in ["", "   "] {
            #expect(throws: AppleError.self) { _ = try AttachmentSource.resolve(path) }
        }
    }

    /// Control characters are refused before anything is stat-ed. NUL would truncate the path
    /// between this check and the `osascript` argv that carries it; RS/US would split one vetted
    /// path into two on Mail's blob route.
    @Test func refusesControlCharactersInThePath() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-note.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        for scalar in ["\u{00}", "\n", "\r", "\t", "\u{1E}", "\u{1F}", "\u{7F}"] {
            let error = refusal(for: file.path + scalar + "/elsewhere", home: nil)
            #expect(error?.type == AppleErrorType.safetyViolation)
        }
    }

    /// Adopted from Mail rather than kept laxer on the second outbound surface: one policy for
    /// both. Matched on the filename suffix, so a file named literally `.command` is blocked too.
    @Test func refusesExecutableAndScriptExtensions() throws {
        let dir = try scratch.directory()
        for name in ["payload.sh", "payload.SH", "installer.app", "hook.command", ".command"] {
            let path = dir.appendingPathComponent(name).path
            try "synthetic".write(toFile: path, atomically: true, encoding: .utf8)
            let error = refusal(for: path, home: nil)
            #expect(error?.type == AppleErrorType.validation, "\(name) must be refused")
            #expect(error?.exitCode == AppleExit.usage)
        }
        // An ordinary document is not caught by the suffix match.
        let ok = dir.appendingPathComponent("report.pdf").path
        try "%PDF-1.4".write(toFile: ok, atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { _ = try AttachmentSource.resolve(ok) }
    }

    /// The size cap is stated as a constant and refused before the file reaches Mail or Messages,
    /// where an oversized attachment is an opaque hang rather than an error.
    @Test func refusesAFileOverTheSizeCap() throws {
        let path = try scratch.directory().appendingPathComponent("apple-cli-test-big.bin").path
        // Sparse: the file reports its full length without occupying it on disk.
        try Data().write(to: URL(fileURLWithPath: path))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(AttachmentSource.maxBytes + 1))
        try handle.close()

        let error = refusal(for: path, home: nil)
        #expect(error?.type == AppleErrorType.validation)
        #expect(error?.message.contains("25 MB") == true)
        // Exactly at the cap is fine — the refusal is for OVER, not for AT.
        let atCap = try scratch.directory().appendingPathComponent("apple-cli-test-cap.bin").path
        try Data().write(to: URL(fileURLWithPath: atCap))
        let capHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: atCap))
        try capHandle.truncate(atOffset: UInt64(AttachmentSource.maxBytes))
        try capHandle.close()
        #expect(throws: Never.self) { _ = try AttachmentSource.resolve(atCap) }
    }

    // MARK: helpers

    /// Run the resolver and return the `AppleError` it threw, or nil if it did not throw.
    ///
    /// `home` is passed straight to the resolver's seam, so a SYNTHETIC credential directory is
    /// what the blocklist measures against. Nothing in the process environment is touched — the
    /// operator's real `~/.ssh` is never read, and a parallel suite's view of `HOME` is unchanged.
    private func refusal(for path: String, home: String?) -> AppleError? {
        do {
            _ = home == nil
                ? try AttachmentSource.resolve(path)
                : try AttachmentSource.resolve(path, home: home!)
            Issue.record("expected a refusal for this path")
            return nil
        } catch let error as AppleError {
            return error
        } catch {
            Issue.record("expected an AppleError, got \(type(of: error))")
            return nil
        }
    }

    /// A synthetic `$HOME` inside the scratch directory. Returns the URL to build fixtures under
    /// and the spelling the blocklist is measured against; they are the same string, but naming
    /// both keeps the call sites readable about which one each assertion is using.
    private func fakeHome() throws -> (URL, String) {
        let home = try scratch.directory().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, home.path)
    }
}
