import AppleKit
import Darwin
import Dispatch
import Foundation

// Test-only executable. Each invocation owns one mode and only its parent's scratch fixtures.
private enum ProbeFailure: Error { case check }

private func require(_ condition: @autoclosure () throws -> Bool) throws {
    guard try condition() else { throw ProbeFailure.check }
}

private final class Descriptors {
    private var owned: Set<Int32> = []

    func own(_ descriptor: Int32) throws -> Int32 {
        try require(descriptor > STDERR_FILENO)
        try require(owned.insert(descriptor).inserted)
        return descriptor
    }

    func close(_ descriptor: Int32) throws {
        try require(owned.remove(descriptor) != nil)
        try require(Darwin.close(descriptor) == 0)
    }

    deinit { for descriptor in owned { _ = Darwin.close(descriptor) } }
}

private func handler(_ action: sigaction) -> UnsafeRawPointer? {
    unsafeBitCast(action.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self)
}

private func signalState() throws -> sigaction {
    var action = sigaction()
    try require(sigaction(SIGPIPE, nil, &action) == 0)
    return action
}

private func requireDefaultUnblocked() throws {
    let action = try signalState()
    try require(handler(action) == unsafeBitCast(SIG_DFL, to: UnsafeRawPointer?.self))
    var mask = sigset_t()
    try require(pthread_sigmask(SIG_SETMASK, nil, &mask) == 0)
    try require(sigismember(&mask, SIGPIPE) == 0)
}

private func socketProtection(_ descriptor: Int32) throws -> Int32 {
    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    try require(getsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0)
    try require(length == socklen_t(MemoryLayout<Int32>.size))
    return value
}

private struct OriginalState {
    let status: Int32
    let descriptor: Int32
    let noSignal: Int32?
    let socketNoSignal: Int32?
    let action: sigaction

    init(_ fd: Int32, stream: Bool, socket: Bool) throws {
        let status = fcntl(fd, F_GETFL)
        let descriptor = fcntl(fd, F_GETFD)
        try require(status >= 0 && descriptor >= 0)
        self.status = status
        self.descriptor = descriptor
        if stream {
            let flag = fcntl(fd, F_GETNOSIGPIPE)
            try require(flag >= 0)
            noSignal = flag
        } else { noSignal = nil }
        if socket { socketNoSignal = try socketProtection(fd) }
        else { socketNoSignal = nil }
        action = try signalState()
    }

    func verify(_ fd: Int32) throws {
        // F_GETFL also exposes kernel bookkeeping, such as FWASWRITTEN after write(2).
        // Compare access mode and every public F_SETFL setting, not that mutable history bit.
        let publicStatus = O_ACCMODE | O_APPEND | O_ASYNC | O_SYNC | O_DSYNC | O_NONBLOCK
        let currentStatus = fcntl(fd, F_GETFL)
        try require(currentStatus >= 0 && currentStatus & publicStatus == status & publicStatus)
        try require(fcntl(fd, F_GETFD) == descriptor)
        if let noSignal { try require(fcntl(fd, F_GETNOSIGPIPE) == noSignal) }
        if let socketNoSignal { try require(try socketProtection(fd) == socketNoSignal) }
        let current = try signalState()
        try require(handler(current) == handler(action) && current.sa_flags == action.sa_flags)
    }
}

private enum Transport: String { case pipe, fifo, socket }

private struct StreamFixture {
    let reader: Int32
    let original: Int32
    let transport: Transport

