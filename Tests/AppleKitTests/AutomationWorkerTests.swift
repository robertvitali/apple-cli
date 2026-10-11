import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

private final class AutomationWorkerMarker: NSObject {}

@Suite("bounded same-executable automation worker", .serialized)
struct AutomationWorkerTests {
    private let scratch = ScratchDirs("worker-prototype")

    private func probeURL() throws -> URL {
        let bundle = Bundle(for: AutomationWorkerMarker.self).bundleURL
        let candidate = bundle.deletingLastPathComponent().appendingPathComponent("AutomationWorkerProbe")
        #expect(FileManager.default.isExecutableFile(atPath: candidate.path))
        return candidate
    }

    private func digest(_ value: String) throws -> AppleAutomationJournal.TargetDigest {
        try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: value)
    }

    private func operationRequest(_ seed: String = "one") throws -> AppleAutomationJournal.OperationRequest {
        try AppleAutomationJournal.OperationRequest(
            operationType: .reactionSet,
            conversationDigest: digest("conversation-\(seed)"),
            messageDigest: digest("message-\(seed)"),
            partDigest: digest("part-\(seed)"),
            minimumEvidence: .init(targetHash: digest("evidence-\(seed)"), targetLength: 12)
        )
    }

    private func command(_ name: String) throws -> WorkerCommand { try WorkerCommand(name: name) }

    private func launch(root: URL, command name: String = "probe.empty", seed: String = "one", deadline: UInt64 = 2_000,
                        launcher: WorkerLauncher = WorkerLauncher()) throws -> WorkerLaunchOutcome {
        try launcher.launch(WorkerLaunchRequest.makeForTesting(
            command: command(name),
            journalRequest: operationRequest(seed),
            deadline: .millisecondsFromNow(deadline),
            stateRoot: root.path
        ))
    }

    private struct ProbeRun {
        let status: Int32?
        let timedOut: Bool
        let stdout: String
        let stderr: String

        var exitCode: Int32? {
            guard let status, status & 0x7f == 0 else { return nil }
            return (status >> 8) & 0xff
        }
    }

    private final class DescriptorSet {
        private var owned = Set<Int32>()

        func insert(_ fd: Int32) -> Int32 {
            if fd >= 0 { owned.insert(fd) }
            return fd
        }

        func close(_ fd: Int32) {
            if owned.remove(fd) != nil { Darwin.close(fd) }
        }

        func closeAll() {
            for fd in Array(owned) { close(fd) }
        }
    }

    private struct NullInputFailingIO: ScriptProcessIO {
        private let base = DarwinScriptProcessIO()
        func pipe() throws -> (read: Int32, write: Int32) { try base.pipe() }
        func nullInput() throws -> Int32 { throw DarwinScriptProcessIO.posixError(EIO) }
        func capture(in directory: URL) throws -> Int32 { try base.capture(in: directory) }
        func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int { try base.read(fd, into: buffer) }
        func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, from: buffer) }
        func captureSize(_ fd: Int32) throws -> off_t { try base.captureSize(fd) }
        func captureSnapshot(_ fd: Int32, maximumBytes: Int?, configuredLimit: Int?) throws -> Data {
            try base.captureSnapshot(fd, maximumBytes: maximumBytes, configuredLimit: configuredLimit)
        }
        func close(_ fd: Int32) throws { try base.close(fd) }
    }

    private func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    private func drain(_ fd: Int32, into data: inout Data, cap: Int = 64 * 1024) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var reads = 0
        while reads < 32 {
            reads += 1
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 0)
            guard ready > 0, p.revents & Int16(POLLIN) != 0 else { return }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= cap else {
                    throw NSError(domain: "AutomationWorkerProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "probe output exceeded cap"])
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            else { return }
        }
    }

    private enum ReapResult {
        case running
        case exited(Int32)
        case unavailable
    }

    private func reap(_ pid: pid_t) -> ReapResult {
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return .exited(status) }
            if waited == 0 { return .running }
            if errno == EINTR { continue }
            return .unavailable
        }
    }

    private func runProbe(_ arguments: [String], timeout: Double = 5.0) throws -> ProbeRun {
        let executable = try probeURL()
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        func check(_ code: Int32, _ step: String) throws {
            guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: step]) }
        }
        try check(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions), "spawn actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal defaults")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "process group")
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)), "spawn flags")

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        let descriptors = DescriptorSet()
        defer { descriptors.closeAll() }
        guard pipe(&stdoutPipe) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        stdoutPipe[0] = descriptors.insert(stdoutPipe[0])
        stdoutPipe[1] = descriptors.insert(stdoutPipe[1])
        guard pipe(&stderrPipe) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        stderrPipe[0] = descriptors.insert(stderrPipe[0])
        stderrPipe[1] = descriptors.insert(stderrPipe[1])
        let null = descriptors.insert(open("/dev/null", O_RDONLY | O_CLOEXEC))
        guard null >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        setNonblocking(stdoutPipe[0])
        setNonblocking(stderrPipe[0])
        try check(posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO), "stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO), "stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO), "stderr")
        let strings = ([executable.path] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings
        argv.append(nil)
        var pid: pid_t = 0
        let path = executable.path
        try check(argv.withUnsafeMutableBufferPointer { posix_spawn(&pid, path, &actions, &attributes, $0.baseAddress!, environ) }, "spawn")
        descriptors.close(stdoutPipe[1]); stdoutPipe[1] = -1
        descriptors.close(stderrPipe[1]); stderrPipe[1] = -1

        let deadline = DispatchTime.now() + timeout
        var stdout = Data()
        var stderr = Data()
        var status: Int32?
        var timedOut = false
        var transferredReap = false
        func transferReapIfNeeded() {
            guard status == nil, !transferredReap, pid > 1 else { return }
            transferredReap = true
            ScriptEventualReaper.shared.accept(ScriptPendingReap(pid: pid, reaper: DarwinScriptProcessReaper()))
        }
        while true {
            try drain(stdoutPipe[0], into: &stdout)
            try drain(stderrPipe[0], into: &stderr)
            switch reap(pid) {
            case .exited(let observed): status = observed
            case .unavailable: timedOut = true
            case .running: break
            }
            if status != nil || timedOut && DispatchTime.now() < deadline { break }
            if DispatchTime.now() >= deadline {
                timedOut = true
                if case .running = reap(pid), pid > 1, pid != getpgrp() { kill(-pid, SIGTERM) }
                let term = DispatchTime.now() + 1.0
                while status == nil && DispatchTime.now() < term {
                    try drain(stdoutPipe[0], into: &stdout)
                    try drain(stderrPipe[0], into: &stderr)
                    switch reap(pid) {
                    case .exited(let observed): status = observed
                    case .unavailable: break
                    case .running: usleep(10_000)
                    }
                }
                if status == nil, case .running = reap(pid), pid > 1, pid != getpgrp() { kill(-pid, SIGKILL) }
                let killDeadline = DispatchTime.now() + 1.0
                while status == nil && DispatchTime.now() < killDeadline {
                    try drain(stdoutPipe[0], into: &stdout)
                    try drain(stderrPipe[0], into: &stderr)
                    switch reap(pid) {
                    case .exited(let observed): status = observed
                    case .unavailable: break
                    case .running: usleep(10_000)
                    }
                }
                if status == nil { transferReapIfNeeded() }
                break
            }
            usleep(10_000)
        }
        try drain(stdoutPipe[0], into: &stdout)
        try drain(stderrPipe[0], into: &stderr)
        return ProbeRun(status: status, timedOut: timedOut,
                        stdout: String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func launchThroughProbeParent(root: URL, command name: String = "probe.empty", seed: String = "one",
                                          deadline: UInt64 = 2_000, mode: String = "normal") throws -> String {
        let result = try runProbe(["--parent-run", mode, root.path, name, seed, String(deadline)])
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        return result.stdout
    }

    private func launchObservedThroughProbe(root: URL, command name: String, seed: String = "observed") throws -> String {
        let result = try runProbe(["--observed-run", root.path, name, seed])
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        return result.stdout
    }

    private func directProtocolOutcome(_ mode: String, scratchRoot: URL? = nil) throws -> String {
        var arguments = ["--direct-protocol", mode]
        if let scratchRoot { arguments.append(scratchRoot.path) }
        let result = try runProbe(arguments)
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        return result.stdout
    }

    @Test("worker frame reader rejects malformed partial oversize and trailing frames")
    func frameReaderRejectsBadFrames() throws {
        let io = DarwinScriptProcessIO()
        let partial = try io.pipe()
        try Data([0, 0, 0, 8, 1, 2]).withUnsafeBytes { _ = try io.write(partial.write, from: $0) }
        try io.close(partial.write)
        do {
            _ = try WorkerFrameIO.readOneFrameThenEOF(from: partial.read, cap: 16, io: io, deadline: .millisecondsFromNow(500))
            Issue.record("partial frame should fail")
        } catch WorkerProtocolError.truncatedFrame {}
        try? io.close(partial.read)

        let oversize = try io.pipe()
        try Data([0, 0, 0, 17]).withUnsafeBytes { _ = try io.write(oversize.write, from: $0) }
        try io.close(oversize.write)
        do {
            _ = try WorkerFrameIO.readOneFrameThenEOF(from: oversize.read, cap: 16, io: io, deadline: .millisecondsFromNow(500))
            Issue.record("oversize frame should fail")
        } catch WorkerProtocolError.frameTooLarge {}
        try? io.close(oversize.read)

        let trailing = try io.pipe()
        try Data([0, 0, 0, 1, 7, 9]).withUnsafeBytes { _ = try io.write(trailing.write, from: $0) }
        try io.close(trailing.write)
        do {
            _ = try WorkerFrameIO.readOneFrameThenEOF(from: trailing.read, cap: 16, io: io, deadline: .millisecondsFromNow(500))
            Issue.record("trailing bytes after one frame should fail")
        } catch WorkerProtocolError.malformedFrame {}
        try? io.close(trailing.read)
    }

    @Test("worker response decoding sanitizes optional detail and accepts legacy frames")
    func workerResponseDecodingSanitizesOptionalDetail() throws {
        let operationID = UUID()
        let nonce = UUID()
        func json(_ detail: String?) -> Data {
            var object: [String: Any] = [
                "schemaVersion": 1,
                "operationID": operationID.uuidString,
                "nonce": nonce.uuidString,
                "category": "refused"
            ]
            if let detail { object["detail"] = detail }
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        let legacy = try JSONDecoder().decode(WorkerResponse.self, from: json(nil))
        #expect(legacy.detail == nil)
        #expect(legacy.failureReason == "refused")

        let valid = try JSONDecoder().decode(WorkerResponse.self, from: json("target-drift"))
        #expect(valid.detail == "target-drift")
        #expect(valid.failureReason == "target-drift")

        for privateLookingDetail in ["unsafe detail", "555-0100", "Alice", "token_ABC123"] {
            let unsafe = try JSONDecoder().decode(WorkerResponse.self, from: json(privateLookingDetail))
            #expect(unsafe.detail == nil)
            #expect(unsafe.failureReason == "refused")
        }

        let encodedUnsafe = WorkerResponse(schemaVersion: 1, operationID: operationID, nonce: nonce,
                                           category: .refused, detail: "unsafe detail")
        #expect(encodedUnsafe.detail == nil)
        #expect(!String(decoding: try JSONEncoder().encode(encodedUnsafe), as: UTF8.self).contains("unsafe detail"))
    }

    @Test("response reader waits for EOF so ACK then hang times out")
    func ackThenHangTimesOutBeforeAcceptingFrame() throws {
        let io = DarwinScriptProcessIO()
        let pair = try io.pipe()
        defer { try? io.close(pair.read); try? io.close(pair.write) }
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack)
        try WorkerFrameIO.writeFrame(try JSONEncoder().encode(response), to: pair.write, cap: WorkerFrameIO.responseCap, io: io, deadline: .millisecondsFromNow(500))
        do {
            _ = try WorkerFrameIO.readOneFrameThenEOF(from: pair.read, cap: WorkerFrameIO.responseCap, io: io, deadline: .millisecondsFromNow(100))
            Issue.record("ACK without EOF should not be accepted")
        } catch WorkerProtocolError.deadlineExpired {}
    }

    @Test("same executable parent mode can launch one hidden-fd worker and receive an ACK")
    func sameExecutableParentLaunchesWorker() throws {
        let result = try runProbe(["--parent", "empty", try scratch.directory().path])
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
    }

    @Test("worker sentinel refuses standalone malformed invocation")
    func workerSentinelRejectsMalformedStandaloneInvocation() throws {
        let result = try runProbe(["__apple_cli_internal_worker_v1", "--request-fd", "3", "--response-fd", "3"])
        #expect(!result.timedOut)
        #expect(result.exitCode != 0)
    }

    @Test("action launch generates operation ID and nonce internally and keeps pending uncertain after ACK")
    func actionLaunchGeneratesOperationAndPersistsUncertainty() throws {
        let root = try scratch.directory().appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchThroughProbeParent(root: root)
        #expect(outcome == "childReturned(ack)")
        try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending?.phase == .uncertainAfterHandoff)
            #expect(snapshot.receipts.isEmpty)
        }
    }

    @Test("action capable child crash after possible handoff preserves uncertain pending state")
    func actionCapableCrashAfterPossibleHandoffPreservesUncertainty() throws {
        let root = try scratch.directory().appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchThroughProbeParent(root: root, command: "probe.crash", seed: "crash")
        #expect(outcome.hasPrefix("childRefusedOrFailed"))
        try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending?.phase == .uncertainAfterHandoff)
            #expect(snapshot.receipts.isEmpty)
        }
    }

    @Test("timeout after possible handoff is bounded and leaves pending uncertain")
    func actionTimeoutPreservesUncertainty() throws {
        let root = try scratch.directory().appendingPathComponent("timeout-\(UUID().uuidString)", isDirectory: true)
        let start = Date()
        let outcome = try launchThroughProbeParent(root: root, command: "probe.sleep", seed: "timeout", deadline: 100)
        #expect(outcome == "timedOut")
        #expect(Date().timeIntervalSince(start) < 2.0)
        try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending?.phase == .uncertainAfterHandoff)
            #expect(snapshot.receipts.isEmpty)
        }
    }

    @Test("existing pending blocks repeated action attempt before request delivery")
    func existingPendingBlocksBeforeDelivery() throws {
        let root = try scratch.directory().appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
        try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
            _ = try lease.begin(operationRequest("existing"))
        }
        let outcome = try launch(root: root, seed: "new")
        guard case .requestNotSent = outcome else {
            Issue.record("expected no request delivery, got \(outcome)")
            return
        }
    }

    @Test("ACK validation rereads all pending digests and rejects mismatch")
    func ackValidationRejectsDigestMismatch() throws {
        let root = try scratch.directory().appendingPathComponent("digest-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchThroughProbeParent(root: root, mode: "mutate")
        #expect(outcome == "protocolViolation(journal-binding)")
    }

    @Test("worker main rejects request trailing bytes and stale parent identity")
    func workerMainRejectsMalformedOrStaleParentRequest() throws {
        #expect(try directProtocolOutcome("trailing") == "exit(70)|response=none")
        #expect(try directProtocolOutcome("stale-parent") == "exit(70)|response=none")
    }

    @Test("worker main refuses a forged executable identity in the request frame")
    func workerMainRejectsForgedExecutableIdentity() throws {
        #expect(try directProtocolOutcome("different-executable") == "exit(70)|response=none")
    }

    @Test("worker main refuses an actual child launched from a different helper executable")
    func workerMainRejectsTrueForeignExecutableIdentityBeforeOperation() throws {
        #expect(try directProtocolOutcome("foreign-executable", scratchRoot: try scratch.directory()) == "exit(70)|response=none")
    }

    @Test("worker main rejects invalid decoded command before operation lookup")
    func workerMainRejectsInvalidDecodedCommandBeforeOperation() throws {
        #expect(try directProtocolOutcome("invalid-command") == "exit(70)|response=none")
    }

    @Test("named FIFO is refused as worker channel")
    func namedFIFOIsNotAcceptedAsAnonymousChannel() throws {
        let path = try scratch.directory().appendingPathComponent("named-fifo-\(UUID().uuidString)").path
        #expect(mkfifo(path, 0o600) == 0)
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        defer { if fd >= 0 { close(fd) } }
        #expect(fd >= 0)
        do {
            try WorkerFrameIO.validateAnonymousPipe(fd)
            Issue.record("named FIFO should not be accepted as anonymous worker pipe")
        } catch WorkerProtocolError.invalidDescriptor {}
    }

    @Test("worker watchdog exits a hung operation when its parent dies")
    func watchdogTerminatesWorkerAfterParentDeath() throws {
        let result = try runProbe(["--orphan-parent", try scratch.directory().path], timeout: 8)
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
    }

    @Test("unreaped child cleanup transfers a deferred reap obligation")
    func cleanupTransfersUnreapedChildToDeferredReaper() throws {
        let root = try scratch.directory().appendingPathComponent("deferred-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchThroughProbeParent(root: root, command: "probe.term-deaf", seed: "deferred", deadline: 100, mode: "deferred")
        #expect(outcome == "timedOut|deferred=1")
    }

    @Test("setup failure before child spawn closes descriptors and records no-delivery")
    func setupFailureBeforeSpawnClosesDescriptorsAndClearsPreparedOperation() throws {
        let before = openDescriptorCount()
        let root = try scratch.directory().appendingPathComponent("setup-fd-\(UUID().uuidString)", isDirectory: true)
        let outcome = try WorkerLauncher(testIO: NullInputFailingIO()).launch(WorkerLaunchRequest.makeForTesting(
            command: command("probe.empty"),
            journalRequest: operationRequest("setup-fd"),
            deadline: .millisecondsFromNow(500),
            stateRoot: root.path
        ))
        guard case .spawnOrSetupFailedBeforeRequest = outcome else {
            Issue.record("expected spawnOrSetupFailedBeforeRequest, got \(outcome)")
            return
        }
        #expect(openDescriptorCount() == before)
        try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending == nil)
            #expect(snapshot.receipts.count == 1)
            #expect(snapshot.receipts.first?.disposition == .noDelivery)
        }
    }

    @Test("observed action clears pending only after ACK and verifier success")
    func observedActionClearsPendingAfterAckAndVerifierSuccess() throws {
        let root = try scratch.directory().appendingPathComponent("observed-ok-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchObservedThroughProbe(root: root, command: "probe.empty", seed: "ok")
        #expect(outcome.hasPrefix("observedState("))
        #expect(outcome.contains(",verified-ok)|pending=none|receipts=observedState"))
    }

    @Test("observed no-op is blocked by pending and writes no receipt")
    func observedNoOpIsBlockedByPendingAndWritesNoReceipt() throws {
        let pendingRoot = try scratch.directory().appendingPathComponent("observed-noop-pending-\(UUID().uuidString)", isDirectory: true)
        try AppleAutomationJournal.withLockedJournal(root: pendingRoot.path, deadline: .millisecondsFromNow(1_000)) { lease in
            _ = try lease.begin(operationRequest("existing"))
        }
        let blocked = try launchObservedThroughProbe(root: pendingRoot, command: "probe.noop", seed: "blocked")
        #expect(blocked.contains("requestNotSent(pending-operation-exists:"))
        #expect(blocked.contains("|pending=preparedBeforeHandoff|receipts=none"))

        let root = try scratch.directory().appendingPathComponent("observed-noop-\(UUID().uuidString)", isDirectory: true)
        let noop = try launchObservedThroughProbe(root: root, command: "probe.noop", seed: "noop")
        #expect(noop == "alreadyInDesiredState(already-desired)|pending=none|receipts=none")
    }

    @Test("observed action retains uncertainty when worker or verifier cannot prove success")
    func observedActionRetainsUncertaintyWithoutVerifiedSuccess() throws {
        for (command, prefix) in [
            ("probe.refuse", "childRefusedOrFailed(probe-refused)"),
            ("probe.refuse-unsafe-detail", "childRefusedOrFailed(refused)"),
            ("probe.verify-false", "verificationFailed"),
            ("probe.verify-throw", "childRefusedOrFailed(unsupported-command)"),
            ("probe.verify-sleep", "timedOut"),
            ("probe.verify-parent-mismatch", "childRefusedOrFailed(parent-identity-mismatch)")
        ] {
            let root = try scratch.directory().appendingPathComponent("observed-\(command)-\(UUID().uuidString)", isDirectory: true)
            let outcome = try launchObservedThroughProbe(root: root, command: command, seed: command)
            #expect(outcome.hasPrefix(prefix))
            #expect(outcome.contains("|pending=uncertainAfterHandoff|receipts=none"))
            if command == "probe.verify-sleep" {
                #expect(outcome.contains("|verify=entered"))
            }
        }
    }

    @Test("observed action holds the journal lock through preflight and verification")
    func observedActionHoldsLockThroughPreflightAndVerification() throws {
        for command in ["probe.preflight-lock", "probe.verify-lock"] {
            let root = try scratch.directory().appendingPathComponent("observed-lock-\(command)-\(UUID().uuidString)", isDirectory: true)
            let outcome = try launchObservedThroughProbe(root: root, command: command, seed: command)
            #expect(outcome.contains("observedState("))
            #expect(outcome.contains("|pending=none|receipts=observedState"))
        }
    }

    @Test("observed action honors cancellation before clearing state")
    func observedActionHonorsCancellationBeforeClearingState() throws {
        for (command, expectedPending) in [
            ("probe.cancel-immediate", "none"),
            ("probe.resolve-cancel", "none"),
            ("probe.preflight-cancel", "none"),
            ("probe.cancel-after-preflight", "none"),
            ("probe.cancel-after-worker", "uncertainAfterHandoff"),
            ("probe.verify-cancel", "uncertainAfterHandoff"),
            ("probe.cancel-after-verify", "uncertainAfterHandoff")
        ] {
            let root = try scratch.directory().appendingPathComponent("observed-cancel-\(command)-\(UUID().uuidString)", isDirectory: true)
            let outcome = try launchObservedThroughProbe(root: root, command: command, seed: command)
            #expect(outcome.hasPrefix("cancelled"))
            #expect(outcome.contains("|pending=\(expectedPending)|receipts=none"))
        }
    }

    @Test("observed action cancels a hanging worker before deadline and releases lock")
    func observedActionCancelsHangingWorkerBeforeDeadlineAndReleasesLock() throws {
        let root = try scratch.directory().appendingPathComponent("observed-cancel-hanging-\(UUID().uuidString)", isDirectory: true)
        let start = Date()
        let outcome = try launchObservedThroughProbe(root: root, command: "probe.cancel-hanging-worker", seed: "hang")
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0)
        #expect(outcome == "cancelled|pending=uncertainAfterHandoff|receipts=none|deferred=0")
    }

    @Test("observed action revalidates pending binding after verifier")
    func observedActionRevalidatesPendingBindingAfterVerifier() throws {
        let root = try scratch.directory().appendingPathComponent("observed-postverify-mismatch-\(UUID().uuidString)", isDirectory: true)
        let outcome = try launchObservedThroughProbe(root: root, command: "probe.verify-mutate-journal", seed: "mismatch")
        #expect(outcome.hasPrefix("protocolViolation(journal-binding)"))
        #expect(outcome.contains("|pending=uncertainAfterHandoff|receipts=none"))
    }

    private func openDescriptorCount() -> Int {
        (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
    }
}
