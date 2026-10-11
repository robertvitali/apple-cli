import Darwin
import Foundation
import AppleKit

@_silgen_name("fork")
func c_fork() -> pid_t

struct ProbeOperation: WorkerOperation {
    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerResponseCategory {
        switch request.command.name {
        case "probe.empty":
            let extraDescriptors = (3..<64).filter { fcntl(Int32($0), F_GETFD) >= 0 }
            return extraDescriptors.count == 2 ? .ack : .failed
        case "probe.sleep":
            Thread.sleep(forTimeInterval: 2.0)
            return .ack
        case "probe.term-deaf":
            signal(SIGTERM, SIG_IGN)
            Thread.sleep(forTimeInterval: 10.0)
            return .ack
        case "probe.crash":
            Darwin.abort()
        default:
            return .ack
        }
    }
}

struct ProbeRegistry: WorkerOperationRegistry {
    func operation(for command: WorkerCommand) -> (any WorkerOperation)? { ProbeOperation() }
}

final class DeferredSink: ScriptDeferredReaping, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ScriptPendingReap] = []
    func accept(_ obligation: ScriptPendingReap) {
        lock.withLock { pending.append(obligation) }
    }
    var accepted: Int { lock.withLock { pending.count } }
}

func printOutcome(_ outcome: WorkerLaunchOutcome, suffix: String = "") {
    print("\(outcome.description)\(suffix)")
}

func digest(_ value: String) throws -> AppleAutomationJournal.TargetDigest {
    try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: value)
}

func request(_ seed: String = "probe") throws -> AppleAutomationJournal.OperationRequest {
    try AppleAutomationJournal.OperationRequest(
        operationType: .reactionSet,
        conversationDigest: digest("conversation-\(seed)"),
        messageDigest: digest("message-\(seed)"),
        partDigest: digest("part-\(seed)"),
        minimumEvidence: .init(targetHash: digest("minimum-evidence-\(seed)"), targetLength: 12)
    )
}

func writePID(_ pid: pid_t, to fd: Int32) {
    let text = "\(pid)\n".data(using: .utf8)!
    text.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
}

func makeJournalRoot(parent: String, prefix: String) throws -> URL {
    let root = URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard chmod(root.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return root
}

func copyExecutable(parent: String) throws -> String {
    let source = URL(fileURLWithPath: CommandLine.arguments[0])
    let copy = URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent("AutomationWorkerProbe-copy-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: copy)
    guard chmod(copy.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return copy.path
}

final class DescriptorSet {
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

struct ProbeProcessIdentity: Codable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let gid: UInt32
    let startTimeMicroseconds: UInt64
    let executableDevice: UInt64
    let executableInode: UInt64
    let executablePath: String
}

struct ProbeExecutableIdentity: Codable {
    let uid: UInt32
    let gid: UInt32
    let device: UInt64
    let inode: UInt64
    let path: String
}

struct ProbeCommandFrame: Codable {
    let name: String
    let payload: Data?
}

struct ProbeRequestFrame: Codable {
    let schemaVersion: Int
    let operationID: UUID
    let nonce: UUID
    let deadline: WorkerDeadline
    let parent: ProbeProcessIdentity
    let workerExecutable: ProbeExecutableIdentity
    let command: ProbeCommandFrame
}

struct ProbeResponseFrame: Codable {
    let schemaVersion: Int
    let operationID: UUID
    let nonce: UUID
    let category: String
}

func currentProcessIdentity(pid: pid_t = getpid()) -> ProbeProcessIdentity? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, raw, Int32(size))
        }
    }
    guard result == Int32(size) else { return nil }
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard pathLength > 0 else { return nil }
    let path = String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let micros = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    return ProbeProcessIdentity(pid: pid, parentPID: Int32(info.pbi_ppid), uid: UInt32(info.pbi_uid),
                                gid: UInt32(info.pbi_gid), startTimeMicroseconds: micros,
                                executableDevice: UInt64(st.st_dev), executableInode: UInt64(st.st_ino),
                                executablePath: path)
}

func executableIdentity(from process: ProbeProcessIdentity) -> ProbeExecutableIdentity {
    ProbeExecutableIdentity(uid: process.uid, gid: process.gid, device: process.executableDevice,
                            inode: process.executableInode, path: process.executablePath)
}

func setNonblocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
}

