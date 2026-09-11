import Darwin
import Foundation

/// The descriptor boundary is also the resource-test seam. Implementations own any temporary
/// descriptors they create internally; each returned descriptor transfers to one launch session.
protocol ScriptProcessIO: Sendable {
    func pipe() throws -> (read: Int32, write: Int32)
    func nullInput() throws -> Int32
    func capture(in directory: URL) throws -> Int32
    func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int
    func captureSize(_ fd: Int32) throws -> off_t
    func captureSnapshot(_ fd: Int32, maximumBytes: Int?, configuredLimit: Int?) throws -> Data
    func close(_ fd: Int32) throws
}

struct DarwinScriptProcessIO: ScriptProcessIO {
    static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Capture syscall errors remain Cocoa read errors with their actual POSIX cause.
    /// This mapping is tested separately from propagation of an injected original error.
    static func captureError(_ code: Int32) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSUnderlyingErrorKey: posixError(code)])
    }

    private func prepared(_ fd: Int32) throws -> Int32 {
        guard fd >= 0 else { throw Self.posixError(errno) }
        if fd < 3 {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
            let failure = errno
            _ = Darwin.close(fd)
            guard moved >= 0 else { throw Self.posixError(failure) }
            return moved
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let failure = errno
            _ = Darwin.close(fd)
            throw Self.posixError(failure)
        }
        return fd
    }

    func pipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw Self.posixError(errno) }
        let input: Int32
        do { input = try prepared(descriptors[0]) }
        catch { _ = Darwin.close(descriptors[1]); throw error }
        do { return (input, try prepared(descriptors[1])) }
        catch { _ = Darwin.close(input); throw error }
    }

    func nullInput() throws -> Int32 { try prepared(open("/dev/null", O_RDONLY | O_CLOEXEC)) }

    func capture(in directory: URL) throws -> Int32 {
        var template = Array(directory.appendingPathComponent("apple-cli-osascript.XXXXXX").path.utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else {
            throw AppleScriptRunner.RunError.launchFailed("cannot create private output capture")
        }
        guard template.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0 else {
            _ = Darwin.close(fd)
            throw AppleScriptRunner.RunError.launchFailed("cannot unlink private output capture")
        }
        return try prepared(fd)
    }

    func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Darwin.read(fd, buffer.baseAddress, buffer.count)
        guard count >= 0 else { throw Self.posixError(errno) }
        return count
    }

    func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int {
        let count = Darwin.write(fd, buffer.baseAddress, buffer.count)
        guard count >= 0 else { throw Self.posixError(errno) }
        return count
    }

    func captureSize(_ fd: Int32) throws -> off_t {
        var information = stat()
        guard fstat(fd, &information) == 0 else { throw Self.captureError(errno) }
        return information.st_size
    }

    func captureSnapshot(_ fd: Int32, maximumBytes: Int? = nil, configuredLimit: Int? = nil) throws -> Data {
        let length = try captureSize(fd)
        if let maximumBytes {
            precondition(maximumBytes >= 0)
            // The second stream can have zero allowance left; report the original
            // positive invocation limit rather than that smaller remaining allowance.
            let original = configuredLimit ?? maximumBytes
            precondition(original > 0)
            guard length <= off_t(maximumBytes) else {
                throw ScriptOutputLimitExceeded(maximumOutputBytes: original)
            }
        }
        var result = Data()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Never seek the shared open-file description or chase a descendant's later appends.
        while offset < length {
            let count: Int
            do {
                count = try buffer.withUnsafeMutableBytes {
                    try Self.captureRead(fd, into: UnsafeMutableRawBufferPointer(rebasing: $0[..<min($0.count, Int(length - offset))]), offset: offset)
                }
            } catch {
                if (error as NSError).userInfo[NSUnderlyingErrorKey].map({ ($0 as? NSError)?.code == Int(EINTR) }) == true { continue }
                throw error
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
        return result
    }

    static func captureRead(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, offset: off_t) throws -> Int {
        let count = pread(fd, buffer.baseAddress, buffer.count, offset)
        guard count >= 0 else { throw captureError(errno) }
        return count
    }

    func close(_ fd: Int32) throws {
        // Do not retry close: a descriptor number may already have become available for reuse.
        guard Darwin.close(fd) == 0 else { throw Self.posixError(errno) }
    }
}

/// Reaping is intentionally a separate capability: a deferred obligation has no descriptors
/// and cannot send signals. A synthetic implementation must never forward fictional IDs to OS APIs.
protocol ScriptProcessReaping: Sendable {
    func reap(_ pid: pid_t) throws -> Bool
}

protocol ScriptProcessChildren: Sendable {
    var reaper: any ScriptProcessReaping { get }
    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t
    func observe(_ pid: pid_t) throws -> Int32?
    func signal(group: pid_t, signal: Int32) throws
}

struct DarwinScriptProcessReaper: ScriptProcessReaping {
    func reap(_ pid: pid_t) throws -> Bool {
        var information = siginfo_t()
        guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG) == 0 else {
            if errno == EINTR { return false }
            throw DarwinScriptProcessIO.posixError(errno)
        }
        return information.si_pid == pid
    }
}

