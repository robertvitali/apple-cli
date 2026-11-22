import Darwin

struct RecordWriterReadiness {
    let flags: Int16
    let capacity: Int
}

/// POLLOUT can report one free byte. A blocking atomic write must fit the space that is
/// actually available. Only the record writer may write to this stream during its lifetime.
final class RecordWriterPipeMonitor: Sendable {
    private let queue: Int32

    init(_ descriptor: Int32) throws(RecordWriterSystemError) {
        var queue = kqueue()
        guard queue >= 0 else { throw RecordWriterSystemError(code: errno) }
        if queue <= STDERR_FILENO {
            // Preserve closed standard streams for callers that subsequently open or redirect them.
            let duplicate = fcntl(queue, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            let failure = errno
            _ = close(queue)
            guard duplicate >= 0 else { throw RecordWriterSystemError(code: failure) }
            queue = duplicate
        }
        var change = kevent64_s()
        change.ident = UInt64(descriptor)
        change.filter = Int16(EVFILT_WRITE)
        change.flags = UInt16(EV_ADD)
        guard kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else {
            let failure = RecordWriterSystemError(code: errno)
            _ = close(queue)
            throw failure
        }
        self.queue = queue
    }

    deinit { _ = close(queue) }

    func wait(milliseconds: Int32) -> Result<RecordWriterReadiness?, RecordWriterSystemError> {
        var timeout = timespec(tv_sec: 0, tv_nsec: Int(milliseconds) * 1_000_000)
        var event = kevent64_s()
        let count = kevent64(queue, nil, 0, &event, 1, 0, &timeout)
        if count < 0 { return .failure(.init(code: errno)) }
        if count == 0 { return .success(nil) }
        if event.flags & UInt16(EV_ERROR) != 0 {
            return .failure(.init(code: Int32(exactly: event.data) ?? EIO))
        }
        if event.flags & UInt16(EV_EOF) != 0 {
            return .success(.init(flags: Int16(POLLHUP), capacity: 0))
        }
        guard event.filter == Int16(EVFILT_WRITE), let capacity = Int(exactly: event.data), capacity > 0 else {
            return .failure(.init(code: EIO))
        }
        return .success(.init(flags: Int16(POLLOUT), capacity: capacity))
    }
}