    init(_ transport: Transport, root: URL, owned: Descriptors) throws {
        self.transport = transport
        switch transport {
        case .pipe:
            var ends: [Int32] = [-1, -1]
            try require(pipe(&ends) == 0)
            reader = try owned.own(ends[0])
            original = try owned.own(ends[1])
        case .socket:
            var ends: [Int32] = [-1, -1]
            try require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
            reader = try owned.own(ends[0])
            original = try owned.own(ends[1])
        case .fifo:
            let path = root.appendingPathComponent("fixture.fifo").path
            try require(mkfifo(path, 0o600) == 0)
            reader = try owned.own(open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC))
            original = try owned.own(open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC))
        }
    }

    func protect() throws {
        try require(fcntl(original, F_GETNOSIGPIPE) == 0)
        try require(fcntl(original, F_SETNOSIGPIPE, 1) == 0)
        try require(fcntl(original, F_GETNOSIGPIPE) > 0)
    }

    func snapshot() throws -> OriginalState {
        try OriginalState(original, stream: true, socket: transport == .socket)
    }
}

private func nonblocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    try require(flags >= 0)
    try require(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
}

private let smallRecord = Data([0x72, 0x65, 0x63, 0x6f, 0x72, 0x64, 0x85,
                               0xe2, 0x80, 0xa8, 0xe2, 0x80, 0xa9])
private let fillByte: UInt8 = 0x66
private let fixtureLimit = 4 * 1_024 * 1_024

private func framed(_ record: Data) -> Data {
    var result = record
    result.append(0x0a)
    return result
}

private func readToEOF(_ descriptor: Int32, maximum: Int) throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while ContinuousClock.now < deadline {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return result }
        if count > 0 {
            try require(result.count + count <= maximum)
            result.append(contentsOf: buffer.prefix(count))
        } else {
            let failure = errno
            try require(failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR)
            usleep(1_000)
        }
    }
    throw ProbeFailure.check
}

private func expectFailure(_ writer: RecordWriter, record: Data = smallRecord,
                          deadline: ContinuousClock.Instant,
                          isCancelled: @Sendable () -> Bool = { false }) throws -> RecordWriterError {
    do {
        try writer.writeRecord(record, deadline: deadline, isCancelled: isCancelled)
    } catch {
        return error
    }
    throw ProbeFailure.check
}

