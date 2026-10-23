import Darwin
import Foundation

/// A fixed, value-free failure for one record attempt. Counts include the LF delimiter.
public struct RecordWriterError: Error, Sendable, Equatable {
    public enum Reason: String, Sendable {
        case invalidRecord, invalidDescriptor, unsupportedDescriptor, unsafeSignalPolicy
        case busy, closed, previouslyFailed, cancelled, timedOut
        case writeFailure, zeroProgress, retryLimit, closeFailure
    }

    public let reason: Reason
    public let systemErrno: Int32?
    public let bytesWritten: Int
}

/// Synchronously writes an unframed record followed by one LF to an exclusively owned stream.
///
/// The caller retains its descriptor; this object owns a close-on-exec duplicate. It does not change
/// caller-configurable descriptor flags or signal policy. Pipes and sockets require preexisting SIGPIPE
/// protection (SIG_IGN or F_GETNOSIGPIPE), which the caller must keep stable. Other writers to the
/// same stream are unsupported. Concurrent or reentrant calls fail with `busy`, rather than queue.
///
/// Cancellation and deadlines are cooperative. In particular, a blocking named FIFO can block
/// after reporting writable; regular-file and device writes can also delay cancellation. Callbacks
/// must return promptly. Success means that the local writes accepted the complete LF-terminated
/// frame, not that a consumer processed it or persisted it. After an accepted attempt fails, stop
/// using the stream: the writer refuses subsequent records, including after a zero-byte failure.
public final class RecordWriter: @unchecked Sendable {
    private enum State { case ready, failed, closed }
    private enum Kind { case fifo, socket, regular, character }
    private struct Prepared {
        let descriptor: Int32
        let kind: Kind
        let chunkLimit: Int
    }
    private struct Progress {
        var bytes = 0
        var transients = 0
        var fifoChunk: Int
    }

    // All mutable state and I/O-seam use are serialized by this gate. Deinit has exclusive ownership.
    private let lock = NSLock()
    private let io: any RecordWriterIO
    private let kind: Kind
    private let chunkLimit: Int
    private var descriptor: Int32?
    private var state = State.ready

    public convenience init(borrowing descriptor: Int32) throws(RecordWriterError) {
        try self.init(borrowing: descriptor, io: DarwinRecordWriterIO())
    }

    init(borrowing descriptor: Int32, io: any RecordWriterIO) throws(RecordWriterError) {
        let prepared = try Self.prepare(descriptor, io: io)
        self.io = io
        self.descriptor = prepared.descriptor
        self.kind = prepared.kind
        self.chunkLimit = prepared.chunkLimit
    }

    deinit {
        if let descriptor { _ = io.close(descriptor) }
    }

    /// Accepts 1...8 MiB with no raw CR or LF. Does not parse JSON or sanitize terminal controls.
    /// Invalid input leaves a ready writer usable. Every other accepted-attempt failure latches.
    public func writeRecord(_ record: Data, deadline: ContinuousClock.Instant,
                            isCancelled: @Sendable () -> Bool = { false }) throws(RecordWriterError) {
        guard lock.try() else { throw Self.error(.busy) }
        defer { lock.unlock() }
        guard state != .closed else { throw Self.error(.closed) }
        guard state != .failed else { throw Self.error(.previouslyFailed) }
        guard !record.isEmpty, record.count <= 8 * 1_024 * 1_024,
              !record.contains(0x0a), !record.contains(0x0d) else { throw Self.error(.invalidRecord) }
        guard let descriptor else { throw Self.error(.closed) }
        state = .failed
        var progress = Progress(fifoChunk: chunkLimit)
        // Foundation's Data closure has an untyped rethrows boundary. Preserve our concrete
        // error through a nonthrowing closure rather than casting an existential Error.
        let bodyResult: Result<Void, RecordWriterError> = record.withUnsafeBytes { bytes in
            Result { () throws(RecordWriterError) in
                try writeBuffer(bytes, descriptor: descriptor, deadline: deadline,
                                isCancelled: isCancelled, progress: &progress)
            }
        }
        try bodyResult.get()
        var newline: UInt8 = 0x0a
        try withUnsafeBytes(of: &newline) { (bytes: UnsafeRawBufferPointer) throws(RecordWriterError) in
            try writeBuffer(bytes, descriptor: descriptor, deadline: deadline,
                            isCancelled: isCancelled, progress: &progress)
        }
        // A completed frame remains a success even if cancellation arrives immediately afterwards.
        state = .ready
    }

    /// Closes the owned duplicate once. A close error still leaves this object closed; never retry
    /// close(2) after EINTR, since the descriptor slot may already have been released and reused.
    public func close() throws(RecordWriterError) {
        guard lock.try() else { throw Self.error(.busy) }
        defer { lock.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        state = .closed
        if case .failure(let failure) = io.close(descriptor) {
            throw Self.error(.closeFailure, errno: failure.code)
        }
    }

    private static func error(_ reason: RecordWriterError.Reason, errno: Int32? = nil,
                              bytes: Int = 0) -> RecordWriterError {
        .init(reason: reason, systemErrno: errno, bytesWritten: bytes)
    }

    private static func require<T>(_ result: Result<T, RecordWriterSystemError>,
                                   _ reason: RecordWriterError.Reason) throws(RecordWriterError) -> T {
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw error(reason, errno: failure.code)
        }
    }

