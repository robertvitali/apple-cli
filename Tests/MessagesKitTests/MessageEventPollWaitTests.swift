import Darwin
import Foundation
import Testing
@testable import MessagesKit

struct MessageEventPollWaitTests {
    @Test func idlePipeAndBackpressurePreserveTheReader() throws {
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[1]) }
        let waiter = try MessageEventPollWait(output: pipeFDs[1])
        do {
            defer { close(pipeFDs[0]) }
            let flags = fcntl(pipeFDs[1], F_GETFL)
            try #require(flags >= 0 && fcntl(pipeFDs[1], F_SETFL, flags | O_NONBLOCK) == 0)
            let until = ContinuousClock.now.advanced(by: .milliseconds(10))
            try waiter.wait(until: until)
            #expect(ContinuousClock.now >= until)
            let bytes = [UInt8](repeating: 0, count: 4096)
            try bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < 16 << 20 {
                    let count = write(pipeFDs[1], buffer.baseAddress, buffer.count)
                    if count < 0 {
                        try #require(errno == EAGAIN)
                        break
                    }
                    try #require(count > 0)
                    written += count
                }
                #expect(written > 0 && written < 16 << 20)
            }
            try waiter.wait(until: .now)
        }
        #expect(throws: MessageEventPollWait.Failure.outputClosed) { try waiter.wait(until: .now) }
    }

    @Test func socketReaderCanStopSendingAndContinueReading() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        let waiter = try MessageEventPollWait(output: pair[1])
        do {
            defer { close(pair[0]) }
            try #require(shutdown(pair[0], SHUT_WR) == 0)
            try waiter.wait(until: .now)
        }
        #expect(throws: MessageEventPollWait.Failure.outputClosed) { try waiter.wait(until: .now) }
    }

    @Test func regularFileWaitPreservesOffsetAndContents() throws {
        let file = try #require(tmpfile())
        defer { fclose(file) }
        let fd = fileno(file)
        let waiter = try MessageEventPollWait(output: fd)
        let until = ContinuousClock.now.advanced(by: .milliseconds(10))
        try waiter.wait(until: until)
        #expect(ContinuousClock.now >= until)
        #expect(lseek(fd, 0, SEEK_END) == 0)
        #expect(throws: MessageEventPollWait.Failure.invalidOutput) { try MessageEventPollWait(output: -1) }
    }
}
