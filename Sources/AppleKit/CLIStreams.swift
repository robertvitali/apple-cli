import Foundation

/// A byte sink used by command output. Implementations must serialize concurrent writes.
public protocol OutputSink: Sendable {
    func write(_ data: Data)
}

/// The production sink. Write failures are intentionally ignored so a closed pipe remains a
/// clean CLI outcome, matching the pre-injection output behavior.
public final class FileHandleOutputSink: OutputSink, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    public init(_ handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ data: Data) {
        lock.withLock {
            try? handle.write(contentsOf: data)
        }
    }

    @discardableResult
    func writeRecord(_ data: Data, deadline: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            do {
                let writer = try RecordWriter(borrowing: handle.fileDescriptor)
                try writer.writeRecord(data, deadline: deadline)
                try writer.close()
                return true
            } catch {
                return false
            }
        }
    }
}

/// A lock-protected sink for deterministic command tests.
public final class MemoryOutputSink: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    public init() {}

    public func write(_ data: Data) {
        lock.withLock {
            buffer.append(data)
        }
    }

    public var data: Data {
        lock.withLock { buffer }
    }
}

/// Injectable stdout/stderr pair for a single command execution.
public struct CLIStreams: Sendable {
    public let stdout: any OutputSink
    public let stderr: any OutputSink

    public init(stdout: any OutputSink, stderr: any OutputSink) {
        self.stdout = stdout
        self.stderr = stderr
    }

    public static let standard = CLIStreams(
        stdout: FileHandleOutputSink(.standardOutput),
        stderr: FileHandleOutputSink(.standardError)
    )
}

enum ScopedCLIStreams {
    @TaskLocal static var current = CLIStreams.standard
}