    private static func prepare(_ original: Int32, io: any RecordWriterIO) throws(RecordWriterError) -> Prepared {
        let descriptor = try require(io.duplicate(original, minimum: STDERR_FILENO + 1), .invalidDescriptor)
        var accepted = false
        defer { if !accepted { _ = io.close(descriptor) } }
        let type = try require(io.fileType(descriptor), .invalidDescriptor)
        let flags = try require(io.statusFlags(descriptor), .invalidDescriptor)
        guard flags & O_ACCMODE == O_WRONLY || flags & O_ACCMODE == O_RDWR else {
            throw error(.invalidDescriptor)
        }
        let kind: Kind
        switch type {
        case mode_t(S_IFIFO): kind = .fifo
        case mode_t(S_IFSOCK): kind = .socket
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFCHR): kind = .character
        default: throw error(.unsupportedDescriptor)
        }
        if kind == .socket {
            guard try require(io.socketType(descriptor), .unsupportedDescriptor) == SOCK_STREAM else {
                throw error(.unsupportedDescriptor)
            }
        }
        if kind == .fifo || kind == .socket {
            let ignored = try require(io.ignoresSIGPIPE(), .unsafeSignalPolicy)
            if !ignored {
                guard try require(io.noSIGPIPE(descriptor), .unsafeSignalPolicy) != 0 else {
                    throw error(.unsafeSignalPolicy)
                }
            }
        }
        var limit = 4_096
        if kind == .fifo {
            let atomicLimit = try require(io.pipeAtomicLimit(descriptor), .unsupportedDescriptor)
            guard atomicLimit > 0 else { throw error(.unsupportedDescriptor) }
            limit = min(limit, atomicLimit)
        }
        accepted = true
        return Prepared(descriptor: descriptor, kind: kind, chunkLimit: limit)
    }

    @discardableResult
    private func checkpoint(deadline: ContinuousClock.Instant, isCancelled: @Sendable () -> Bool,
                            bytes: Int) throws(RecordWriterError) -> Duration {
        if isCancelled() { throw Self.error(.cancelled, bytes: bytes) }
        let remaining = io.now().duration(to: deadline)
        guard remaining > .zero else { throw Self.error(.timedOut, bytes: bytes) }
        return remaining
    }

    private func transient(_ code: Int32, progress: inout Progress) throws(RecordWriterError) {
        progress.transients += 1
        if progress.transients >= 64 {
            throw Self.error(.retryLimit, errno: code, bytes: progress.bytes)
        }
    }

    private func waitWritable(_ descriptor: Int32, deadline: ContinuousClock.Instant,
                              isCancelled: @Sendable () -> Bool,
                              progress: inout Progress) throws(RecordWriterError) {
        while true {
            let remaining = try checkpoint(deadline: deadline, isCancelled: isCancelled, bytes: progress.bytes)
            // Clamp before converting; a distant deadline must not overflow integer milliseconds.
            let milliseconds: Int32 = remaining >= .milliseconds(50) ? 50
                : Int32((remaining.components.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
            switch io.pollWritable(descriptor, milliseconds: milliseconds) {
            case .success(nil): continue
            case .success(let returned?):
                if returned & Int16(POLLNVAL) != 0 {
                    throw Self.error(kind == .character ? .unsupportedDescriptor : .invalidDescriptor,
                                     bytes: progress.bytes)
                }
                if returned & Int16(POLLERR | POLLHUP) != 0 {
                    throw Self.error(.writeFailure, bytes: progress.bytes)
                }
                guard returned & Int16(POLLOUT) != 0 else { throw Self.error(.writeFailure, bytes: progress.bytes) }
                return
            case .failure(let failure):
                if failure.code == EINTR { try transient(failure.code, progress: &progress); continue }
                let unsupported = kind == .character && (failure.code == ENODEV || failure.code == EOPNOTSUPP)
                throw Self.error(unsupported ? .unsupportedDescriptor : .writeFailure,
                                 errno: failure.code, bytes: progress.bytes)
            }
        }
    }

    private func writeBuffer(_ buffer: UnsafeRawBufferPointer, descriptor: Int32,
                             deadline: ContinuousClock.Instant, isCancelled: @Sendable () -> Bool,
                             progress: inout Progress) throws(RecordWriterError) {
        var offset = 0
        var needsPoll = false
        while offset < buffer.count {
            try checkpoint(deadline: deadline, isCancelled: isCancelled, bytes: progress.bytes)
            if kind == .fifo || needsPoll {
                try waitWritable(descriptor, deadline: deadline, isCancelled: isCancelled, progress: &progress)
            }
            try checkpoint(deadline: deadline, isCancelled: isCancelled, bytes: progress.bytes)
            let count = min(kind == .fifo ? progress.fifoChunk : chunkLimit, buffer.count - offset)
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + count)])
            let result = kind == .socket
                ? io.send(descriptor, bytes: bytes, flags: MSG_DONTWAIT | MSG_NOSIGNAL)
                : io.write(descriptor, bytes: bytes)
            needsPoll = false
            switch result {
            case .success(let written):
                guard written > 0 else { throw Self.error(.zeroProgress, bytes: progress.bytes) }
                // Native write/send cannot return more than requested. Keep an invalid internal
                // adapter from advancing offsets out of bounds or reporting a complete frame.
                guard written <= count else { throw Self.error(.writeFailure, bytes: progress.bytes) }
                offset += written
                progress.bytes += written
                progress.transients = 0
                progress.fifoChunk = chunkLimit
            case .failure(let failure):
                if failure.code == EINTR {
                    try transient(failure.code, progress: &progress)
                } else if failure.code == EAGAIN || failure.code == EWOULDBLOCK {
                    if kind == .fifo { progress.fifoChunk = max(1, count / 2) }
                    try transient(failure.code, progress: &progress)
                    needsPoll = true
                } else {
                    throw Self.error(.writeFailure, errno: failure.code, bytes: progress.bytes)
                }
            }
        }
    }
}

