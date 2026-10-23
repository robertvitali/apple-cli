import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

private final class RecordWriterProbeMarker: NSObject {}
private enum RecordWriterProbeSetupError: Error { case failed }

@Suite("record writer isolated native descriptors")
struct RecordWriterNativeTests {
    private let scratch = ScratchDirs("record-writer-native")

    private struct ProbeRun {
        let status: Int32?
        let timedOut: Bool
        let observationFailed: Bool
        let cleanupFailed: Bool
        let stdout: String
        let stderr: String

        var exitCode: Int32? {
            guard let status, status & 0x7f == 0 else { return nil }
            return (status >> 8) & 0xff
        }
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw RecordWriterProbeSetupError.failed }
    }

    private func probeURL() throws -> URL {
        let bundle = Bundle(for: RecordWriterProbeMarker.self).bundleURL
        let url = bundle.deletingLastPathComponent().appendingPathComponent("RecordWriterProbe")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw RecordWriterProbeSetupError.failed
        }
        return url
    }

    private func openAboveStandard(_ path: String, flags: Int32) throws -> Int32 {
        let fd = open(path, flags | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecordWriterProbeSetupError.failed }
        if fd > STDERR_FILENO { return fd }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        let closed = Darwin.close(fd)
        guard moved >= 0, closed == 0 else {
            if moved >= 0 { _ = Darwin.close(moved) }
            throw RecordWriterProbeSetupError.failed
        }
        return moved
    }

    // Regular files eliminate pipe-drain deadlocks, including when a child dies by signal.
    // Read at most the fixed marker vocabulary's budget, even on a failing child.
    private func capture(_ fd: Int32) throws -> String {
        var information = stat()
        guard fstat(fd, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size >= 0, information.st_size <= 256 else {
            throw RecordWriterProbeSetupError.failed
        }
        var bytes = [UInt8](repeating: 0, count: 257)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0, count <= 256,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw RecordWriterProbeSetupError.failed
        }
        return text
    }

    private enum Observation { case running, interrupted, exited(Int32), gone, failed }

    private func observe(_ pid: pid_t) -> Observation {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .exited(status) }
        if result == 0 { return .running }
        if result == -1, errno == EINTR { return .interrupted }
        if result == -1, errno == ECHILD { return .gone }
        return .failed
    }

    private func runProbe(_ mode: String) throws -> ProbeRun {
        let executable = try probeURL()
        // Parent retains ownership of every fixture path, even after a signal exit.
        let root = try scratch.directory()
        var descriptors: [Int32] = []
        defer { for fd in descriptors { _ = Darwin.close(fd) } }
        func own(_ fd: Int32) -> Int32 { descriptors.append(fd); return fd }
        let input = own(try openAboveStandard("/dev/null", flags: O_RDONLY))
        let output = own(try openAboveStandard(root.appendingPathComponent("stdout").path,
                                              flags: O_RDWR | O_CREAT | O_EXCL))
        let error = own(try openAboveStandard(root.appendingPathComponent("stderr").path,
                                             flags: O_RDWR | O_CREAT | O_EXCL))

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t()
        var defaults = sigset_t()
        try check(sigemptyset(&mask))
        try check(sigfillset(&defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP |
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        for (source, destination) in [(input, STDIN_FILENO), (output, STDOUT_FILENO), (error, STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
            try check(posix_spawn_file_actions_addclose(&actions, source))
        }
        var argv = [executable.path, mode, root.path].map { strdup($0) }
        defer { argv.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw RecordWriterProbeSetupError.failed }
        argv.append(nil)
        var pid: pid_t = 0
        try check(argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, executable.path, &actions, &attributes, $0.baseAddress!, environ)
        })

        var ownsChild = true
        var status: Int32?
        var observationFailed = false
        var cleanupFailed = false
        var timedOut = false
        // There are no throwing operations between spawn and discharge/transfer of ownership.
        // Never signal after waitpid reaped the child or reported ECHILD.
        func update() -> Bool {
            guard ownsChild else { return false }
            switch observe(pid) {
            case .running: return true
            case .interrupted: return false
            case .exited(let value):
                status = value
                ownsChild = false
            case .gone:
                ownsChild = false
                observationFailed = true
            case .failed:
                observationFailed = true
            }
            return false
        }
        func wait(until deadline: ContinuousClock.Instant) {
            while ownsChild && ContinuousClock.now < deadline {
                _ = update()
                if ownsChild { usleep(5_000) }
            }
        }
        func signalOwnedGroup(_ signal: Int32) {
            guard update(), ownsChild, pid > 1, pid != getpgrp() else { return }
            if kill(-pid, signal) != 0, errno != ESRCH { cleanupFailed = true }
        }
        wait(until: ContinuousClock.now.advanced(by: .seconds(5)))
        _ = update()
        if ownsChild {
            timedOut = true
            signalOwnedGroup(SIGTERM)
            wait(until: ContinuousClock.now.advanced(by: .seconds(1)))
            _ = update()
            if ownsChild {
                signalOwnedGroup(SIGKILL)
                wait(until: ContinuousClock.now.advanced(by: .seconds(1)))
                _ = update()
            }
            if ownsChild {
                // Existing nonblocking fallback owns only this exact unreaped child, not a group.
                ownsChild = false
                ScriptEventualReaper.shared.accept(ScriptPendingReap(pid: pid, reaper: DarwinScriptProcessReaper()))
            }
        }
        return ProbeRun(status: status, timedOut: timedOut,
                        observationFailed: observationFailed, cleanupFailed: cleanupFailed,
                        stdout: try capture(output), stderr: try capture(error))
    }

    private func expectHealthy(_ run: ProbeRun) {
        #expect(!run.timedOut)
        #expect(!run.observationFailed)
        #expect(!run.cleanupFailed)
        #expect(run.exitCode == 0)
        #expect(run.stderr.isEmpty)
    }

    @Test("native signal policy, framing, backpressure and ownership", arguments: [
        "raw-pipe", "raw-fifo", "raw-socket-nosignal",
        "refuse-pipe", "refuse-socket",
        "closed-pipe", "closed-fifo", "closed-socket",
        "success-pipe", "success-fifo", "success-socket", "success-file", "success-null",
        "ignored-pipe", "ignored-socket",
        "full-pipe-timeout", "full-pipe-cancel",
        "full-fifo-timeout", "full-fifo-cancel",
        "full-socket-timeout", "full-socket-cancel", "close-reuse",
    ])
    func native(_ mode: String) throws {
        let result = try runProbe(mode)
        expectHealthy(result)
        #expect(result.stdout == "ok\n")
    }

    @Test("named FIFO partial-space reduction has explicit host evidence", arguments: [
        "partial-fifo-timeout", "partial-fifo-cancel", "partial-fifo-drain",
    ])
    func partialNamedFIFO(_ mode: String) throws {
        let result = try runProbe(mode)
        expectHealthy(result)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 {
            // Local macOS 27 is the validated threshold host; absence is not a silent pass.
            #expect(result.stdout == "exercised\n")
        } else {
            #expect(result.stdout == "exercised\n" || result.stdout == "threshold-unavailable\n")
        }
    }
}
