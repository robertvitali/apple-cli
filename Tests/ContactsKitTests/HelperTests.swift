import Testing
import Foundation
import TestSupport
@testable import ContactsKit
import AppleKit

// Tests for the pure command-support helpers extracted for testability: the search
// --deep union/dedup, the page-size cap, vCard dry-run validation, and input-size bounds.

private func summary(_ id: String, _ given: String = "") -> ContactSummary {
    ContactSummary(id: id, given_name: given, family_name: "", organization: "")
}

@Suite("effectiveLimit (min(limit, cap))")
struct EffectiveLimitTests {
    @Test("clamps to cap, passes through below cap") func clamp() {
        #expect(effectiveLimit(500, cap: 200) == 200)
        #expect(effectiveLimit(50, cap: 200) == 50)
        #expect(effectiveLimit(200, cap: 200) == 200)
        #expect(effectiveLimit(1, cap: 200) == 1)
    }
}

@Suite("unionSummariesByID (search --deep)")
struct UnionDedupTests {
    @Test("dedupes by id, preserves first-seen order") func dedupOrder() {
        let lists = [
            [summary("a", "Alice"), summary("b", "Bob")],
            [summary("b", "Bob2"), summary("c", "Cy")],   // b duplicate (first wins)
            [summary("a", "Alice2"), summary("d", "Dee")],
        ]
        let out = unionSummariesByID(lists, cap: 200)
        #expect(out.map(\.id) == ["a", "b", "c", "d"])
        #expect(out.first?.given_name == "Alice")  // first-seen 'a' kept, not "Alice2"
    }
    @Test("honors the cap") func cap() {
        let lists = [(0..<300).map { summary("id\($0)") }]
        let out = unionSummariesByID(lists, cap: 200)
        #expect(out.count == 200)
    }
    @Test("empty input → empty") func empty() {
        #expect(unionSummariesByID([], cap: 200).isEmpty)
        #expect(unionSummariesByID([[]], cap: 200).isEmpty)
    }
}

@Suite("vCard dry-run validation (ContactsStore.validateVCard)")
struct VCardValidateTests {
    @Test("valid 3.0 → parsed count") func valid() throws {
        let vcard = ["BEGIN:VCARD", "VERSION:3.0", "N:Doe;Jane;;;", "FN:Jane Doe", "END:VCARD", ""]
            .joined(separator: "\r\n")
        #expect(try ContactsStore.validateVCard(text: vcard) == 1)
    }
    @Test("malformed / empty → validation_error") func malformed() {
        for bad in ["not a vcard at all", "", "   "] {
            do {
                _ = try ContactsStore.validateVCard(text: bad)
                Issue.record("expected validation_error for \(bad.debugDescription)")
            } catch let e as AppleError {
                #expect(e.type == "validation_error")
            } catch {
                Issue.record("expected AppleError, got \(error)")
            }
        }
    }
}

@Suite("Input-size bounds")
struct InputBoundsTests {
    @Test("small input passes") func small() throws {
        try checkBoundedInput("small payload", "--json")
    }
    @Test("over-limit input rejected") func overLimit() {
        let big = String(repeating: "x", count: maxContactsInputBytes + 1)
        do {
            try checkBoundedInput(big, "--json")
            Issue.record("expected validation_error for oversized input")
        } catch let e as AppleError {
            #expect(e.type == "validation_error")
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }
}

@Suite("readBoundedFile under the shared tilde policy")
struct ReadBoundedFileTildeTests {
    private let scratch = ScratchDirs("contacts-bounded-file")

    /// Asserted as an exact refusal, not "does not read the other home", so the test fails on
    /// every macOS release, including those whose Foundation leaves the spelling cwd-relative.
    @Test("another user's ~user spelling, or a tilde with a combining mark, is refused before any read")
    func refusesForeignSpellings() {
        let other = NSUserName() == "root" ? "~daemon" : "~root"
        for raw in [other + "/.profile", "~no-such-user-apple-cli/x", "~\u{0301}/x"] {
            do {
                _ = try readBoundedFile(raw, "note")
                Issue.record("expected a refusal for \(raw)")
            } catch let error as AppleError {
                #expect(error.type == "validation_error")
                #expect(error.message == "cannot read the note file: " + TildeSpelling.refusalMessage(raw))
            } catch {
                Issue.record("expected AppleError, got \(error)")
            }
        }
    }

