import Foundation
import Testing
@testable import AppleKit

@Suite("Scoped command streams")
struct OutputSinkTests {
    private struct Payload: Encodable {
        let value: String
    }

    private final class RecordingSink: OutputSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []

        func write(_ data: Data) {
            lock.withLock { stored.append(data) }
        }

        var writes: [Data] {
            lock.withLock { stored }
        }
    }

    @Test("scoped streams capture stdout and stderr without changing output bytes")
    func capturesBothStreams() throws {
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()

        try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
            try Output.emit(tool: "version", data: Payload(value: "sample"))
            Output.writeError(Data("diagnostic\n".utf8))
        }

        let expected = try Output.encodeSuccess(tool: "version", data: Payload(value: "sample"))
            + Data([0x0a])
        #expect(stdout.data == expected)
        #expect(stderr.data == Data("diagnostic\n".utf8))
    }

    @Test("task-local streams isolate concurrent command output")
    func concurrentIsolation() async {
        let first = MemoryOutputSink()
        let second = MemoryOutputSink()

        async let firstWrite: Void = Output.withStreams(
            CLIStreams(stdout: first, stderr: MemoryOutputSink())
        ) {
            await Task.yield()
            Output.printText("first")
        }
        async let secondWrite: Void = Output.withStreams(
            CLIStreams(stdout: second, stderr: MemoryOutputSink())
        ) {
            Output.printText("second")
            await Task.yield()
        }

        _ = await (firstWrite, secondWrite)
        #expect(first.data == Data("first\n".utf8))
        #expect(second.data == Data("second\n".utf8))
    }

    @Test("file-handle sink preserves raw bytes")
    func fileHandleSink() throws {
        let pipe = Pipe()
        let sink = FileHandleOutputSink(pipe.fileHandleForWriting)
        let expected = Data([0x00, 0x0a, 0x7f, 0xff])

        sink.write(expected)
        try pipe.fileHandleForWriting.close()

        #expect(pipe.fileHandleForReading.readDataToEndOfFile() == expected)
    }

    @Test("an encoded envelope and its trailing newline are one atomic sink write")
    func envelopeWriteIsAtomic() throws {
        let stdout = RecordingSink()

        try Output.withStreams(
            CLIStreams(stdout: stdout, stderr: MemoryOutputSink())
        ) {
            try Output.emit(tool: "version", data: Payload(value: "sample"))
        }

        let writes = stdout.writes
        #expect(writes.count == 1)
        #expect(writes.first?.last == 0x0a)
    }
}