private func checkFailedReuse(_ writer: RecordWriter) throws {
    let error = try expectFailure(writer, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
    try require(error.reason == .previouslyFailed && error.systemErrno == nil && error.bytesWritten == 0)
}

private func rawClosed(_ transport: Transport, root: URL) throws {
    let owned = Descriptors()
    let fixture = try StreamFixture(transport, root: root, owned: owned)
    if transport != .socket { try fixture.protect() }
    else {
        try require(fcntl(fixture.original, F_GETNOSIGPIPE) == 0)
        try require(try socketProtection(fixture.original) == 0)
    }
    let before = try fixture.snapshot()
    try owned.close(fixture.reader)
    // Assert immediately before the raw syscall: neither ignore nor masking can hide SIGPIPE.
    try requireDefaultUnblocked()
    var byte: UInt8 = 0x72
    let count: Int
    if transport == .socket {
        count = Darwin.send(fixture.original, &byte, 1, MSG_DONTWAIT | MSG_NOSIGNAL)
    } else {
        count = Darwin.write(fixture.original, &byte, 1)
    }
    let failure = errno
    try require(count == -1 && failure == EPIPE)
    try before.verify(fixture.original)
    try requireDefaultUnblocked()
}

private func refused(_ transport: Transport, root: URL) throws {
    let owned = Descriptors()
    let fixture = try StreamFixture(transport, root: root, owned: owned)
    try requireDefaultUnblocked()
    try require(fcntl(fixture.original, F_GETNOSIGPIPE) == 0)
    let before = try fixture.snapshot()
    do {
        let writer = try RecordWriter(borrowing: fixture.original)
        try writer.close()
        throw ProbeFailure.check
    } catch let error as RecordWriterError {
        try require(error.reason == .unsafeSignalPolicy && error.systemErrno == nil && error.bytesWritten == 0)
    }
    try before.verify(fixture.original)
}

private func closed(_ transport: Transport, root: URL) throws {
    let owned = Descriptors()
    let fixture = try StreamFixture(transport, root: root, owned: owned)
    try fixture.protect()
    try requireDefaultUnblocked()
    let before = try fixture.snapshot()
    let writer = try RecordWriter(borrowing: fixture.original)
    try before.verify(fixture.original)
    try owned.close(fixture.reader)
    let error = try expectFailure(writer, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
    try require(error.reason == .writeFailure && error.bytesWritten == 0)
    if transport == .socket { try require(error.systemErrno == EPIPE) }
    else { try require(error.systemErrno == nil || error.systemErrno == EPIPE) }
    try checkFailedReuse(writer)
    try writer.close()
    try writer.close()
    try before.verify(fixture.original)
    try requireDefaultUnblocked()
}

private func success(_ transport: Transport, root: URL, ignored: Bool = false) throws {
    let owned = Descriptors()
    let fixture = try StreamFixture(transport, root: root, owned: owned)
    if ignored {
        try requireDefaultUnblocked()
        let previous = signal(SIGPIPE, SIG_IGN)
        try require(unsafeBitCast(previous, to: UnsafeRawPointer?.self)
                    != unsafeBitCast(SIG_ERR, to: UnsafeRawPointer?.self))
        try require(handler(try signalState()) == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self))
        try require(fcntl(fixture.original, F_GETNOSIGPIPE) == 0)
    } else { try fixture.protect() }
    if transport != .socket {
        let limit = fpathconf(fixture.original, _PC_PIPE_BUF)
        try require(limit >= framed(smallRecord).count)
    }
    try nonblocking(fixture.reader)
    let before = try fixture.snapshot()
    let writer = try RecordWriter(borrowing: fixture.original)
    try before.verify(fixture.original)
    try writer.writeRecord(smallRecord, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
    try before.verify(fixture.original)
    try writer.close()
    try before.verify(fixture.original)
    try owned.close(fixture.original)
    let received = try readToEOF(fixture.reader, maximum: framed(smallRecord).count)
    try require(received == framed(smallRecord))
}

private func successFile(root: URL, null: Bool) throws {
    let owned = Descriptors()
    let path = null ? "/dev/null" : root.appendingPathComponent("fixture.record").path
    let flags = null ? O_WRONLY | O_CLOEXEC : O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC
    let original = try owned.own(open(path, flags, 0o600))
    let before = try OriginalState(original, stream: false, socket: false)
    let writer = try RecordWriter(borrowing: original)
    try before.verify(original)
    try writer.writeRecord(smallRecord, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
    try before.verify(original)
    try writer.close()
    try before.verify(original)
    if !null {
        var bytes = [UInt8](repeating: 0, count: framed(smallRecord).count + 1)
        let count = pread(original, &bytes, bytes.count, 0)
        try require(count == framed(smallRecord).count)
        try require(Data(bytes.prefix(count)) == framed(smallRecord))
    }
}

// Fill only the fixture-owned stream. Large writes followed by single-byte writes establish
// actual EAGAIN, rather than guessing an OS-dependent capacity or readiness threshold.
private func fill(_ fixture: StreamFixture) throws -> Int {
    try nonblocking(fixture.original)
    let buffer = [UInt8](repeating: fillByte, count: 4_096)
    var total = 0
    for request in [buffer.count, 1] {
        while true {
            let count = buffer.withUnsafeBytes { bytes in
                fixture.transport == .socket
                    ? Darwin.send(fixture.original, bytes.baseAddress, request, MSG_DONTWAIT | MSG_NOSIGNAL)
                    : Darwin.write(fixture.original, bytes.baseAddress, request)
            }
            let failure = errno
            if count > 0 {
                total += count
                try require(total <= fixtureLimit)
            } else {
                try require(count == -1 && (failure == EAGAIN || failure == EWOULDBLOCK))
                break
            }
        }
    }
    try require(total > 0)
    return total
}

private func backpressure(_ transport: Transport, root: URL, cancel: Bool) throws {
    let owned = Descriptors()
    let fixture = try StreamFixture(transport, root: root, owned: owned)
    try fixture.protect()
    _ = try fill(fixture)
    let before = try fixture.snapshot()
    let writer = try RecordWriter(borrowing: fixture.original)
    let start = ContinuousClock.now
    let error = try expectFailure(writer, deadline: start.advanced(by: cancel ? .seconds(1) : .milliseconds(180)),
                                  isCancelled: { cancel && ContinuousClock.now >= start.advanced(by: .milliseconds(100)) })
    try require(error.reason == (cancel ? .cancelled : .timedOut))
    try require(error.systemErrno == nil && error.bytesWritten == 0)
    try checkFailedReuse(writer)
    try writer.close()
    try before.verify(fixture.original)
}

private func closeReuse(root: URL) throws {
    let owned = Descriptors()
    let firstPath = root.appendingPathComponent("first.record").path
    let replacementPath = root.appendingPathComponent("replacement.record").path
    let original = try owned.own(open(firstPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600))
    let writer = try RecordWriter(borrowing: original)
    try owned.close(original)
    let opened = try owned.own(open(replacementPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600))
    // Require observed reuse. Never force dup2 onto a slot another runtime thread could own.
    try require(opened == original)
    let replacement = opened
    let before = try OriginalState(replacement, stream: false, socket: false)
    try writer.writeRecord(smallRecord, deadline: ContinuousClock.now.advanced(by: .seconds(1)))
    try writer.close()
    try before.verify(replacement)
    var information = stat()
    try require(fstat(replacement, &information) == 0 && information.st_size == 0)
    let reader = try owned.own(open(firstPath, O_RDONLY | O_CLOEXEC))
    try require(try readToEOF(reader, maximum: framed(smallRecord).count) == framed(smallRecord))
}

// Only this fixture's nonblocking reader is used on the in-child drain queue. Result transfer
// is locked, and the main thread waits for completion before reporting or releasing descriptors.
private final class DrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, ProbeFailure>?

    func store(_ value: Result<Data, ProbeFailure>) {
        lock.lock(); defer { lock.unlock() }
        result = value
    }

    func take() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw ProbeFailure.check }
        return try result.get()
    }
}