    /// The ceiling is measured on the path that is read. The trailing-slash spelling is the
    /// regression case: `attributesOfItem(atPath:)` finds nothing for `…/big.bin/` while the read
    /// resolves it, so measuring the raw spelling skipped the limit. `~/…` skipped it the same way,
    /// but a test cannot place a 25 MB file in the account's real home.
    @Test("the size ceiling is measured on the path that is read, including a trailing-slash spelling")
    func sizeCeilingIsMeasuredOnTheReadPath() throws {
        let dir = try scratch.directory()
        let small = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: small)
        #expect(try readBoundedFile(small.path, "note") == Data("hello".utf8))

        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(maxContactsInputBytes + 1))
        try handle.close()
        for spelling in [big.path, big.path + "/"] {
            do {
                _ = try readBoundedFile(spelling, "image")
                Issue.record("expected the size ceiling to refuse \(spelling)")
            } catch let error as AppleError {
                #expect(error.type == "validation_error")
                #expect(error.message == "image file exceeds the 25 MB limit (\(maxContactsInputBytes + 1) bytes)")
            }
        }
    }
}

@Suite("readBoundedFile input rules")
struct ReadBoundedFileInputRuleTests {
    private let scratch = ScratchDirs("contacts-file-rules")

    private func expectRefusal(_ raw: String, _ what: String = "note", home: String? = nil,
                               type: String, prefix: String, mentions: String? = nil,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            if let home { _ = try readBoundedFile(raw, what, home: home) }
            else { _ = try readBoundedFile(raw, what) }
            Issue.record("expected a refusal for \(raw)", sourceLocation: sourceLocation)
        } catch let error as AppleError {
            #expect(error.type == type, sourceLocation: sourceLocation)
            #expect(error.message.hasPrefix(prefix), "\(error.message)", sourceLocation: sourceLocation)
            if let mentions {
                #expect(error.message.contains(mentions), "\(error.message)", sourceLocation: sourceLocation)
            }
        } catch {
            Issue.record("expected AppleError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    private func sparseFile(_ url: URL, size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    private func link(_ at: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: at, withDestinationURL: target)
    }

    /// A pipe whose write end is closed after `bytes` are written, so a read sees end of file.
    private func filledPipe(_ bytes: [UInt8]) throws -> Int32 {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let written = bytes.withUnsafeBytes { write(ends[1], $0.baseAddress, bytes.count) }
        close(ends[1])
        try #require(written == bytes.count)
        return ends[0]
    }

    @Test("a symbolic link is measured and read as its target")
    func symbolicLinkIsMeasuredAsItsTarget() throws {
        let dir = try scratch.directory()
        let small = dir.appendingPathComponent("small.txt")
        try Data("hello".utf8).write(to: small)
        try link(dir.appendingPathComponent("small-link"), to: small)
        #expect(try readBoundedFile(dir.appendingPathComponent("small-link").path, "note") == Data("hello".utf8))

        let big = dir.appendingPathComponent("big.bin")
        try sparseFile(big, size: maxContactsInputBytes + 1)
        try link(dir.appendingPathComponent("big-link"), to: big)
        expectRefusal(dir.appendingPathComponent("big-link").path, "image", type: AppleErrorType.validation,
                      prefix: "image file exceeds the 25 MB limit (\(maxContactsInputBytes + 1) bytes)")
    }

    /// `.timeLimit` cannot interrupt a blocked `open`, so a watchdog opens the pipe for writing
    /// after five seconds: that succeeds only while a reader is waiting in `open`, releases it, and
    /// is recorded, so a reader that would block forever fails the test instead of hanging it.
    @Test("a named pipe is refused at once, without waiting for a writer", .timeLimit(.minutes(1)))
    func namedPipeIsRefusedWithoutWaiting() throws {
        let fifo = try scratch.directory().appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let released = ReleaseFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { released.set(); close(writer) }
        }
        expectRefusal(fifo.path, type: AppleErrorType.validation,
                      prefix: "note file is a named pipe, not a regular file or a pipe given as /dev/stdin",
                      mentions: "--note")
        #expect(!released.isSet, "the reader waited in open() for a writer")
    }