struct RecordWriterSystemError: Error, Sendable { let code: Int32 }

/// Internal syscall boundary; errors capture errno before any subsequent operation.
protocol RecordWriterIO: Sendable {
    func duplicate(_ descriptor: Int32, minimum: Int32) -> Result<Int32, RecordWriterSystemError>
    func fileType(_ descriptor: Int32) -> Result<mode_t, RecordWriterSystemError>
    func statusFlags(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError>
    func socketType(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError>
    func ignoresSIGPIPE() -> Result<Bool, RecordWriterSystemError>
    func noSIGPIPE(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError>
    func pipeAtomicLimit(_ descriptor: Int32) -> Result<Int, RecordWriterSystemError>
    func pollWritable(_ descriptor: Int32, milliseconds: Int32) -> Result<Int16?, RecordWriterSystemError>
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) -> Result<Int, RecordWriterSystemError>
    func send(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, flags: Int32) -> Result<Int, RecordWriterSystemError>
    func close(_ descriptor: Int32) -> Result<Void, RecordWriterSystemError>
    func now() -> ContinuousClock.Instant
}

struct DarwinRecordWriterIO: RecordWriterIO {
    private func result<T: FixedWidthInteger>(_ value: T) -> Result<T, RecordWriterSystemError> {
        value == -1 ? .failure(.init(code: errno)) : .success(value)
    }
    func duplicate(_ descriptor: Int32, minimum: Int32) -> Result<Int32, RecordWriterSystemError> {
        result(fcntl(descriptor, F_DUPFD_CLOEXEC, minimum))
    }
    func fileType(_ descriptor: Int32) -> Result<mode_t, RecordWriterSystemError> {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { return .failure(.init(code: errno)) }
        return .success(value.st_mode & mode_t(S_IFMT))
    }
    func statusFlags(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> {
        result(fcntl(descriptor, F_GETFL))
    }
    func socketType(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> {
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0 else {
            return .failure(.init(code: errno))
        }
        return .success(type)
    }
    func ignoresSIGPIPE() -> Result<Bool, RecordWriterSystemError> {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0 else { return .failure(.init(code: errno)) }
        let ignored = unsafeBitCast(current.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self)
            == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
        return .success(ignored)
    }
    func noSIGPIPE(_ descriptor: Int32) -> Result<Int32, RecordWriterSystemError> {
        result(fcntl(descriptor, F_GETNOSIGPIPE))
    }
    func pipeAtomicLimit(_ descriptor: Int32) -> Result<Int, RecordWriterSystemError> {
        errno = 0
        let value = fpathconf(descriptor, _PC_PIPE_BUF)
        let failure = errno
        return value == -1 && failure != 0 ? .failure(.init(code: failure)) : .success(value)
    }
    func pollWritable(_ descriptor: Int32, milliseconds: Int32) -> Result<Int16?, RecordWriterSystemError> {
        var descriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let count = poll(&descriptor, 1, milliseconds)
        if count == -1 { return .failure(.init(code: errno)) }
        return .success(count == 0 ? nil : descriptor.revents)
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) -> Result<Int, RecordWriterSystemError> {
        result(Darwin.write(descriptor, bytes.baseAddress, bytes.count))
    }
    func send(_ descriptor: Int32, bytes: UnsafeRawBufferPointer, flags: Int32) -> Result<Int, RecordWriterSystemError> {
        result(Darwin.send(descriptor, bytes.baseAddress, bytes.count, flags))
    }
    func close(_ descriptor: Int32) -> Result<Void, RecordWriterSystemError> {
        Darwin.close(descriptor) == 0 ? .success(()) : .failure(.init(code: errno))
    }
    func now() -> ContinuousClock.Instant { ContinuousClock().now }
}
