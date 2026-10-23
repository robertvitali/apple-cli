import Darwin
import Foundation
import Testing
@testable import AppleKit

private final class RecordIOFixture: RecordWriterIO, @unchecked Sendable {
    enum Step { case count(Int), failure(Int32) }
    var type = mode_t(S_IFREG)
    var flags = O_WRONLY
    var socket = SOCK_STREAM
    var ignored = true
    var protection: Int32 = 0
    var atomicLimit = 512
    var failAt: String?
    var failureCode: Int32 = EIO
    var steps: [Step] = []
    var polls: [Result<Int16?, RecordWriterSystemError>] = []
    var calls: [String] = []
    var requests: [Int] = []
    var sendFlags: [Int32] = []
    var pollTimeouts: [Int32] = []
    var output = Data()
    var closeCount = 0
    var closeFailure: Int32?
    var clock = ContinuousClock().now
    var pollAdvance = Duration.zero
    var afterOutput: ((RecordIOFixture) -> Void)?
    var minimum: Int32?

    private func answer<T>(_ name: String, _ value: T) -> Result<T, RecordWriterSystemError> {
        calls.append(name)
        return failAt == name ? .failure(.init(code: failureCode)) : .success(value)
    }
    func duplicate(_ descriptor: Int32, minimum: Int32) -> Result<Int32, RecordWriterSystemError> {
        self.minimum = minimum
        return answer("duplicate", 100)
    }
    func fileType(_ descriptor: Int32) -> Result<mode_t, RecordWriterSystemError> { answer("type", type) }
    func statusFlags(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> { answer("flags", flags) }
    func socketType(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> { answer("socket", socket) }
    func ignoresSIGPIPE() -> Result<Bool, RecordWriterSystemError> { answer("signal", ignored) }
    func noSIGPIPE(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> { answer("protection", protection) }
    func pipeAtomicLimit(_ descriptor: Int32) -> Result<Int, RecordWriterSystemError> { answer("limit", atomicLimit) }
    func pollWritable(_ descriptor: Int32, milliseconds: Int32) -> Result<Int16?, RecordWriterSystemError> {
        calls.append("poll")
        pollTimeouts.append(milliseconds)
        clock = clock.advanced(by: pollAdvance)
        return polls.isEmpty ? .success(Int16(POLLOUT)) : polls.removeFirst()
    }
    private func emit(_ bytes: UnsafeRawBufferPointer) -> Result<Int, RecordWriterSystemError> {
        requests.append(bytes.count)
        let step = steps.isEmpty ? .count(bytes.count) : steps.removeFirst()
        switch step {
        case .failure(let code): return .failure(.init(code: code))
        case .count(let count):
            precondition((0...bytes.count).contains(count), "invalid scripted write count")
            output.append(contentsOf: bytes.prefix(count))
            afterOutput?(self)
            return .success(count)
        }
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) -> Result<Int, RecordWriterSystemError> {
        calls.append("write"); return emit(bytes)
    }
    func send(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, flags: Int32) -> Result<Int, RecordWriterSystemError> {
        calls.append("send"); sendFlags.append(flags); return emit(bytes)
    }
    func close(_ descriptor: Int32) -> Result<Void, RecordWriterSystemError> {
        closeCount += 1
        if let closeFailure { calls.append("close"); return .failure(.init(code: closeFailure)) }
        return answer("close", ())
    }
    func now() -> ContinuousClock.Instant { clock }
}

private final class RecordResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecordWriterError?
    func set(_ error: RecordWriterError) { lock.withLock { stored = error } }
    var value: RecordWriterError? { lock.withLock { stored } }
}

struct RecordWriterTests {
    private func failure(_ reason: RecordWriterError.Reason, errno: Int32? = nil, bytes: Int = 0,
                         _ body: () throws -> Void) {
        do { try body(); Issue.record("expected a record-writer failure") }
        catch let error as RecordWriterError {
            #expect(error.reason == reason)
            #expect(error.systemErrno == errno)
            #expect(error.bytesWritten == bytes)
        } catch { Issue.record("unexpected error type") }
    }

    @Test(arguments: ["duplicate", "type", "flags", "socket", "signal", "protection", "limit"])
    func initializationFailuresCloseOnlyOwnedDuplicate(_ operation: String) {
        let io = RecordIOFixture()
        io.type = operation == "socket" ? mode_t(S_IFSOCK) : mode_t(S_IFIFO)
        io.ignored = false; io.protection = 1; io.failAt = operation
        let reason: RecordWriterError.Reason = ["signal", "protection"].contains(operation) ? .unsafeSignalPolicy
            : ["socket", "limit"].contains(operation) ? .unsupportedDescriptor : .invalidDescriptor
        failure(reason, errno: EIO) { _ = try RecordWriter(borrowing: 12, io: io) }
        #expect(io.closeCount == (operation == "duplicate" ? 0 : 1))
        #expect(io.minimum == 3)
    }

    @Test(arguments: [EBADF, EMFILE, ENFILE])
    func duplicationPreservesFailureCode(_ code: Int32) {
        let io = RecordIOFixture(); io.failAt = "duplicate"; io.failureCode = code
        failure(.invalidDescriptor, errno: code) { _ = try RecordWriter(borrowing: -1, io: io) }
        #expect(io.closeCount == 0)
    }

    @Test func validationOrderAndSemanticRefusals() {
        let readOnly = RecordIOFixture(); readOnly.type = mode_t(S_IFDIR); readOnly.flags = O_RDONLY
        failure(.invalidDescriptor) { _ = try RecordWriter(borrowing: 4, io: readOnly) }
        #expect(readOnly.calls == ["duplicate", "type", "flags", "close"])
        let directory = RecordIOFixture(); directory.type = mode_t(S_IFDIR)
        failure(.unsupportedDescriptor) { _ = try RecordWriter(borrowing: 4, io: directory) }
        let datagram = RecordIOFixture(); datagram.type = mode_t(S_IFSOCK); datagram.socket = SOCK_DGRAM
        failure(.unsupportedDescriptor) { _ = try RecordWriter(borrowing: 4, io: datagram) }
        #expect(!datagram.calls.contains("signal"))
        for kind in [S_IFIFO, S_IFSOCK] {
            let unsafe = RecordIOFixture(); unsafe.type = mode_t(kind); unsafe.ignored = false
            failure(.unsafeSignalPolicy) { _ = try RecordWriter(borrowing: 4, io: unsafe) }
        }
        for limit in [0, -1] {
            let badLimit = RecordIOFixture(); badLimit.type = mode_t(S_IFIFO); badLimit.atomicLimit = limit
            failure(.unsupportedDescriptor) { _ = try RecordWriter(borrowing: 4, io: badLimit) }
        }
    }

    @Test func ignoredSignalSkipsFlagQueryAndFlagOnlyPolicyWorks() throws {
        for kind in [S_IFIFO, S_IFSOCK] {
            let ignored = RecordIOFixture(); ignored.type = mode_t(kind); ignored.failAt = "protection"
            try RecordWriter(borrowing: 4, io: ignored).close()
            #expect(!ignored.calls.contains("protection"))
            let protected = RecordIOFixture(); protected.type = mode_t(kind); protected.ignored = false; protected.protection = 1
            try RecordWriter(borrowing: 4, io: protected).close()
            #expect(protected.calls.contains("protection"))
        }
    }

    @Test func recordsPreserveBytesAndExactlyOneDelimiter() throws {
        let io = RecordIOFixture(); let writer = try RecordWriter(borrowing: 4, io: io)
        let record = Data("{\"value\":\"é\u{0085}\u{2028}\u{2029}\"}".utf8)
        try writer.writeRecord(record, deadline: io.clock.advanced(by: .seconds(1)))
        try writer.writeRecord(Data([0]), deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.output == record + Data([10, 0, 10]))
        #expect(io.calls.filter { $0 == "poll" }.isEmpty)
    }

    @Test func invalidRecordsDoNotPoisonReadyWriter() throws {
        let io = RecordIOFixture(); let writer = try RecordWriter(borrowing: 4, io: io)
        for record in [Data(), Data([10]), Data([13]), Data(repeating: 65, count: 8 * 1_024 * 1_024 + 1)] {
            failure(.invalidRecord) { try writer.writeRecord(record, deadline: io.clock) }
        }
        #expect(io.output.isEmpty)
        try writer.writeRecord(Data("ok".utf8), deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.output == Data("ok\n".utf8))
    }

    @Test func maximumRecordAndChunks() throws {
        let io = RecordIOFixture(); let writer = try RecordWriter(borrowing: 4, io: io)
        let data = Data(repeating: 65, count: 8 * 1_024 * 1_024)
        try writer.writeRecord(data, deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.output.count == data.count + 1)
        #expect(io.output.dropLast().elementsEqual(data))
        #expect(io.output.last == 10)
        #expect(io.requests.dropLast().allSatisfy { $0 == 4_096 })
        #expect(io.requests.last == 1)
    }

    @Test(arguments: [0, 1, 2, 3])
    func partialBodyOrDelimiterFailureLatches(_ prefix: Int) throws {
        let io = RecordIOFixture()
        io.steps = prefix == 0 ? [.failure(EPIPE)] : [.count(prefix), .failure(EPIPE)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.writeFailure, errno: EPIPE, bytes: prefix) {
            try writer.writeRecord(Data("abc".utf8), deadline: io.clock.advanced(by: .seconds(1)))
        }
        #expect(io.output == Data("abc".utf8).prefix(prefix))
        failure(.previouslyFailed) { try writer.writeRecord(Data(), deadline: io.clock) }
        try writer.close()
        failure(.closed) { try writer.writeRecord(Data(), deadline: io.clock) }
    }

    @Test func zeroWriteAndCancellationPrecedence() throws {
        let zero = RecordIOFixture(); zero.steps = [.count(0)]
        let writer = try RecordWriter(borrowing: 4, io: zero)
        failure(.zeroProgress) { try writer.writeRecord(Data([65]), deadline: zero.clock.advanced(by: .seconds(1))) }
        let cancelled = RecordIOFixture(); let second = try RecordWriter(borrowing: 4, io: cancelled)
        failure(.cancelled) { try second.writeRecord(Data([65]), deadline: cancelled.clock, isCancelled: { true }) }
        #expect(!cancelled.calls.contains("write"))
        failure(.previouslyFailed) { try second.writeRecord(Data([65]), deadline: cancelled.clock) }
        let expired = RecordIOFixture(); let third = try RecordWriter(borrowing: 4, io: expired)
        failure(.timedOut) { try third.writeRecord(Data([65]), deadline: expired.clock) }
    }

    @Test func cancellationAfterPrefixAndNoCheckAfterFullFrame() throws {
        let partial = RecordIOFixture(); partial.steps = [.count(2)]
        let first = try RecordWriter(borrowing: 4, io: partial)
        failure(.cancelled, bytes: 2) {
            try first.writeRecord(Data("abc".utf8), deadline: partial.clock.advanced(by: .seconds(1)),
                                  isCancelled: { partial.output.count >= 2 })
        }
        let complete = RecordIOFixture(); let second = try RecordWriter(borrowing: 4, io: complete)
        let deadline = complete.clock.advanced(by: .seconds(1))
        complete.afterOutput = { if $0.output.last == 10 { $0.clock = deadline } }
        try second.writeRecord(Data([65]), deadline: deadline, isCancelled: { complete.output.last == 10 })
        #expect(complete.output == Data([65, 10]))
    }

    @Test func deadlineAfterPartialWriteReportsBytes() throws {
        let io = RecordIOFixture(); io.steps = [.count(2)]
        let deadline = io.clock.advanced(by: .milliseconds(1))
        io.afterOutput = { $0.clock = deadline }
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.timedOut, bytes: 2) { try writer.writeRecord(Data("abc".utf8), deadline: deadline) }
    }

    @Test func fifoHalvesActualRequestAndRestoresCapAfterProgress() throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFIFO)
        io.steps = Array(repeating: .failure(EAGAIN), count: 9) + [.count(1)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        let data = Data(repeating: 65, count: 512)
        try writer.writeRecord(data, deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.requests == [512, 256, 128, 64, 32, 16, 8, 4, 2, 1, 511, 1])
        #expect(io.output == data + Data([10]))
        #expect(io.pollTimeouts.count == io.requests.count)
    }