private func partialFIFO(root: URL, mode: String) throws -> String {
    let owned = Descriptors()
    let fixture = try StreamFixture(.fifo, root: root, owned: owned)
    try fixture.protect()
    let total = try fill(fixture)
    var byte: UInt8 = 0
    try require(Darwin.read(fixture.reader, &byte, 1) == 1 && byte == fillByte)
    var readiness = pollfd(fd: fixture.original, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&readiness, 1, 0)
    try require(ready == 0 || ready == 1)
    if ready == 0 {
        try require(readiness.revents == 0)
        return "threshold-unavailable\n"
    }
    // Closure, invalid descriptors and unexpected event bits are failures, not threshold skips.
    try require(readiness.revents == Int16(POLLOUT))
    let record = Data(repeating: 0x72, count: 512)
    let attempted = record.withUnsafeBytes { Darwin.write(fixture.original, $0.baseAddress, $0.count) }
    let failure = errno
    // A different kernel threshold is explicit evidence, not reduced-chunk coverage.
    if attempted > 0 {
        try require(attempted <= record.count)
        return "threshold-unavailable\n"
    }
    try require(attempted == -1 && (failure == EAGAIN || failure == EWOULDBLOCK))
    let before = try fixture.snapshot()
    let writer = try RecordWriter(borrowing: fixture.original)
    try before.verify(fixture.original)
    if mode == "partial-fifo-drain" {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = DrainResult()
        let reader = fixture.reader
        DispatchQueue.global().async {
            defer { finished.signal() }
            guard started.wait(timeout: .now() + 1) == .success else {
                result.store(.failure(.check)); return
            }
            do { result.store(.success(try readToEOF(reader, maximum: fixtureLimit + 513))) }
            catch { result.store(.failure(.check)) }
        }
        // No capture of mutable state: multiple signals are harmless; the reader waits once.
        var writeSucceeded = false
        do {
            try writer.writeRecord(record, deadline: ContinuousClock.now.advanced(by: .seconds(1)), isCancelled: {
                started.signal()
                return false
            })
            writeSucceeded = true
        } catch {
            // Still close and join the owned reader before surfacing a failed write.
        }
        var cleanupSucceeded = true
        do { try writer.close() } catch { cleanupSucceeded = false }
        do { try before.verify(fixture.original) } catch { cleanupSucceeded = false }
        do { try owned.close(fixture.original) } catch { cleanupSucceeded = false }
        started.signal()
        // If the queue cannot finish, exit without releasing descriptors underneath its reads.
        guard finished.wait(timeout: .now() + 1.5) == .success else { _exit(1) }
        try require(writeSucceeded && cleanupSucceeded)
        let received = try result.take()
        var expected = Data(repeating: fillByte, count: total - 1)
        expected.append(framed(record))
        try require(received == expected)
    } else {
        let cancel = mode == "partial-fifo-cancel"
        let start = ContinuousClock.now
        let error = try expectFailure(writer, record: record,
                                      deadline: start.advanced(by: cancel ? .seconds(1) : .milliseconds(180)),
                                      isCancelled: { cancel && ContinuousClock.now >= start.advanced(by: .milliseconds(100)) })
        try require(error.reason == (cancel ? .cancelled : .timedOut))
        try require(error.systemErrno == nil && error.bytesWritten >= 1 && error.bytesWritten < framed(record).count)
        try checkFailedReuse(writer)
        try writer.close()
        try before.verify(fixture.original)
    }
    return "exercised\n"
}