func writeAll(_ fd: Int32, _ data: Data, until deadline: DispatchTime) -> Bool {
    var offset = 0
    while offset < data.count && DispatchTime.now() < deadline {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&p, 1, 10)
        if ready < 0 {
            if errno == EINTR { continue }
            return false
        }
        guard ready > 0, p.revents & Int16(POLLOUT) != 0 else { continue }
        let wrote = data.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(4096, data.count - offset))
        }
        if wrote > 0 { offset += wrote }
        else if errno != EAGAIN && errno != EINTR { return false }
    }
    return offset == data.count
}

func framed(_ data: Data) -> Data {
    var header = UInt32(data.count).bigEndian
    var output = Data(bytes: &header, count: 4)
    output.append(data)
    return output
}

func readFrame(_ fd: Int32, until deadline: DispatchTime) -> ProbeResponseFrame? {
    var storage = Data()
    var expected: Int?
    var buffer = [UInt8](repeating: 0, count: 4096)
    while DispatchTime.now() < deadline {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&p, 1, 10)
        if ready < 0 {
            if errno == EINTR { continue }
            return nil
        }
        guard ready > 0 else { continue }
        if p.revents & Int16(POLLIN) != 0 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { return nil }
            storage.append(contentsOf: buffer.prefix(count))
            if expected == nil, storage.count >= 4 {
                let length = storage.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                expected = Int(length)
            }
            if let expected, storage.count >= 4 + expected {
                return try? JSONDecoder().decode(ProbeResponseFrame.self, from: storage.subdata(in: 4..<(4 + expected)))
            }
        }
        if p.revents & Int16(POLLHUP) != 0 { return nil }
    }
    return nil
}

enum ReapResult {
    case running
    case exited(Int32)
    case unavailable
}

func reap(_ pid: pid_t) -> ReapResult {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .exited(status) }
        if result == 0 { return .running }
        if errno == EINTR { continue }
        return .unavailable
    }
}

func spawnWorker(executable: String, requestFD: Int32, responseFD: Int32, null: Int32) -> pid_t {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return -1 }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_init(&actions) == 0 else { return -1 }
    defer { posix_spawn_file_actions_destroy(&actions) }
    var mask = sigset_t()
    var defaults = sigset_t()
    sigemptyset(&mask)
    sigfillset(&defaults)
    guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
        return -1
    }
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        guard posix_spawn_file_actions_adddup2(&actions, null, fd) == 0 else { return -1 }
    }
    guard posix_spawn_file_actions_addinherit_np(&actions, requestFD) == 0,
          posix_spawn_file_actions_addinherit_np(&actions, responseFD) == 0 else { return -1 }
    let strings = [executable, "__apple_cli_internal_worker_v1", "--request-fd", String(requestFD), "--response-fd", String(responseFD)]
    var argv = strings.map { strdup($0) }
    defer { argv.forEach { free($0) } }
    guard !argv.contains(nil) else { return -1 }
    argv.append(nil)
    var child: pid_t = 0
    let code = argv.withUnsafeMutableBufferPointer { posix_spawn(&child, executable, &actions, &attributes, $0.baseAddress!, environ) }
    return code == 0 ? child : -1
}

func waitFor(_ pid: pid_t, until deadline: DispatchTime) -> Int32? {
    while DispatchTime.now() < deadline {
        switch reap(pid) {
        case .exited(let status): return status
        case .unavailable: return nil
        case .running: usleep(10_000)
        }
    }
    if case .running = reap(pid), pid > 1, pid != getpgrp() { kill(-pid, SIGTERM) }
    let term = DispatchTime.now() + 1.0
    while DispatchTime.now() < term {
        switch reap(pid) {
        case .exited(let status): return status
        case .unavailable: return nil
        case .running: usleep(10_000)
        }
    }
    if case .running = reap(pid), pid > 1, pid != getpgrp() { kill(-pid, SIGKILL) }
    let killDeadline = DispatchTime.now() + 1.0
    while DispatchTime.now() < killDeadline {
        switch reap(pid) {
        case .exited(let status): return status
        case .unavailable: return nil
        case .running: usleep(10_000)
        }
    }
    return nil
}

func statusDescription(_ status: Int32?) -> String {
    guard let status else { return "status(unavailable)" }
    if status & 0x7f == 0 { return "exit(\((status >> 8) & 0xff))" }
    return "signal(\(status & 0x7f))"
}