    /// Only the exact spellings `/dev/stdin` and `/dev/fd/N` hand a descriptor over. A spelling that
    /// reads as `/dev/stdin` once its `..` components are removed as text, but resolves through a
    /// link to a named pipe elsewhere, is opened by path and refused like any named pipe.
    @Test("a spelling that only looks like /dev/stdin is not handed over", .timeLimit(.minutes(1)))
    func lookalikeStdinIsNotHandedOver() throws {
        let root = try scratch.directory()
        let base = try scratch.directory()
        let depth = base.path.split(separator: "/").count + 1
        var deep = root
        for level in 1...depth { deep = deep.appendingPathComponent("d\(level)", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dev"), withIntermediateDirectories: true)
        try #require(mkfifo(root.appendingPathComponent("dev/stdin").path, 0o600) == 0)
        try link(base.appendingPathComponent("lnk"), to: deep)
        let spelling = base.path + "/lnk" + String(repeating: "/..", count: depth) + "/dev/stdin"
        expectRefusal(spelling, type: AppleErrorType.validation, prefix: "note file is a named pipe")
    }

    @Test("a directory and a character device are refused, naming the inline flag")
    func otherFileKindsAreRefused() throws {
        expectRefusal(try scratch.directory().path, "image", type: AppleErrorType.validation,
                      prefix: "image file is a directory", mentions: "--base64 (the bytes base64-encoded)")
        expectRefusal("/dev/null", "vcard", type: AppleErrorType.validation,
                      prefix: "vcard file is a character device", mentions: "--vcard")
    }

    /// `/dev/stdin` is `/dev/fd/0`, so a `/dev/fd/N` spelling takes the same path through the
    /// reader without touching this process's own stdin, which swift-testing shares across suites.
    @Test("a pipe or a regular file handed over as /dev/fd/N, as /dev/stdin is, is read", .timeLimit(.minutes(1)))
    func descriptorSpellingsAreRead() throws {
        let piped = try filledPipe(Array("piped note".utf8))
        defer { close(piped) }
        #expect(try readBoundedFile("/dev/fd/\(piped)", "note") == Data("piped note".utf8))

        let file = try scratch.directory().appendingPathComponent("redirected.txt")
        try Data("from a redirect".utf8).write(to: file)
        let regular = open(file.path, O_RDONLY | O_CLOEXEC)
        try #require(regular >= 0)
        defer { close(regular) }
        #expect(try readBoundedFile("/dev/fd/\(regular)", "note") == Data("from a redirect".utf8))
    }

    /// Node's and Bun's spawn `input` hands the child a socket, not a pipe, as its stdin.
    @Test("a socket handed over as /dev/fd/N, as Node's and Bun's spawn input is, is read",
          .timeLimit(.minutes(1)))
    func handedOverSocketIsRead() throws {
        var ends: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        defer { close(ends[0]) }
        let bytes = Array("from a socket".utf8)
        let written = bytes.withUnsafeBytes { write(ends[1], $0.baseAddress, bytes.count) }
        close(ends[1])
        try #require(written == bytes.count)
        #expect(try readBoundedFile("/dev/fd/\(ends[0])", "note") == Data("from a socket".utf8))
    }

    /// The writer ignores SIGPIPE, so once the reader gives up and the read end is closed it stops
    /// with EPIPE instead of blocking on a full pipe.
    @Test("a pipe longer than the limit is refused after one byte past it", .timeLimit(.minutes(1)))
    func pipeOverTheLimitIsRefused() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let (reader, writer) = (ends[0], ends[1])
        try #require(fcntl(writer, F_SETNOSIGPIPE, 1) == 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let chunk = [UInt8](repeating: 0x62, count: 64 * 1024)
            var sent = 0
            while sent <= maxContactsInputBytes + chunk.count {
                let count = chunk.withUnsafeBytes { write(writer, $0.baseAddress, chunk.count) }
                if count <= 0 { break }
                sent += count
            }
            close(writer)
            done.signal()
        }
        expectRefusal("/dev/fd/\(reader)", type: AppleErrorType.validation,
                      prefix: "note file exceeds the 25 MB limit (more than \(maxContactsInputBytes) bytes were read)")
        close(reader)
        #expect(done.wait(timeout: .now() + 30) == .success)
    }