private func run(_ mode: String, root: URL) throws -> String {
    try requireDefaultUnblocked()
    switch mode {
    case "raw-pipe": try rawClosed(.pipe, root: root)
    case "raw-fifo": try rawClosed(.fifo, root: root)
    case "raw-socket-nosignal": try rawClosed(.socket, root: root)
    case "refuse-pipe": try refused(.pipe, root: root)
    case "refuse-socket": try refused(.socket, root: root)
    case "closed-pipe": try closed(.pipe, root: root)
    case "closed-fifo": try closed(.fifo, root: root)
    case "closed-socket": try closed(.socket, root: root)
    case "success-pipe": try success(.pipe, root: root)
    case "success-fifo": try success(.fifo, root: root)
    case "success-socket": try success(.socket, root: root)
    case "success-file": try successFile(root: root, null: false)
    case "success-null": try successFile(root: root, null: true)
    case "ignored-pipe": try success(.pipe, root: root, ignored: true)
    case "ignored-socket": try success(.socket, root: root, ignored: true)
    case "full-pipe-timeout": try backpressure(.pipe, root: root, cancel: false)
    case "full-pipe-cancel": try backpressure(.pipe, root: root, cancel: true)
    case "full-fifo-timeout": try backpressure(.fifo, root: root, cancel: false)
    case "full-fifo-cancel": try backpressure(.fifo, root: root, cancel: true)
    case "full-socket-timeout": try backpressure(.socket, root: root, cancel: false)
    case "full-socket-cancel": try backpressure(.socket, root: root, cancel: true)
    case "close-reuse": try closeReuse(root: root)
    case "partial-fifo-timeout", "partial-fifo-cancel", "partial-fifo-drain":
        return try partialFIFO(root: root, mode: mode)
    default: throw ProbeFailure.check
    }
    return "ok\n"
}

// Signal policy changes, including the ignored branch, never occur in the parallel test runner.
_ = alarm(3)
do {
    try require(CommandLine.arguments.count == 3)
    let marker = try run(CommandLine.arguments[1], root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    let bytes = Data(marker.utf8)
    let count = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    guard count == bytes.count else { _exit(2) }
} catch {
    // Never print paths, descriptors, records, OS error descriptions or unbounded diagnostics.
    let bytes = Data("probe-failed\n".utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    _exit(1)
}