struct DarwinScriptProcessChildren: ScriptProcessChildren {
    let reaper: any ScriptProcessReaping = DarwinScriptProcessReaper()

    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
        // WNOWAIT is meaningful only with exclusive reaping. Do not change the host's policy.
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0 else {
            throw DarwinScriptProcessIO.posixError(errno)
        }
        let ignored = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self) == 1
        guard !ignored, action.sa_flags & SA_NOCLDWAIT == 0 else {
            throw AppleScriptRunner.RunError.launchFailed("SIGCHLD auto-reaping prevents owned child cleanup")
        }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        func check(_ code: Int32) throws {
            guard code == 0 else { throw DarwinScriptProcessIO.posixError(code) }
        }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        // Measured against Foundation Process on both supported local Swift toolchains.
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP |
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        for (source, destination) in [(input, STDIN_FILENO), (output, STDOUT_FILENO), (error, STDERR_FILENO)] {
            // Allocations are moved above 2 before any action is assembled.
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
            try check(posix_spawn_file_actions_addclose(&actions, source))
        }
        let strings = [invocation.executablePath] + invocation.arguments
        var argv = strings.map { strdup($0) }
        defer { for pointer in argv { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw DarwinScriptProcessIO.posixError(ENOMEM) }
        argv.append(nil)
        var pid: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, invocation.executablePath, &actions, &attributes, $0.baseAddress!, environ)
        }
        try check(code) // posix_spawn returns the error number; errno is unrelated.
        return pid
    }

    func observe(_ pid: pid_t) throws -> Int32? {
        var information = siginfo_t()
        guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            if errno == EINTR { return nil }
            throw DarwinScriptProcessIO.posixError(errno)
        }
        guard information.si_pid != 0 else { return nil }
        guard information.si_pid == pid,
              [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(information.si_code) else {
            throw DarwinScriptProcessIO.posixError(EIO)
        }
        // Foundation reports the signal number itself, not shell-style 128 + signal.
        return information.si_status
    }

    func signal(group: pid_t, signal: Int32) throws {
        guard group > 1, group != getpgrp() else { throw DarwinScriptProcessIO.posixError(EINVAL) }
        guard kill(-group, signal) == 0 else { throw DarwinScriptProcessIO.posixError(errno) }
    }
}

final class ScriptPendingReap: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let reaper: any ScriptProcessReaping
    private var finished = false

    init(pid: pid_t, reaper: any ScriptProcessReaping) {
        self.pid = pid
        self.reaper = reaper
    }

    /// True means the obligation is consumed, including when another owner already reaped it.
    func poll() -> Bool {
        lock.withLock {
            if finished { return true }
            do { finished = try reaper.reap(pid) }
            catch { if (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ECHILD) { finished = true } }
            return finished
        }
    }
}

protocol ScriptDeferredReaping: Sendable {
    func accept(_ pending: ScriptPendingReap)
}

/// One shared nonblocking registry, with no per-invocation worker or retained I/O resources.
final class ScriptEventualReaper: ScriptDeferredReaping, @unchecked Sendable {
    static let shared = ScriptEventualReaper()
    private let queue = DispatchQueue(label: "apple-cli.osascript.eventual-reap")
    private var pending: [ScriptPendingReap] = []
    private var timer: DispatchSourceTimer?

