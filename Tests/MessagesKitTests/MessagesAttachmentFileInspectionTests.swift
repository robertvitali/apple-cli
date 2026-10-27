import Darwin
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentFileInspectionTests {
    @Test func regularMissingUnsafeAndNonregularFiles() throws {
        let fx = try ChatFixture()
        let probe = MessagesAttachmentFileInspection(homeDirectory: fx.homePath)
        #expect(try probe.inspect(filename: fx.presentAttachmentPath) == .readableRegularFile)
        #expect(try probe.inspect(filename: "~/Library/Messages/Attachments/zz/apple-cli-present.png") == .readableRegularFile)
        #expect(try probe.inspect(filename: "~/Library/Messages/Attachments/absent/file") == .missing)
        #expect(try probe.inspect(filename: "~/Library/Messages/Attachments/zz") == .unavailable)
        #expect(try probe.inspect(filename: fx.symlinkAttachmentPath) == .unavailable)
        for path in [nil, "", "/Volumes/synthetic", "/etc/passwd", "relative", "~/Library/Messages/Attachments/../outside", "~/Library/Messages/Attachments/zz//file", "~/Library/Messages/Attachments/zz/./file", "~/Library/Messages/Attachments/zz/file\0suffix"] as [String?] {
            #expect(try probe.inspect(filename: path) == .unavailable)
        }
        let root = URL(fileURLWithPath: fx.homePath).appendingPathComponent("Library/Messages/Attachments")
        let fifo = root.appendingPathComponent("synthetic-fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(try probe.inspect(filename: fifo) == .unavailable)
        let directoryLink = root.appendingPathComponent("directory-link").path
        try FileManager.default.createSymbolicLink(atPath: directoryLink, withDestinationPath: root.appendingPathComponent("zz").path)
        #expect(try probe.inspect(filename: directoryLink + "/apple-cli-present.png") == .unavailable)
    }

    @Test func noOutboundSizeLimitAndPermissionFailure() throws {
        let fx = try ChatFixture()
        let probe = MessagesAttachmentFileInspection(homeDirectory: fx.homePath)
        let base = URL(fileURLWithPath: fx.presentAttachmentPath).deletingLastPathComponent()
        let empty = base.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try probe.inspect(filename: empty.path) == .readableRegularFile)
        let large = base.appendingPathComponent("large").path
        let fd = open(large, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        #expect(ftruncate(fd, 32 * 1_024 * 1_024) == 0)
        close(fd)
        #expect(try probe.inspect(filename: large) == .readableRegularFile)
        if getuid() != 0 {
            #expect(chmod(empty.path, 0) == 0)
            defer { chmod(empty.path, 0o600) }
            #expect(try probe.inspect(filename: empty.path) == .unavailable)
        }
    }

    @Test func cancellationPropagatesAndRootSymlinkIsRefused() throws {
        enum Cancelled: Error { case stop }
        let fx = try ChatFixture()
        let probe = MessagesAttachmentFileInspection(homeDirectory: fx.homePath)
        var calls = 0
        #expect(throws: Cancelled.self) {
            try probe.inspect(filename: fx.presentAttachmentPath) {
                calls += 1
                if calls == 5 { throw Cancelled.stop }
            }
        }
        #expect(calls == 5)
        #expect(try probe.inspect(filename: fx.presentAttachmentPath) == .readableRegularFile)
        let alias = fx.homePath + "-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fx.homePath)
        #expect(try MessagesAttachmentFileInspection(homeDirectory: alias).inspect(filename: "~/Library/Messages/Attachments/zz/apple-cli-present.png") == .unavailable)
    }
}