    @Test func pipeLimitClampsAndShortRequestReduction() throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFIFO); io.atomicLimit = 100_000
        io.steps = [.failure(EAGAIN), .count(1)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        try writer.writeRecord(Data([65, 66, 67]), deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.requests == [3, 1, 2, 1])
        let larger = RecordIOFixture(); larger.type = mode_t(S_IFIFO); larger.atomicLimit = 100_000
        try RecordWriter(borrowing: 4, io: larger).writeRecord(Data(repeating: 65, count: 4_097),
                                                            deadline: larger.clock.advanced(by: .seconds(1)))
        #expect(larger.requests == [4_096, 1, 1])
    }

    @Test func socketUsesPerCallFlagsAndWaitsAfterBackpressure() throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFSOCK); io.steps = [.failure(EAGAIN), .failure(EINTR)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        #expect(io.sendFlags == Array(repeating: MSG_DONTWAIT | MSG_NOSIGNAL, count: 4))
        #expect(!io.calls.contains("write"))
        #expect(io.pollTimeouts == [50])
    }

    @Test func transientLimitAndProgressReset() throws {
        let io = RecordIOFixture(); io.steps = Array(repeating: .failure(EINTR), count: 64)
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.retryLimit, errno: EINTR) {
            try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        }
        #expect(io.requests.count == 64)
        let reset = RecordIOFixture()
        reset.steps = Array(repeating: .failure(EINTR), count: 63) + [.count(1)]
            + Array(repeating: .failure(EINTR), count: 63)
        try RecordWriter(borrowing: 4, io: reset).writeRecord(Data([65, 66]), deadline: reset.clock.advanced(by: .seconds(1)))
        #expect(reset.output == Data([65, 66, 10]))
    }

    @Test func pollTimeoutsUseDeadlineAndRoundedSlices() throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFIFO)
        io.polls = Array(repeating: .success(nil), count: 80); io.pollAdvance = .microseconds(100)
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.timedOut) { try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .milliseconds(8))) }
        #expect(io.pollTimeouts.count == 80)
        #expect(io.pollTimeouts.last == 1)
        #expect(io.requests.isEmpty)
        let far = RecordIOFixture(); far.type = mode_t(S_IFIFO)
        try RecordWriter(borrowing: 4, io: far).writeRecord(Data([65]), deadline: far.clock.advanced(by: .seconds(1_000_000)))
        #expect(far.pollTimeouts == [50, 50])
    }

    @Test(arguments: [Int16(POLLHUP), Int16(POLLERR), Int16(POLLNVAL), Int16(0), Int16(POLLIN),
                      Int16(POLLNVAL | POLLHUP | POLLOUT), Int16(POLLERR | POLLOUT)])
    func pollEventsNeverCaptureStaleErrno(_ event: Int16) throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFIFO); io.polls = [.success(event)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        errno = EACCES
        failure(event & Int16(POLLNVAL) != 0 ? .invalidDescriptor : .writeFailure) {
            try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        }
        #expect(io.requests.isEmpty)
    }

    @Test(arguments: [ENODEV, EOPNOTSUPP, EBADF])
    func characterPollFailureIsExplicit(_ code: Int32) throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFCHR); io.steps = [.failure(EAGAIN)]
        io.polls = [.failure(.init(code: code))]
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(code == EBADF ? .writeFailure : .unsupportedDescriptor, errno: code) {
            try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        }
    }

    @Test func characterInvalidReadinessAndPollInterruptionLimit() throws {
        let character = RecordIOFixture(); character.type = mode_t(S_IFCHR)
        character.steps = [.failure(EAGAIN)]; character.polls = [.success(Int16(POLLNVAL))]
        let first = try RecordWriter(borrowing: 4, io: character)
        failure(.unsupportedDescriptor) { try first.writeRecord(Data([65]), deadline: character.clock.advanced(by: .seconds(1))) }
        let io = RecordIOFixture(); io.type = mode_t(S_IFIFO)
        io.polls = Array(repeating: .failure(.init(code: EINTR)), count: 64)
        let second = try RecordWriter(borrowing: 4, io: io)
        failure(.retryLimit, errno: EINTR) { try second.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1))) }
        #expect(io.pollTimeouts.count == 64)
    }

    @Test func closeFailureCannotCloseReusedDescriptorOrRetry() throws {
        let io = RecordIOFixture(); io.failAt = "close"; io.failureCode = EINTR
        var writer: RecordWriter? = try RecordWriter(borrowing: 4, io: io)
        failure(.closeFailure, errno: EINTR) { try writer?.close() }
        try writer?.close()
        failure(.closed) { try writer?.writeRecord(Data([65]), deadline: io.clock) }
        writer = nil
        #expect(io.closeCount == 1)
    }

    @Test func initializationCleanupFailurePreservesOriginalError() {
        let io = RecordIOFixture(); io.type = mode_t(S_IFDIR); io.closeFailure = EINTR
        failure(.unsupportedDescriptor) { _ = try RecordWriter(borrowing: 4, io: io) }
        #expect(io.closeCount == 1)
    }

    @Test func deinitClosesReadyOrFailedWriterOnce() throws {
        let ready = RecordIOFixture()
        var writer: RecordWriter? = try RecordWriter(borrowing: 4, io: ready)
        #expect(writer != nil)
        writer = nil
        #expect(ready.closeCount == 1)
        let failed = RecordIOFixture()
        var second: RecordWriter? = try RecordWriter(borrowing: 4, io: failed)
        failure(.timedOut) { try second?.writeRecord(Data([65]), deadline: failed.clock) }
        second = nil
        #expect(failed.closeCount == 1)
    }

    @Test func readyPollStillChecksCancellationAndDeadlineBeforeWriting() throws {
        let expired = RecordIOFixture(); expired.type = mode_t(S_IFIFO); expired.pollAdvance = .seconds(1)
        let first = try RecordWriter(borrowing: 4, io: expired)
        failure(.timedOut) {
            try first.writeRecord(Data([65]), deadline: expired.clock.advanced(by: .milliseconds(1)))
        }
        #expect(expired.requests.isEmpty)
        let cancelled = RecordIOFixture(); cancelled.type = mode_t(S_IFIFO)
        let second = try RecordWriter(borrowing: 4, io: cancelled)
        failure(.cancelled) {
            try second.writeRecord(Data([65]), deadline: cancelled.clock.advanced(by: .seconds(1)),
                                   isCancelled: { !cancelled.pollTimeouts.isEmpty })
        }
        #expect(cancelled.requests.isEmpty)
    }

    @Test(arguments: [EPIPE, ECONNRESET, EIO])
    func socketWriteFailuresAreTerminal(_ code: Int32) throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFSOCK); io.steps = [.failure(code)]
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.writeFailure, errno: code) {
            try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        }
        failure(.previouslyFailed) { try writer.writeRecord(Data([65]), deadline: io.clock) }
    }

    @Test func misleadingReadinessCannotSpinUnboundedly() throws {
        let io = RecordIOFixture(); io.type = mode_t(S_IFSOCK)
        io.steps = Array(repeating: .failure(EAGAIN), count: 64)
        let writer = try RecordWriter(borrowing: 4, io: io)
        failure(.retryLimit, errno: EAGAIN) {
            try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)))
        }
        #expect(io.requests.count == 64)
        #expect(io.pollTimeouts.count == 63)
    }

    @Test func nativeDuplicationIsCloseOnExecAndPreservesOriginalFlags() throws {
        let original = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard original >= 0 else { Issue.record("could not open owned null descriptor"); return }
        defer { _ = Darwin.close(original) }
        let originalFlags = fcntl(original, F_GETFL)
        let descriptorFlags = fcntl(original, F_GETFD)
        let io = DarwinRecordWriterIO()
        let duplicate = try io.duplicate(original, minimum: 3).get()
        defer { _ = Darwin.close(duplicate) }
        #expect(duplicate >= 3 && duplicate != original)
        #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(original, F_GETFL) == originalFlags)
        #expect(fcntl(original, F_GETFD) == descriptorFlags)
    }

    @Test func reentrantCallsAreBusy() throws {
        let io = RecordIOFixture(); let writer = try RecordWriter(borrowing: 4, io: io)
        let result = RecordResultBox()
        try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)), isCancelled: {
            do { try writer.close() }
            catch let error as RecordWriterError { result.set(error) }
            catch { Issue.record("unexpected error type") }
            return false
        })
        #expect(result.value?.reason == .busy)
        #expect(result.value?.bytesWritten == 0)
        #expect(io.closeCount == 0)
    }

    @Test func overlappingCallDoesNotInterruptActiveOwner() throws {
        let io = RecordIOFixture(); let writer = try RecordWriter(borrowing: 4, io: io)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let result = RecordResultBox()
        let owner = Thread {
            defer { done.signal() }
            let outcome = Result { () throws(RecordWriterError) in
                try writer.writeRecord(Data([65]), deadline: io.clock.advanced(by: .seconds(1)), isCancelled: {
                    entered.signal()
                    return release.wait(timeout: .now() + 10) == .timedOut
                })
            }
            if case .failure(let error) = outcome { result.set(error) }
        }
        var completed = false
        defer {
            for _ in 0..<8 { release.signal() }
            if !completed {
                #expect(done.wait(timeout: .now() + 10) == .success, "owner did not finish during cleanup")
            }
        }
        // A dedicated thread avoids depending on the shared global queue under full-suite load.
        owner.start()
        guard entered.wait(timeout: .now() + 10) == .success else { Issue.record("owner did not enter callback"); return }
        failure(.busy) { try writer.close() }
        failure(.busy) { try writer.writeRecord(Data([66]), deadline: io.clock) }
        for _ in 0..<8 { release.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            Issue.record("owner did not finish"); return
        }
        completed = true
        #expect(result.value == nil)
        #expect(io.output == Data([65, 10]))
    }
}