    /// Synchronized registry state for lifecycle tests; this does not count runtime threads.
    var isIdle: Bool { queue.sync { pending.isEmpty && timer == nil } }

    func accept(_ obligation: ScriptPendingReap) {
        queue.async { [self] in
            pending.append(obligation)
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(100))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.pending.removeAll { $0.poll() }
                if self.pending.isEmpty {
                    self.timer?.cancel()
                    self.timer = nil
                }
            }
            timer = source
            source.resume()
        }
    }
}

struct ScriptProcessDependencies: Sendable {
    var io: any ScriptProcessIO = DarwinScriptProcessIO()
    var children: any ScriptProcessChildren = DarwinScriptProcessChildren()
    var deferred: any ScriptDeferredReaping = ScriptEventualReaper.shared
}

/// One calling thread owns every pipe. WNOWAIT reserves the root's identity until the last
/// possible group signal, including failures encountered while reading completed captures.
/// Exclusive reaping is a library precondition; ECHILD revokes authority. This is not a pidfd
/// defense against an arbitrary concurrent foreign waitpid(-1) consumer.
final class OwnedScriptProcess {
    private let dependencies: ScriptProcessDependencies
    private var descriptors = Set<Int32>()
    private var pid: pid_t?
    private var ownsChild = false
    private var observedStatus: Int32?
    private var maySignal = true

    init(dependencies: ScriptProcessDependencies) { self.dependencies = dependencies }

    private func keep(_ descriptor: Int32) -> Int32 {
        descriptors.insert(descriptor)
        return descriptor
    }

    private func close(_ descriptor: Int32) throws {
        guard descriptors.remove(descriptor) != nil else { return }
        try dependencies.io.close(descriptor)
    }

    private func closeAll() {
        for descriptor in Array(descriptors) { try? close(descriptor) }
    }

    private func pipe() throws -> (read: Int32, write: Int32) {
        let pair = try dependencies.io.pipe()
        return (keep(pair.read), keep(pair.write))
    }