func runDirectProtocolProbe(_ mode: String, scratchParent: String?) throws -> String {
    guard var parent = currentProcessIdentity() else { return "identity-unavailable" }
    var executable = executableIdentity(from: parent)
    var workerPath = CommandLine.arguments[0]
    let commandName: String
    var trailing = false
    var needsChildExecutableIdentity = false
    switch mode {
    case "stale-parent":
        parent = ProbeProcessIdentity(pid: parent.pid, parentPID: parent.parentPID, uid: parent.uid, gid: parent.gid,
                                      startTimeMicroseconds: 1, executableDevice: parent.executableDevice,
                                      executableInode: parent.executableInode, executablePath: parent.executablePath)
        commandName = "probe.empty"
    case "different-executable":
        executable = ProbeExecutableIdentity(uid: executable.uid, gid: executable.gid, device: executable.device,
                                             inode: executable.inode &+ 1, path: executable.path)
        commandName = "probe.empty"
    case "foreign-executable":
        guard let scratchParent else { return "missing-scratch" }
        workerPath = try copyExecutable(parent: scratchParent)
        commandName = "probe.crash"
        needsChildExecutableIdentity = true
    case "invalid-command":
        commandName = "bad command"
    case "trailing":
        commandName = "probe.empty"
        trailing = true
    default:
        return "unknown-mode"
    }

    var req: [Int32] = [-1, -1]
    var resp: [Int32] = [-1, -1]
    let descriptors = DescriptorSet()
    defer { descriptors.closeAll() }
    guard pipe(&req) == 0 else { return "pipe-failed" }
    req[0] = descriptors.insert(req[0])
    req[1] = descriptors.insert(req[1])
    guard pipe(&resp) == 0 else { return "pipe-failed" }
    resp[0] = descriptors.insert(resp[0])
    resp[1] = descriptors.insert(resp[1])
    let null = descriptors.insert(open("/dev/null", O_RDONLY | O_CLOEXEC))
    guard null >= 0 else { return "null-failed" }
    _ = setNonblocking(req[1])
    _ = setNonblocking(resp[0])
    let pid = spawnWorker(executable: workerPath, requestFD: req[0], responseFD: resp[1], null: null)
    guard pid > 1 else { return "spawn-failed" }
    descriptors.close(req[0]); req[0] = -1
    descriptors.close(resp[1]); resp[1] = -1
    if needsChildExecutableIdentity {
        guard let child = currentProcessIdentity(pid: pid) else {
            _ = waitFor(pid, until: DispatchTime.now() + 1.0)
            return "child-identity-unavailable"
        }
        executable = executableIdentity(from: child)
        let parentExecutable = executableIdentity(from: parent)
        guard executable.inode != parentExecutable.inode || executable.device != parentExecutable.device else {
            _ = waitFor(pid, until: DispatchTime.now() + 1.0)
            return "copy-not-foreign"
        }
    }
    let frame = ProbeRequestFrame(schemaVersion: 1, operationID: UUID(), nonce: UUID(),
                                  deadline: .millisecondsFromNow(1_000), parent: parent,
                                  workerExecutable: executable,
                                  command: ProbeCommandFrame(name: commandName, payload: nil))
    var bytes = framed(try JSONEncoder().encode(frame))
    if trailing { bytes.append(0xff) }
    let deadline = DispatchTime.now() + 2.0
    guard writeAll(req[1], bytes, until: deadline) else {
        _ = waitFor(pid, until: DispatchTime.now() + 1.0)
        return "write-timeout"
    }
    descriptors.close(req[1]); req[1] = -1
    let response = readFrame(resp[0], until: deadline)
    descriptors.close(resp[0]); resp[0] = -1
    let status = waitFor(pid, until: deadline)
    return "\(statusDescription(status))|response=\(response?.category ?? "none")"
}


