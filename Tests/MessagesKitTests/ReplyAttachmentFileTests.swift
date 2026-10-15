import Darwin
import Foundation
import Testing
import TestSupport
@testable import MessagesKit
import AppleKit

@Suite("Messages reply attachment file boundaries")
struct ReplyAttachmentFileTests {
    private let scratch = ScratchDirs("reply-attachment-files")

    @Test func sourceFIFOIsRefusedWithoutWaitingForWriter() throws {
        let root = try scratch.directory()
        let path = root.appendingPathComponent("source.bin").path
        try assertFIFORefusedWithoutWaiting(path: path) {
            #expect(throws: Error.self) {
                _ = try prepareReplyAttachmentDraftCopy(rawFilePath: path, scratchRoot: root.path,
                                                        home: root.path, deadline: .millisecondsFromNow(2_000))
            }
        }
    }

    @Test func replacedCopyFIFOIsRefusedWithoutWaitingForWriter() throws {
        let root = try scratch.directory()
        let source = root.appendingPathComponent("source.bin")
        try Data("apple-cli-test attachment".utf8).write(to: source)
        let draft = try prepareReplyAttachmentDraftCopy(rawFilePath: source.path, scratchRoot: root.path,
                                                       home: root.path, deadline: .millisecondsFromNow(2_000))
        try FileManager.default.removeItem(atPath: draft.copyPath)
        try assertFIFORefusedWithoutWaiting(path: draft.copyPath) {
            #expect(throws: Error.self) {
                _ = try validateReplyAttachmentDraftCopy(draft, deadline: .millisecondsFromNow(2_000))
            }
        }
    }
}

// A delayed writer releases an accidentally blocking open, so the regression
// reports a failure instead of hanging the suite. The expected path returns
// before that writer is attempted; every scheduled callback is joined.
func assertFIFORefusedWithoutWaiting(path: String, operation: () throws -> Void) throws {
    try #require(mkfifo(path, 0o600) == 0)
    let state = FIFOReleaseState()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.25)
        state.markAttempted()
        let writer = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if writer >= 0 { close(writer) }
        finished.signal()
    }
    defer { #expect(finished.wait(timeout: .now() + .seconds(3)) == .success) }
    try operation()
    #expect(!state.wasAttempted)
}

private final class FIFOReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false
    func markAttempted() { lock.withLock { attempted = true } }
    var wasAttempted: Bool { lock.withLock { attempted } }
}