    private func nonblocking(_ descriptor: Int32, noSigpipe: Bool = false) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DarwinScriptProcessIO.posixError(errno)
        }
        if noSigpipe, fcntl(descriptor, F_SETNOSIGPIPE, 1) != 0 {
            throw AppleScriptRunner.RunError.launchFailed("could not arm the stdin pipe against SIGPIPE: errno \(errno)")
        }
    }

    private func observe() throws {
        guard ownsChild, let pid else { return }
        do {
            if let status = try dependencies.children.observe(pid) { observedStatus = status }
        } catch {
            maySignal = false
            if Self.isErrno(error, ECHILD) { ownsChild = false }
            throw error
        }
    }

    private static func isErrno(_ error: any Error, _ code: Int32) -> Bool {
        let value = error as NSError
        return value.domain == NSPOSIXErrorDomain && value.code == Int(code)
    }

    private static func retryable(_ error: any Error) -> Bool {
        isErrno(error, EAGAIN) || isErrno(error, EINTR)
    }

    private func reap() throws -> Bool {
        guard ownsChild, let pid else { return true }
        do {
            if try dependencies.children.reaper.reap(pid) {
                ownsChild = false
                maySignal = false
                return true
            }
            return false
        } catch {
            maySignal = false
            if Self.isErrno(error, ECHILD) { ownsChild = false }
            throw error
        }
    }

    private func transferReap() {
        guard ownsChild, let pid else { return }
        ownsChild = false
        maySignal = false
        dependencies.deferred.accept(ScriptPendingReap(pid: pid, reaper: dependencies.children.reaper))
    }

    private func signal(_ number: Int32) {
        guard ownsChild, maySignal, let pid, pid > 1, pid != getpgrp() else { return }
        // Revalidate wait ownership even when the root's exit was already observed.
        do { try observe() } catch { return }
        guard ownsChild, maySignal else { return }
        try? dependencies.children.signal(group: pid, signal: number)
    }

    private func pause(until deadline: DispatchTime) {
        while DispatchTime.now() < deadline, ownsChild {
            do { try observe() } catch { return }
            // Root exit does not prove that inheriting descendants stopped.
            _ = poll(nil, 0, 10)
        }
    }

    private func cancel(timeout: Bool) {
        signal(SIGTERM)
        pause(until: .now() + (timeout ? 1.0 : 0.5))
        signal(SIGKILL)
        // Group signalling is finished. No wait below can be followed by another signal.
        maySignal = false
        let deadline = DispatchTime.now() + 1.0
        while ownsChild {
            do { if try reap() { break } } catch { break }
            if DispatchTime.now() >= deadline { break }
            _ = poll(nil, 0, 10)
        }
        closeAll()
        transferReap()
    }

    func launch(_ invocation: ScriptInvocation, captureDirectory: URL) throws -> ScriptOutcome {
        defer { closeAll() }
        let seconds: TimeInterval?
        let script: Data?
        let usesCaptures: Bool
        switch invocation.delivery {
        case .inline: (seconds, script, usesCaptures) = (nil, nil, false)
        case .timed(let value): (seconds, script, usesCaptures) = (value, nil, true)
        case .stdin(let value): (seconds, script, usesCaptures) = (nil, Data(value.utf8), false)
        case .timedStdin(let value, let bound): (seconds, script, usesCaptures) = (bound, Data(value.utf8), false)
        }
        let childInput: Int32
        var writer: Int32?
        let childOutput: Int32
        let childError: Int32
        var outputReader: Int32?
        var errorReader: Int32?
        do {
            if script != nil {
                let input = try pipe()
                childInput = input.read
                writer = input.write
                try nonblocking(input.write, noSigpipe: true)
            } else { childInput = keep(try dependencies.io.nullInput()) }
            if usesCaptures {
                childOutput = keep(try dependencies.io.capture(in: captureDirectory))
                childError = keep(try dependencies.io.capture(in: captureDirectory))
            } else {
                let output = try pipe()
                let error = try pipe()
                (outputReader, childOutput) = (output.read, output.write)
                (errorReader, childError) = (error.read, error.write)
                try nonblocking(output.read)
                try nonblocking(error.read)
            }
            pid = try dependencies.children.spawn(invocation, input: childInput, output: childOutput, error: childError)
            ownsChild = true
        } catch let error as AppleScriptRunner.RunError { throw error }
        catch { throw AppleScriptRunner.RunError.launchFailed(String(describing: error)) }

        // Timing begins after successful spawn, as in the existing Foundation launcher.
        let deadline = seconds.map { DispatchTime.now() + $0 }
        do {
            try close(childInput)
            if !usesCaptures { try close(childOutput); try close(childError) }
            var output = Data()
            var errorOutput = Data()
            var written = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let writerFD = writer, written == script?.count {
                    do { try close(writerFD); writer = nil }
                    catch { throw Self.deliveryFailure(error) }
                }
                do { try observe() }
                catch { throw AppleScriptRunner.RunError.launchFailed("could not observe osascript: \(error)") }
                // An observation may itself return after expiry. Completion must be known
                // inside the bound; newly observed success cannot erase an elapsed deadline.
                if let deadline, DispatchTime.now() >= deadline {
                    throw AppleScriptRunner.TimeoutError(seconds: seconds!)
                }
                if usesCaptures, let limit = invocation.maximumOutputBytes {
                    let outputSize = try dependencies.io.captureSize(childOutput)
                    guard outputSize <= off_t(limit) else {
                        throw ScriptOutputLimitExceeded(maximumOutputBytes: limit)
                    }
                    let errorSize = try dependencies.io.captureSize(childError)
                    guard errorSize <= off_t(limit) - outputSize else {
                        throw ScriptOutputLimitExceeded(maximumOutputBytes: limit)
                    }
                }
                if observedStatus != nil, writer == nil,
                   usesCaptures || (outputReader == nil && errorReader == nil) { break }
                var polls: [pollfd] = []
                if let outputReader { polls.append(pollfd(fd: outputReader, events: Int16(POLLIN), revents: 0)) }
                if let errorReader { polls.append(pollfd(fd: errorReader, events: Int16(POLLIN), revents: 0)) }
                if let writer { polls.append(pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)) }
                let remaining = deadline.map { max(0, Double($0.uptimeNanoseconds) - Double(DispatchTime.now().uptimeNanoseconds)) / 1_000_000 }
                let milliseconds = Int32(min(10, remaining.map { $0.rounded(.up) } ?? 10))
                let ready = polls.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), milliseconds) }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw AppleScriptRunner.RunError.launchFailed("could not poll osascript: errno \(errno)")
                }
                for event in polls where event.revents != 0 {
                    // One chunk per descriptor per turn; a producer cannot postpone the deadline.
                    if let deadline, DispatchTime.now() >= deadline {
                        throw AppleScriptRunner.TimeoutError(seconds: seconds!)
                    }
                    if event.fd == writer {
                        do {
                            let count = try script!.withUnsafeBytes { raw in
                                try dependencies.io.write(event.fd, from: UnsafeRawBufferPointer(rebasing: raw[written..<min(raw.count, written + buffer.count)]))
                            }
                            if count == 0 { throw DarwinScriptProcessIO.posixError(EIO) }
                            written += count
                        } catch {
                            if Self.retryable(error) { continue }
                            throw Self.deliveryFailure(error)
                        }
                    } else {
                        let label = script == nil ? (event.fd == outputReader ? "stdout" : "piped-stderr") :
                            (event.fd == outputReader ? "stdin-form-stdout" : "stdin-form-stderr")
                        let allowance = invocation.maximumOutputBytes.map { $0 - output.count - errorOutput.count }
                        // Branch before adding one, so Int.max never overflows. One excess
                        // byte distinguishes EOF from overflow when the allowance is zero.
                        let request = allowance.map { $0 < buffer.count ? $0 + 1 : buffer.count } ?? buffer.count
                        let count: Int
                        do {
                            count = try buffer.withUnsafeMutableBytes {
                                try dependencies.io.read(event.fd, into: UnsafeMutableRawBufferPointer(rebasing: $0[..<request]))
                            }
                            if count == 0 {
                                try close(event.fd)
                                if event.fd == outputReader { outputReader = nil } else { errorReader = nil }
                            }
                        } catch {
                            if Self.retryable(error) { continue }
                            throw OsascriptLauncher.outputReadFailure(label, error)
                        }
                        // A policy error is not a POSIX read failure and must never acquire
                        // launchFailed classification or retain the detection byte.
                        if let allowance, count > allowance {
                            throw ScriptOutputLimitExceeded(maximumOutputBytes: invocation.maximumOutputBytes!)
                        }
                        if event.fd == outputReader { output.append(contentsOf: buffer.prefix(count)) }
                        else { errorOutput.append(contentsOf: buffer.prefix(count)) }
                    }
                }
            }
            if usesCaptures {
                // Hold the root waitable across BOTH reads; preserve a raw capture error.
                let limit = invocation.maximumOutputBytes
                output = try dependencies.io.captureSnapshot(childOutput, maximumBytes: limit, configuredLimit: limit)
                errorOutput = try dependencies.io.captureSnapshot(childError,
                    maximumBytes: limit.map { $0 - output.count }, configuredLimit: limit)
            }
            let outcome = ScriptOutcome(terminationStatus: observedStatus!, standardOutput: output, standardError: errorOutput)
            maySignal = false
            do {
                let reapDeadline = DispatchTime.now() + 1.0
                while !(try reap()) {
                    if DispatchTime.now() >= reapDeadline {
                        closeAll()
                        transferReap()
                        break
                    }
                    _ = poll(nil, 0, 10)
                }
            } catch {
                closeAll()
                transferReap()
                throw AppleScriptRunner.RunError.launchFailed("could not reap osascript: \(error)")
            }
            return outcome
        } catch {
            cancel(timeout: error is AppleScriptRunner.TimeoutError)
            throw error
        }
    }

    private static func deliveryFailure(_ error: any Error) -> AppleScriptRunner.RunError {
        .launchFailed("could not deliver script on stdin: \(String(describing: error))")
    }
}