if CommandLine.arguments.dropFirst().first == "--parent-run" {
    guard CommandLine.arguments.count == 7, let deadlineMS = UInt64(CommandLine.arguments[6]) else { exit(40) }
    let mode = CommandLine.arguments[2]
    let root = CommandLine.arguments[3]
    let commandName = CommandLine.arguments[4]
    let seed = CommandLine.arguments[5]
    let launcher: WorkerLauncher
    let suffixProvider: () -> String
    if mode == "mutate" {
        launcher = WorkerLauncher(testMutationHook: { path in
            let state = URL(fileURLWithPath: path).appendingPathComponent("automation-state.json")
            guard var text = try? String(contentsOf: state, encoding: .utf8) else { return }
            text = text.replacingOccurrences(of: "reactionSet", with: "replySend")
            try? text.write(to: state, atomically: false, encoding: .utf8)
        })
        suffixProvider = { "" }
    } else if mode == "deferred" {
        let sink = DeferredSink()
        launcher = WorkerLauncher(testMutationHook: nil, testDeferredReaping: sink, signalGraceMilliseconds: 0, reapGraceMilliseconds: 0)
        suffixProvider = { "|deferred=\(sink.accepted)" }
    } else {
        launcher = WorkerLauncher()
        suffixProvider = { "" }
    }
    let outcome = try launcher.launch(WorkerLaunchRequest.makeForTesting(
        command: try WorkerCommand(name: commandName),
        journalRequest: request(seed),
        deadline: .millisecondsFromNow(deadlineMS),
        stateRoot: root
    ))
    printOutcome(outcome, suffix: suffixProvider())
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--direct-protocol" {
    guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else { exit(41) }
    print(try runDirectProtocolProbe(CommandLine.arguments[2], scratchParent: CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil))
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--orphan-parent" {
    guard CommandLine.arguments.count == 3 else { exit(29) }
    let scratchParent = CommandLine.arguments[2]
    var pidPipe: [Int32] = [-1, -1]
    guard pipe(&pidPipe) == 0 else { exit(30) }
    let child = c_fork()
    if child == 0 {
        close(pidPipe[0])
        let writeFD = pidPipe[1]
        Thread.detachNewThread {
            usleep(150_000)
            Darwin._exit(0)
        }
        guard let root = try? makeJournalRoot(parent: scratchParent, prefix: "worker-orphan") else { Darwin._exit(21) }
        let launcher = WorkerLauncher(testSpawnedPIDHook: { writePID($0, to: writeFD) })
        _ = try? launcher.launch(WorkerLaunchRequest.makeForTesting(
            command: try WorkerCommand(name: "probe.sleep"),
            journalRequest: request("orphan"),
            deadline: .millisecondsFromNow(5_000),
            stateRoot: root.path
        ))
        Darwin._exit(20)
    }
    close(pidPipe[1])
    guard child > 0 else { exit(31) }
    let readDeadline = DispatchTime.now() + 2.0
    _ = setNonblocking(pidPipe[0])
    var bytes = [UInt8](repeating: 0, count: 32)
    var count = -1
    while DispatchTime.now() < readDeadline {
        count = read(pidPipe[0], &bytes, bytes.count)
        if count > 0 { break }
        if count < 0, errno != EAGAIN, errno != EINTR { break }
        usleep(10_000)
    }
    close(pidPipe[0])
    guard count > 0, let workerPID = Int32(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(32) }
    var status: Int32 = 0
    let childDeadline = DispatchTime.now() + 3.0
    while DispatchTime.now() < childDeadline {
        let waited = waitpid(child, &status, WNOHANG)
        if waited == child { break }
        if waited < 0, errno != EINTR { exit(34) }
        usleep(10_000)
    }
    let deadline = DispatchTime.now() + 3.0
    while DispatchTime.now() < deadline {
        if kill(workerPID, 0) != 0, errno == ESRCH { exit(0) }
        usleep(10_000)
    }
    _ = waitFor(workerPID, until: DispatchTime.now())
    exit(33)
}

if CommandLine.arguments.dropFirst().first == "--parent" {
    guard CommandLine.arguments.count == 4 else { exit(42) }
    let mode = CommandLine.arguments[2]
    let root = try makeJournalRoot(parent: CommandLine.arguments[3], prefix: "worker-probe")
    let command = try WorkerCommand(name: mode == "empty" ? "probe.empty" : "probe.crash")
    let outcome = try WorkerLauncher().launch(WorkerLaunchRequest.makeForTesting(
        command: command,
        journalRequest: request(),
        deadline: .millisecondsFromNow(2_000),
        stateRoot: root.path
    ))
    if case .childReturned = outcome { exit(0) }
    exit(10)
}

exit(Int32(InternalWorkerMain.run(arguments: CommandLine.arguments, registry: ProbeRegistry())))