    @Test("a relative spelling is made absolute for the text match, keeping its .. components")
    func relativeSpellingKeepsItsComponents() {
        #expect(absoluteSpelling("jump/../../payload", in: "/h/.config") == "/h/.config/jump/../../payload")
        #expect(absoluteSpelling("/h/.config/x", in: "/elsewhere") == "/h/.config/x")
    }

    @Test("a character device handed over as stdin is refused as a terminal or other device")
    func handedOverDeviceIsRefused() throws {
        let device = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(device >= 0)
        defer { close(device) }
        expectRefusal("/dev/fd/\(device)", type: AppleErrorType.validation,
                      prefix: "note file is a terminal or other character device")
    }

    @Test("a control character anywhere in the spelling is a safety violation")
    func controlCharactersAreRefused() {
        for (raw, code) in [("notes\u{1B}.txt", "001B"), ("a\nb", "000A"), ("x\u{7F}", "007F")] {
            expectRefusal(raw, type: AppleErrorType.safetyViolation,
                          prefix: "cannot read the note file from a path containing a control character (U+\(code))")
        }
    }

    /// A directory the caller may search but not list still yields its files, as a plain open does.
    @Test("a file in a search-only directory is read")
    func searchOnlyDirectoryIsRead() throws {
        let dir = try scratch.directory().appendingPathComponent("search-only", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("listed nowhere".utf8).write(to: dir.appendingPathComponent("note.txt"))
        try #require(chmod(dir.path, 0o311) == 0)
        defer { _ = chmod(dir.path, 0o755) }
        #expect(try readBoundedFile(dir.appendingPathComponent("note.txt").path, "note") == Data("listed nowhere".utf8))
    }

    @Test("a missing file stays a validation error")
    func missingFileIsAValidationError() throws {
        let missing = try scratch.directory().appendingPathComponent("absent.txt")
        expectRefusal(missing.path, type: AppleErrorType.validation, prefix: "failed to read note file")
    }

    @Test("a file in a credential directory is refused however it is spelled or linked")
    func credentialDirectoriesAreRefused() throws {
        let home = try scratch.directory()
        let outside = try scratch.directory()
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_test")
        try Data("not a real key".utf8).write(to: key)
        let refused = "cannot read the note file from a sensitive directory"

        // Directly, with home spelled through a link, and through a link to the file.
        expectRefusal(key.path, home: home.path, type: AppleErrorType.safetyViolation, prefix: refused)
        let homeLink = outside.appendingPathComponent("home-link")
        try link(homeLink, to: home)
        expectRefusal(key.path, home: homeLink.path, type: AppleErrorType.safetyViolation, prefix: refused)
        try link(outside.appendingPathComponent("innocent.txt"), to: key)
        expectRefusal(outside.appendingPathComponent("innocent.txt").path, home: home.path,
                      type: AppleErrorType.safetyViolation, prefix: refused)

        // A credential directory that is itself a link, reached through a second link that never
        // names it: only the identity comparison sees it.
        let awsReal = outside.appendingPathComponent("aws-real", isDirectory: true)
        try FileManager.default.createDirectory(at: awsReal, withIntermediateDirectories: true)
        try Data("not real credentials".utf8).write(to: awsReal.appendingPathComponent("credentials"))
        try link(home.appendingPathComponent(".aws"), to: awsReal)
        try link(outside.appendingPathComponent("alias"), to: home.appendingPathComponent(".aws"))
        expectRefusal(outside.appendingPathComponent("alias/credentials").path, home: home.path,
                      type: AppleErrorType.safetyViolation, prefix: refused)

        // A file that is a link out of a credential directory is caught by the directory it was
        // found in, however that is spelled: plainly, with `.` and `..` components, through the
        // resolved home (`/private/var/…` for `/var/…`), or through a second link to the directory.
        let config = home.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let dotfile = outside.appendingPathComponent("tool.conf")
        try Data("token=placeholder".utf8).write(to: dotfile)
        try link(config.appendingPathComponent("tool/tool.conf"), to: dotfile)
        let resolvedHome = try #require(realpath(home.path, nil))
        defer { free(resolvedHome) }
        for spelling in [home.path + "/.config/tool/tool.conf", home.path + "/./.config/tool/tool.conf",
                         home.path + "/Documents/../.config/tool/tool.conf",
                         String(cString: resolvedHome) + "/.config/tool/tool.conf"] {
            expectRefusal(spelling, home: home.path, type: AppleErrorType.safetyViolation, prefix: refused)
        }
        try link(outside.appendingPathComponent("config-alias"), to: config)
        expectRefusal(outside.appendingPathComponent("config-alias/tool/tool.conf").path, home: home.path,
                      type: AppleErrorType.safetyViolation, prefix: refused)
        // Through a link to a subdirectory, no directory the spelling passes through is a credential
        // directory itself; only the ancestors of the directory the file was found in reach one.
        try link(outside.appendingPathComponent("tool-alias"), to: config.appendingPathComponent("tool"))
        expectRefusal(outside.appendingPathComponent("tool-alias/tool.conf").path, home: home.path,
                      type: AppleErrorType.safetyViolation, prefix: refused)

        // A path that enters a credential directory and leaves it through `..` after a link lands
        // elsewhere physically; it is refused because it passes through the directory, however the
        // way in is spelled.
        let deep = outside.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: outside.appendingPathComponent("payload"))
        try link(config.appendingPathComponent("jump"), to: deep)
        expectRefusal(home.path + "/.config/jump/../../payload", home: home.path,
                      type: AppleErrorType.safetyViolation, prefix: refused)
        for spelling in [String(cString: resolvedHome) + "/.config/jump/../../payload",
                         home.path + "/Documents/../.config/jump/../../payload"] {
            expectRefusal(spelling, home: homeLink.path, type: AppleErrorType.safetyViolation, prefix: refused)
        }

        let ordinary = home.appendingPathComponent("note.txt")
        try Data("fine".utf8).write(to: ordinary)
        #expect(try readBoundedFile(ordinary.path, "note", home: home.path) == Data("fine".utf8))
    }

