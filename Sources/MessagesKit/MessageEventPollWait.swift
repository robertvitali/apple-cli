import Darwin
import Foundation

/// Waits between capture attempts without writing heartbeat records or polling the message database.
/// The caller keeps the output descriptor open and exclusively owned for the watch lifetime.
struct MessageEventPollWait {
    enum Failure: Error { case invalidOutput, outputClosed, monitorFailed }

    private let stream: Int32?

    init(output: Int32) throws {
        var info = stat()
        guard fstat(output, &info) == 0 else { throw Failure.invalidOutput }
        switch info.st_mode & S_IFMT {
        case S_IFIFO, S_IFSOCK: stream = output
        default: stream = nil
        }
    }

    func checkConnection() throws {
        guard let stream else { return }
        // A full pipe remains connected. A departed reader reports an error
        // even when no records are available for delivery.
        var observation = pollfd(fd: stream, events: Int16(POLLOUT), revents: 0)
        for _ in 0..<8 {
            let result = poll(&observation, 1, 0)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Failure.monitorFailed }
            if observation.revents & Int16(POLLNVAL) != 0 { throw Failure.invalidOutput }
            if observation.revents & Int16(POLLERR | POLLHUP) != 0 { throw Failure.outputClosed }
            return
        }
        throw Failure.monitorFailed
    }

    func wait(until deadline: ContinuousClock.Instant) throws {
        while true {
            try checkConnection()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            let sleep = stream == nil ? remaining : min(remaining, .seconds(1))
            let parts = sleep.components
            Thread.sleep(forTimeInterval: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
    }
}