    /// The documented boundary, pinned so a change to it is deliberate: the credential check reads
    /// paths, and a hard link made outside the directories carries no trace of its other name.
    @Test("a hard link to a credential file made outside the directories is read")
    func hardLinkIsTheDocumentedBoundary() throws {
        let home = try scratch.directory()
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_test")
        try Data("not a real key".utf8).write(to: key)
        let alias = try scratch.directory().appendingPathComponent("alias.txt")
        try #require(Darwin.link(key.path, alias.path) == 0)
        #expect(try readBoundedFile(alias.path, "note", home: home.path) == Data("not a real key".utf8))
    }

    @Test("the bounded read stops one byte past the limit")
    func boundedReadStopsOnePastTheLimit() throws {
        let over = try filledPipe([UInt8](repeating: 0x61, count: 20))
        defer { close(over) }
        #expect(try readAtMost(over, limit: 10) == nil)
        var rest = [UInt8](repeating: 0, count: 64)
        #expect(rest.withUnsafeMutableBytes { read(over, $0.baseAddress, 64) } == 9)

        let exact = try filledPipe([UInt8](repeating: 0x61, count: 10))
        defer { close(exact) }
        #expect(try readAtMost(exact, limit: 10) == Data(repeating: 0x61, count: 10))

        let empty = try filledPipe([])
        defer { close(empty) }
        #expect(try readAtMost(empty, limit: 0) == Data())
    }

    @Test("the bounded read waits on a non-blocking pipe that has nothing yet", .timeLimit(.minutes(1)))
    func boundedReadWaitsOnANonBlockingPipe() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let (reader, writer) = (ends[0], ends[1])
        defer { close(reader) }
        try #require(fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK) == 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let bytes = Array("late".utf8)
            _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, bytes.count) }
            close(writer)
        }
        #expect(try readAtMost(reader, limit: 10) == Data("late".utf8))
    }
}

/// A flag set from another thread.
private final class ReleaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
