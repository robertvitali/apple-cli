import Darwin
import Foundation

package struct WorkerDeadline: Codable, Equatable, Sendable {
    let uptimeNanoseconds: UInt64
    package static func millisecondsFromNow(_ milliseconds: UInt64) -> WorkerDeadline {
        let now = DispatchTime.now().uptimeNanoseconds
        let add = milliseconds > UInt64.max / 1_000_000 ? UInt64.max : milliseconds * 1_000_000
        return WorkerDeadline(uptimeNanoseconds: now > UInt64.max - add ? UInt64.max : now + add)
    }
    package var expired: Bool { remainingNanoseconds == 0 }
    package var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= uptimeNanoseconds ? 0 : uptimeNanoseconds - now
    }
    var pollMilliseconds: Int32 {
        let remaining = remainingNanoseconds
        guard remaining > 0 else { return 0 }
        return Int32(min(10, max(1, (remaining + 999_999) / 1_000_000)))
    }

    var journalDeadline: AppleAutomationJournal.MonotonicDeadline {
        AppleAutomationJournal.MonotonicDeadline.uptimeNanoseconds(uptimeNanoseconds)
    }

    func boundedNanoseconds(_ configured: UInt64) -> UInt64 {
        min(configured, remainingNanoseconds)
    }
}


package struct WorkerCommand: Codable, Equatable, Sendable, CustomStringConvertible {
    package let name: String
    package let payload: Data?

    enum CodingKeys: String, CodingKey {
        case name
        case payload
    }

    package init(name: String, payload: Data? = nil) throws {
        guard !name.isEmpty, name.utf8.count <= 128, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            throw WorkerProtocolError.malformedFrame
        }
        if let payload, payload.count > 4096 { throw WorkerProtocolError.frameTooLarge }
        self.name = name
        self.payload = payload
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let payload = try container.decodeIfPresent(Data.self, forKey: .payload)
        try self.init(name: name, payload: payload)
    }

    package var description: String { name }
}

package struct WorkerProcessIdentity: Codable, Equatable, Sendable {
    package let pid: Int32
    package let parentPID: Int32
    package let uid: UInt32
    package let gid: UInt32
    package let startTimeMicroseconds: UInt64
    package let executableDevice: UInt64
    package let executableInode: UInt64
    package let executablePath: String
}

package struct WorkerExecutableIdentity: Codable, Equatable, Sendable {
    package let uid: UInt32
    package let gid: UInt32
    package let device: UInt64
    package let inode: UInt64
    package let path: String

    package init(uid: UInt32, gid: UInt32, device: UInt64, inode: UInt64, path: String) {
        self.uid = uid
        self.gid = gid
        self.device = device
        self.inode = inode
        self.path = path
    }
}

package struct WorkerRequest: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let operationID: UUID
    package let nonce: UUID
    package let deadline: WorkerDeadline
    package let parent: WorkerProcessIdentity
    package let workerExecutable: WorkerExecutableIdentity
    package let command: WorkerCommand

    package init(schemaVersion: Int, operationID: UUID, nonce: UUID, deadline: WorkerDeadline, parent: WorkerProcessIdentity, workerExecutable: WorkerExecutableIdentity, command: WorkerCommand) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.nonce = nonce
        self.deadline = deadline
        self.parent = parent
        self.workerExecutable = workerExecutable
        self.command = command
    }
}

package enum WorkerResponseCategory: String, Codable, Equatable, Sendable { case ack, refused, failed }

package struct WorkerOperationResult: Equatable, Sendable {
    package let category: WorkerResponseCategory
    package let detail: String?

    package init(_ category: WorkerResponseCategory, detail: String? = nil) {
        self.category = category
        self.detail = Self.safeDetail(detail)
    }

    package static let ack = WorkerOperationResult(.ack)
    package static let refused = WorkerOperationResult(.refused)
    package static let failed = WorkerOperationResult(.failed)

    package static func refused(_ detail: String) -> WorkerOperationResult {
        WorkerOperationResult(.refused, detail: detail)
    }

    package static func failed(_ detail: String) -> WorkerOperationResult {
        WorkerOperationResult(.failed, detail: detail)
    }

    private static let publicDetails: Set<String> = [
        "accessibility-denied",
        "ambiguous-selected-message",
        "ax-failure",
        "ax-failure-preflight",
        "ax-failure-open",
        "ax-failure-initial-route",
        "ax-failure-post-open-safety",
        "ax-failure-route-revalidation",
        "ax-failure-reply-open",
        "ax-failure-composer-readiness",
        "ax-failure-menu-open",
        "ax-failure-picker-readiness",
        "ax-failure-pre-press",
        "ax-failure-press",
        "ax-failure-post-press",
        "ax-failure-cleanup",
        "ax-failure-verification",
        "deadline-expired",
        "invalid-payload",
        "picker-unavailable",
        "probe-refused",
        "post-press-window-drift",
        "post-press-picker-identity-drift",
        "post-press-button-identity-drift",
        "post-press-selected-unknown",
        "post-press-selection-timeout",
        "picker-cancel-picker-unavailable",
        "picker-cancel-identity-drift",
        "picker-cancel-unavailable",
        "picker-dismissal-window-drift",
        "picker-dismissal-picker-identity-drift",
        "picker-dismissal-timeout",
        "post-press-verify-open-drift",
        "post-press-verify-route-drift",
        "post-press-verify-action-missing",
        "post-press-verify-picker-state-drift",
        "custom-chooser-post-selection-unselected",
        "edit-preflight-refused",
        "edit-unverified",
        "edit-persisted-verified",
        "attachment-retrieval-downloaded-verified",
        "attachment-retrieval-already-downloaded-verified",
        "attachment-retrieval-unavailable",
        "attachment-retrieval-failed",
        "attachment-retrieval-membership-drift",
        "reaction-remove-changed-verified",
        "reaction-remove-unchanged-verified",
        "reaction-set-changed-verified",
        "reaction-set-unchanged-verified",
        "no-send-empty-owned-composer-closed-verified",
        "no-send-exact-attachment-draft-closed-verified",
        "reaction-unavailable",
        "reply-action-unavailable",
        "reply-composer-existing",
        "reply-composer-ambiguous",
        "reply-composer-not-empty",
        "reply-composer-evidence-unavailable",
        "reply-composer-ownership-drift",
        "reply-composer-attachment-evidence",
        "reply-composer-cleanup-unavailable",
        "reply-composer-cleanup-failed",
        "reply-composer-original-draft-drift",
        "reply-composer-text-mismatch",
        "reply-composer-possible-draft-remains",
        "reply-attachment-clipboard-drift",
        "reply-attachment-layout-drift",
        "reply-attachment-draft-unverified",
        "reply-send-already-restored-clean-verified",
        "reply-send-empty-owned-composer-closed-verified",
        "target-drift",
        "traversal-limit",
        "unknown-ax-value"
    ]

    private static let targetDriftPhases: Set<String> = [
        "preflight",
        "open",
        "initial-route",
        "post-open-safety",
        "route-revalidation",
        "reply-open",
        "composer-readiness",
        "menu-open",
        "picker-readiness",
        "pre-press",
        "press",
        "post-press",
        "cleanup",
        "verification"
    ]

    private static let targetDriftReasons: Set<String> = [
        "relationship-count-changed",
        "window-mismatch",
        "picker-mismatch",
        "button-mismatch",
        "selected-state-changed"
    ]

    private static let verificationPaths: Set<String> = ["exact-existing", "custom-chooser"]
    private static let verificationDriftKinds: Set<String> = ["discovery-drift", "validation-drift"]
    private static let verificationDriftReasons: Set<String> = targetDriftReasons.union([
        "picker-still-present",
        "missing-transcript",
        "missing-retained-message",
        "replaced-transcript",
        "retained-message-action-missing"
    ])
    private static let customChooserAXFailurePhases: Set<String> = [
        "picker-read",
        "existing-button",
        "route-validation",
        "launch-discovery",
        "query",
        "preexisting-check",
        "launch-revalidation",
        "launch-press",
        "detached-discovery",
        "popover",
        "search-discovery",
        "search-precondition",
        "search-write",
        "search-readback",
        "candidate-wait",
        "candidate-read",
        "candidate-revalidation",
        "candidate-press",
        "post-selection"
    ]

    private static func safeDetail(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 128 else { return nil }
        guard publicDetails.contains(value) || isSafeTargetDriftDetail(value) || isSafeVerificationDetail(value) ||
            isSafeCustomChooserAXFailureDetail(value) || isSafeCustomChooserReactionUnavailableDetail(value) ||
            isSafeReplyAttachmentOwnershipDetail(value) || isSafeEditDiagnostic(value) else { return nil }
        return value
    }

    private static func isSafeEditDiagnostic(_ value: String) -> Bool {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "edit-unverified" else { return false }
        let stages: Set<Substring> = ["native-action", "trust", "titles", "process", "inactive",
            "navigation", "route", "anchor", "open-editor", "capture-editor", "replacement",
            "confirmation", "completion", "persistence"]
        let categories: Set<Substring> = ["deadline-expired", "target-drift", "ambiguous-selected-message",
            "unknown-ax-value", "traversal-limit", "ax-failure", "route-drift", "cancelled", "other"]
        return stages.contains(fields[1]) && categories.contains(fields[2])
    }

    private static func isSafeReplyAttachmentOwnershipDetail(_ value: String) -> Bool {
        let phases = ["before-paste", "after-paste", "before-return", "return-started", "after-return"]
        let reasons: Set<String> = ["transcript-count", "reply-transcript", "transcript-process", "main-transcript",
                                    "child-transcript-drift", "body-main-link-missing",
                                    "main-target-missing", "main-target-process", "main-target-action-missing", "other"]
        for phase in phases {
            let prefix = "reply-attachment-ownership-\(phase)-"
            if value.hasPrefix(prefix) { return reasons.contains(String(value.dropFirst(prefix.count))) }
        }
        return false
    }

    private static func isSafeTargetDriftDetail(_ value: String) -> Bool {
        let prefix = "target-drift-"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        for phase in targetDriftPhases {
            if suffix == phase { return true }
            let phasePrefix = "\(phase)-"
            if suffix.hasPrefix(phasePrefix) {
                return targetDriftReasons.contains(String(suffix.dropFirst(phasePrefix.count)))
            }
        }
        return false
    }

    private static func isSafeCustomChooserAXFailureDetail(_ value: String) -> Bool {
        let prefix = "ax-failure-custom-chooser-"
        guard value.hasPrefix(prefix) else { return false }
        return customChooserAXFailurePhases.contains(String(value.dropFirst(prefix.count)))
    }

    private static func isSafeCustomChooserReactionUnavailableDetail(_ value: String) -> Bool {
        let prefix = "reaction-unavailable-custom-chooser-"
        guard value.hasPrefix(prefix) else { return false }
        return customChooserAXFailurePhases.contains(String(value.dropFirst(prefix.count)))
    }

    private static func isSafeVerificationDetail(_ value: String) -> Bool {
        for path in verificationPaths {
            let prefix = "\(path)-verify-"
            guard value.hasPrefix(prefix) else { continue }
            let suffix = String(value.dropFirst(prefix.count))
            if suffix == "desired-state-mismatch" { return true }
            for kind in verificationDriftKinds {
                if suffix == kind { return true }
                let kindPrefix = "\(kind)-"
                if suffix.hasPrefix(kindPrefix) {
                    return verificationDriftReasons.contains(String(suffix.dropFirst(kindPrefix.count)))
                }
            }
        }
        return false
    }
}

package struct WorkerResponse: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let operationID: UUID
    package let nonce: UUID
    package let category: WorkerResponseCategory
    package let detail: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case nonce
        case category
        case detail
    }

    package init(schemaVersion: Int, operationID: UUID, nonce: UUID, category: WorkerResponseCategory, detail: String? = nil) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.nonce = nonce
        self.category = category
        self.detail = WorkerOperationResult(category, detail: detail).detail
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
                      operationID: container.decode(UUID.self, forKey: .operationID),
                      nonce: container.decode(UUID.self, forKey: .nonce),
                      category: container.decode(WorkerResponseCategory.self, forKey: .category),
                      detail: container.decodeIfPresent(String.self, forKey: .detail))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    package var failureReason: String { detail ?? category.rawValue }
}

package enum WorkerProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidArguments
    case invalidDescriptor
    case frameTooLarge
    case truncatedFrame
    case malformedFrame
    case deadlineExpired
    case cancelled
    case parentIdentityMismatch
    case unsupportedCommand
    case childExited

    package var description: String {
        switch self {
        case .invalidArguments: return "invalid-arguments"
        case .invalidDescriptor: return "invalid-descriptor"
        case .frameTooLarge: return "frame-too-large"
        case .truncatedFrame: return "truncated-frame"
        case .malformedFrame: return "malformed-frame"
        case .deadlineExpired: return "deadline-expired"
        case .cancelled: return "cancelled"
        case .parentIdentityMismatch: return "parent-identity-mismatch"
        case .unsupportedCommand: return "unsupported-command"
        case .childExited: return "child-exited"
        }
    }
}

enum WorkerFrameIO {
    static let requestCap = 64 * 1024
    static let responseCap = 16 * 1024

    static func setNonblocking(_ fd: Int32, noSigpipe: Bool = false) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DarwinScriptProcessIO.posixError(errno) }
        if noSigpipe, fcntl(fd, F_SETNOSIGPIPE, 1) != 0 { throw DarwinScriptProcessIO.posixError(errno) }
    }

    static func validateAnonymousPipe(_ fd: Int32) throws {
        guard fd > 2 else { throw WorkerProtocolError.invalidDescriptor }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw DarwinScriptProcessIO.posixError(errno) }
        guard (st.st_mode & S_IFMT) == S_IFIFO, st.st_nlink == 0 else { throw WorkerProtocolError.invalidDescriptor }
    }

    static func writeFrame(_ data: Data, to fd: Int32, cap: Int, io: any ScriptProcessIO,
                           deadline: WorkerDeadline, isCancelled: () -> Bool = { false }) throws {
        guard data.count <= cap else { throw WorkerProtocolError.frameTooLarge }
        var header = UInt32(data.count).bigEndian
        var bytes = Data(bytes: &header, count: 4)
        bytes.append(data)
        var offset = 0
        while offset < bytes.count {
            try throwIfParentDeadOrChildExited(deadline: deadline, isCancelled: isCancelled)
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&p, 1, deadline.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw DarwinScriptProcessIO.posixError(errno)
            }
            guard ready > 0 else { continue }
            if p.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw WorkerProtocolError.truncatedFrame }
            guard p.revents & Int16(POLLOUT) != 0 else { continue }
            do {
                let wrote = try bytes.withUnsafeBytes { raw in
                    try io.write(fd, from: UnsafeRawBufferPointer(rebasing: raw[offset..<min(bytes.count, offset + 4096)]))
                }
                guard wrote > 0 else { throw WorkerProtocolError.truncatedFrame }
                offset += wrote
            } catch {
                if isRetryable(error) { continue }
                throw error
            }
        }
    }

    static func readOneFrameThenEOF(from fd: Int32, cap: Int, io: any ScriptProcessIO,
                                    deadline: WorkerDeadline, isCancelled: () -> Bool = { false }) throws -> Data {
        var storage = Data()
        var expected: Int?
        var returnedFrame: Data?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try throwIfParentDeadOrChildExited(deadline: deadline, isCancelled: isCancelled)
            if let frame = returnedFrame {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, deadline.pollMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw DarwinScriptProcessIO.posixError(errno)
                }
                guard ready > 0 else { continue }
                if p.revents & Int16(POLLIN) != 0 {
                    let count = try buffer.withUnsafeMutableBytes { try io.read(fd, into: $0) }
                    if count > 0 { throw WorkerProtocolError.malformedFrame }
                    return frame
                }
                if p.revents & Int16(POLLHUP) != 0 {
                    let count = try buffer.withUnsafeMutableBytes { try io.read(fd, into: $0) }
                    if count > 0 { throw WorkerProtocolError.malformedFrame }
                    return frame
                }
                if p.revents & Int16(POLLERR | POLLNVAL) != 0 { throw WorkerProtocolError.truncatedFrame }
                continue
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, deadline.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw DarwinScriptProcessIO.posixError(errno)
            }
            guard ready > 0 else { continue }
            if p.revents & Int16(POLLERR | POLLNVAL) != 0 { throw WorkerProtocolError.truncatedFrame }
            if p.revents & (Int16(POLLIN) | Int16(POLLHUP)) == 0 { continue }
            let read: Int
            do { read = try buffer.withUnsafeMutableBytes { try io.read(fd, into: $0) } }
            catch {
                if isRetryable(error) { continue }
                throw error
            }
            guard read > 0 else { throw WorkerProtocolError.truncatedFrame }
            storage.append(contentsOf: buffer.prefix(read))
            if expected == nil, storage.count >= 4 {
                let length = storage.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= UInt32(cap) else { throw WorkerProtocolError.frameTooLarge }
                expected = Int(length)
            }
            if let expected, storage.count >= 4 + expected {
                guard storage.count == 4 + expected else { throw WorkerProtocolError.malformedFrame }
                returnedFrame = storage.subdata(in: 4..<(4 + expected))
            }
            if storage.count > cap + 4 { throw WorkerProtocolError.frameTooLarge }
        }
    }

    static func throwIfParentDeadOrChildExited(deadline: WorkerDeadline, isCancelled: () -> Bool = { false }) throws {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        if deadline.expired { throw WorkerProtocolError.deadlineExpired }
        if getppid() == 1 { throw WorkerProtocolError.parentIdentityMismatch }
    }

    static func isRetryable(_ error: any Error) -> Bool {
        let value = error as NSError
        return value.domain == NSPOSIXErrorDomain && (value.code == Int(EAGAIN) || value.code == Int(EINTR))
    }
}

package protocol WorkerOperation: Sendable {
    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult
}

package protocol WorkerOperationRegistry: Sendable {
    func operation(for command: WorkerCommand) -> (any WorkerOperation)?
}

package struct EmptyWorkerOperationRegistry: WorkerOperationRegistry {
    package init() {}
    package func operation(for command: WorkerCommand) -> (any WorkerOperation)? { nil }
}

package enum InternalWorkerMain {
    static let sentinel = "__apple_cli_internal_worker_v1"

    package static func isWorkerInvocation(_ arguments: [String]) -> Bool {
        arguments.count == 6 && arguments[1] == sentinel && arguments[2] == "--request-fd" && arguments[4] == "--response-fd"
    }

    package static func run(arguments: [String], registry: any WorkerOperationRegistry) -> Int32 {
        do {
            guard isWorkerInvocation(arguments), let requestFD = Int32(arguments[3]),
                  let responseFD = Int32(arguments[5]), requestFD > 2, responseFD > 2,
                  requestFD != responseFD else { throw WorkerProtocolError.invalidArguments }
            try WorkerFrameIO.validateAnonymousPipe(requestFD)
            try WorkerFrameIO.validateAnonymousPipe(responseFD)
            try WorkerFrameIO.setNonblocking(requestFD)
            try WorkerFrameIO.setNonblocking(responseFD, noSigpipe: true)
            let io = DarwinScriptProcessIO()
            defer { try? io.close(requestFD); try? io.close(responseFD) }
            let requestData = try WorkerFrameIO.readOneFrameThenEOF(from: requestFD, cap: WorkerFrameIO.requestCap,
                                                                    io: io, deadline: .millisecondsFromNow(1_000))
            let request = try JSONDecoder().decode(WorkerRequest.self, from: requestData)
            guard request.schemaVersion == 1 else { throw WorkerProtocolError.malformedFrame }
            guard validateParent(request.parent), validateWorkerExecutable(request.workerExecutable, sameExecutableAs: request.parent) else { throw WorkerProtocolError.parentIdentityMismatch }
            guard !request.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
            guard let operation = registry.operation(for: request.command) else { throw WorkerProtocolError.unsupportedCommand }
            let watchdog = WorkerOperationWatchdog(parent: request.parent, deadline: request.deadline)
            watchdog.start()
            defer { watchdog.cancel() }
            let result = try operation.run(request, deadline: request.deadline)
            guard validateParent(request.parent), validateWorkerExecutable(request.workerExecutable, sameExecutableAs: request.parent) else { throw WorkerProtocolError.parentIdentityMismatch }
            let response = WorkerResponse(schemaVersion: 1, operationID: request.operationID, nonce: request.nonce, category: result.category, detail: result.detail)
            let responseData = try JSONEncoder().encode(response)
            try WorkerFrameIO.writeFrame(responseData, to: responseFD, cap: WorkerFrameIO.responseCap,
                                         io: io, deadline: request.deadline)
            return 0
        } catch {
            return 70
        }
    }

    fileprivate static func validateParentForWatchdog(_ identity: WorkerProcessIdentity) -> Bool {
        guard getppid() == identity.pid, let current = WorkerProcessIdentity.current(pid: identity.pid) else { return false }
        return current == identity
    }

    private static func validateWorkerExecutable(_ identity: WorkerExecutableIdentity, sameExecutableAs parent: WorkerProcessIdentity) -> Bool {
        guard let current = WorkerExecutableIdentity.current() else { return false }
        let parentExecutable = WorkerExecutableIdentity(uid: parent.uid, gid: parent.gid, device: parent.executableDevice, inode: parent.executableInode, path: parent.executablePath)
        return current == identity && current == parentExecutable
    }

    private static func validateParent(_ identity: WorkerProcessIdentity) -> Bool {
        validateParentForWatchdog(identity)
    }
}

extension WorkerProcessIdentity {
    static func current(pid: pid_t = getpid()) -> WorkerProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, raw, Int32(size))
            }
        }
        guard result == Int32(size) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathSize = UInt32(pathBuffer.count)
        let pathLength = proc_pidpath(pid, &pathBuffer, pathSize)
        guard pathLength > 0 else { return nil }
        let observedPath = String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let executable = WorkerExecutableIdentity.canonicalExecutable(path: observedPath, uid: UInt32(info.pbi_uid), gid: UInt32(info.pbi_gid)) else { return nil }
        let micros = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return WorkerProcessIdentity(pid: pid,
                                     parentPID: Int32(info.pbi_ppid),
                                     uid: UInt32(info.pbi_uid),
                                     gid: UInt32(info.pbi_gid),
                                     startTimeMicroseconds: micros,
                                     executableDevice: executable.device,
                                     executableInode: executable.inode,
                                     executablePath: executable.path)
    }
}

extension WorkerExecutableIdentity {
    static func current() -> WorkerExecutableIdentity? {
        guard let process = WorkerProcessIdentity.current() else { return nil }
        return WorkerExecutableIdentity(uid: process.uid, gid: process.gid, device: process.executableDevice, inode: process.executableInode, path: process.executablePath)
    }

    fileprivate static func canonicalExecutable(path: String, uid: UInt32, gid: UInt32) -> WorkerExecutableIdentity? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonicalPath = String(cString: resolved)
        var st = stat()
        guard stat(canonicalPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return WorkerExecutableIdentity(uid: uid, gid: gid, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), path: canonicalPath)
    }
}

package struct WorkerJournalBinding {
    package let root: String
    package let request: AppleAutomationJournal.OperationRequest
    package init(root: String, request: AppleAutomationJournal.OperationRequest) {
        self.root = root
        self.request = request
    }
}

package struct WorkerLaunchRequest {
    package let command: WorkerCommand
    package let deadline: WorkerDeadline
    package let journal: WorkerJournalBinding

    fileprivate init(command: WorkerCommand, deadline: WorkerDeadline, journal: WorkerJournalBinding) {
        self.command = command
        self.deadline = deadline
        self.journal = journal
    }

    package static func makeForTesting(command: WorkerCommand, journalRequest: AppleAutomationJournal.OperationRequest, deadline: WorkerDeadline, stateRoot: String) -> WorkerLaunchRequest {
        WorkerLaunchRequest(command: command, deadline: deadline, journal: WorkerJournalBinding(root: stateRoot, request: journalRequest))
    }
}

/// Digest-only target binding used to derive the journal request and raw worker command
/// from the same resolved target. This binds orchestration intent; it does not prove
/// that an arbitrary command payload semantically matches those digests.
package struct WorkerObservedTargetBinding {
    package let operationType: AppleAutomationJournal.PendingOperation.OperationType
    package let conversationDigest: AppleAutomationJournal.TargetDigest
    package let messageDigest: AppleAutomationJournal.TargetDigest?
    package let partDigest: AppleAutomationJournal.TargetDigest?
    package let minimumEvidence: AppleAutomationJournal.PendingOperation.MinimumEvidence

    package init(operationType: AppleAutomationJournal.PendingOperation.OperationType,
                 conversationDigest: AppleAutomationJournal.TargetDigest,
                 messageDigest: AppleAutomationJournal.TargetDigest?,
                 partDigest: AppleAutomationJournal.TargetDigest?,
                 minimumEvidence: AppleAutomationJournal.PendingOperation.MinimumEvidence) {
        self.operationType = operationType
        self.conversationDigest = conversationDigest
        self.messageDigest = messageDigest
        self.partDigest = partDigest
        self.minimumEvidence = minimumEvidence
    }

    fileprivate var journalRequest: AppleAutomationJournal.OperationRequest {
        AppleAutomationJournal.OperationRequest(operationType: operationType,
                                                conversationDigest: conversationDigest,
                                                messageDigest: messageDigest,
                                                partDigest: partDigest,
                                                minimumEvidence: minimumEvidence)
    }
}

/// A resolved observed action. Build `command` from the supplied target binding so
/// production callers keep the worker payload and journal request coupled to one
/// resolution pass.
package struct WorkerResolvedAction {
    package let command: WorkerCommand
    package let journalRequest: AppleAutomationJournal.OperationRequest
    package init(target binding: WorkerObservedTargetBinding, command: (WorkerObservedTargetBinding) throws -> WorkerCommand) throws {
        self.command = try command(binding)
        self.journalRequest = binding.journalRequest
    }
}

package enum WorkerPreflightResult: Equatable {
    case requiresMutation
    case alreadyInDesiredState(String)
}

/// Deadline and cooperative cancellation state passed to observed-action callbacks.
/// Callbacks must stay bounded and check this context before continuing slow work.
package struct WorkerObservedContext {
    package let deadline: WorkerDeadline
    private let isCancelledCallback: () -> Bool
    package init(deadline: WorkerDeadline, isCancelled: @escaping () -> Bool) {
        self.deadline = deadline
        self.isCancelledCallback = isCancelled
    }
    package var isCancelled: Bool { isCancelledCallback() }
}

/// Experimental observed worker orchestration. `resolve`, `preflight`, and `verify`
/// run while the journal lock is held, so callbacks must be quick or cooperatively
/// bounded by `WorkerObservedContext.deadline` and `isCancelled`.
package struct WorkerObservedAction {
    package typealias Resolve = () throws -> WorkerResolvedAction
    package typealias Preflight = (WorkerResolvedAction, WorkerObservedContext) throws -> WorkerPreflightResult
    package typealias Verify = (WorkerResolvedAction, WorkerResponse, WorkerObservedContext) throws -> String?

    package let stateRoot: String
    package let deadline: WorkerDeadline
    let isCancelled: () -> Bool
    let resolve: Resolve
    let preflight: Preflight
    let verify: Verify

    package init(stateRoot: String,
                 deadline: WorkerDeadline,
                 isCancelled: @escaping () -> Bool = { false },
                 resolve: @escaping Resolve,
                 preflight: @escaping Preflight,
                 verify: @escaping Verify) {
        self.stateRoot = stateRoot
        self.deadline = deadline
        self.isCancelled = isCancelled
        self.resolve = resolve
        self.preflight = preflight
        self.verify = verify
    }

    /// Context-aware resolution retains the same context as preflight/verification,
    /// while preserving existing no-argument resolver callers.
    package init(stateRoot: String, deadline: WorkerDeadline,
                 isCancelled: @escaping () -> Bool = { false },
                 resolveWithContext: @escaping (WorkerObservedContext) throws -> WorkerResolvedAction,
                 preflight: @escaping Preflight, verify: @escaping Verify) {
        self.init(stateRoot: stateRoot, deadline: deadline, isCancelled: isCancelled,
                  resolve: { try resolveWithContext(WorkerObservedContext(deadline: deadline, isCancelled: isCancelled)) },
                  preflight: preflight, verify: verify)
    }
}

package enum WorkerLaunchOutcome: CustomStringConvertible {
    case spawnOrSetupFailedBeforeRequest(String)
    case requestNotSent(String)
    case childRefusedOrFailed(String)
    case childReturned(WorkerResponse)
    case timedOut
    case protocolViolation(String)

    package var description: String {
        switch self {
        case .spawnOrSetupFailedBeforeRequest(let value): return "spawnOrSetupFailedBeforeRequest(\(value))"
        case .requestNotSent(let value): return "requestNotSent(\(value))"
        case .childRefusedOrFailed(let value): return "childRefusedOrFailed(\(value))"
        case .childReturned(let response):
            return response.detail.map { "childReturned(\(response.category.rawValue):\($0))" } ?? "childReturned(\(response.category.rawValue))"
        case .timedOut: return "timedOut"
        case .protocolViolation(let value): return "protocolViolation(\(value))"
        }
    }
}

/// Experimental UI-automation result for a bounded worker handoff plus caller-supplied
/// postcondition. `.observedState` records only observed postcondition evidence; it is
/// not causal completion proof and does not prove Messages has no queued late action.
package enum WorkerObservedOutcome: CustomStringConvertible {
    case alreadyInDesiredState(String)
    case observedState(operationID: UUID, verification: String)
    case spawnOrSetupFailedBeforeRequest(String)
    case requestNotSent(String)
    case childRefusedOrFailed(String)
    case cancelled
    case verificationFailed
    case timedOut
    case protocolViolation(String)

    package var description: String {
        switch self {
        case .alreadyInDesiredState(let value): return "alreadyInDesiredState(\(value))"
        case .observedState(let operationID, let verification): return "observedState(\(operationID.uuidString),\(verification))"
        case .spawnOrSetupFailedBeforeRequest(let value): return "spawnOrSetupFailedBeforeRequest(\(value))"
        case .requestNotSent(let value): return "requestNotSent(\(value))"
        case .childRefusedOrFailed(let value): return "childRefusedOrFailed(\(value))"
        case .cancelled: return "cancelled"
        case .verificationFailed: return "verificationFailed"
        case .timedOut: return "timedOut"
        case .protocolViolation(let value): return "protocolViolation(\(value))"
        }
    }
}

private enum WorkerExchangeResult {
    case response(WorkerResponse)
    case spawnOrSetupFailedBeforeRequest(String)
    case requestNotSent(String)
    case childRefusedOrFailed(String)
    case cancelled
    case timedOut
    case protocolViolation(String)
}

final class WorkerOperationWatchdog: @unchecked Sendable {
    private let parent: WorkerProcessIdentity
    private let deadline: WorkerDeadline
    private let lock = NSLock()
    private var cancelled = false

    init(parent: WorkerProcessIdentity, deadline: WorkerDeadline) {
        self.parent = parent
        self.deadline = deadline
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let done = cancelled
                lock.unlock()
                if done { return }
                if deadline.expired || !InternalWorkerMain.validateParentForWatchdog(parent) {
                    Darwin._exit(70)
                }
                _ = poll(nil, 0, 10)
            }
        }
    }

    func cancel() { lock.withLock { cancelled = true } }
}

package struct WorkerLauncher {
    package typealias JournalMutationHook = @Sendable (String) -> Void
    package typealias SpawnedPIDHook = @Sendable (pid_t) -> Void
    private let io: any ScriptProcessIO
    private let mutateJournalBeforeAckValidation: JournalMutationHook?
    private let deferredReaping: any ScriptDeferredReaping
    private let spawnedPIDHook: SpawnedPIDHook?
    private let signalGraceNanoseconds: UInt64
    private let reapGraceNanoseconds: UInt64
    package init() {
        self.io = DarwinScriptProcessIO()
        self.mutateJournalBeforeAckValidation = nil
        self.deferredReaping = ScriptEventualReaper.shared
        self.spawnedPIDHook = nil
        self.signalGraceNanoseconds = 200_000_000
        self.reapGraceNanoseconds = 200_000_000
    }

    package init(testSpawnedPIDHook: @escaping SpawnedPIDHook,
                 signalGraceMilliseconds: UInt64 = 200,
                 reapGraceMilliseconds: UInt64 = 200) {
        self.io = DarwinScriptProcessIO()
        self.mutateJournalBeforeAckValidation = nil
        self.deferredReaping = ScriptEventualReaper.shared
        self.spawnedPIDHook = testSpawnedPIDHook
        self.signalGraceNanoseconds = signalGraceMilliseconds * 1_000_000
        self.reapGraceNanoseconds = reapGraceMilliseconds * 1_000_000
    }

    init(testIO: any ScriptProcessIO) {
        self.io = testIO
        self.mutateJournalBeforeAckValidation = nil
        self.deferredReaping = ScriptEventualReaper.shared
        self.spawnedPIDHook = nil
        self.signalGraceNanoseconds = 200_000_000
        self.reapGraceNanoseconds = 200_000_000
    }

    package init(testMutationHook: JournalMutationHook? = nil,
         testDeferredReaping deferredReaping: (any ScriptDeferredReaping)? = nil,
         signalGraceMilliseconds: UInt64 = 200,
         reapGraceMilliseconds: UInt64 = 200) {
        self.io = DarwinScriptProcessIO()
        self.mutateJournalBeforeAckValidation = testMutationHook
        self.deferredReaping = deferredReaping ?? ScriptEventualReaper.shared
        self.spawnedPIDHook = nil
        self.signalGraceNanoseconds = signalGraceMilliseconds * 1_000_000
        self.reapGraceNanoseconds = reapGraceMilliseconds * 1_000_000
    }

    package func launch(_ request: WorkerLaunchRequest) throws -> WorkerLaunchOutcome {
        guard !request.deadline.expired else { return .timedOut }
        do {
            return try AppleAutomationJournal.withLockedJournal(root: request.journal.root, deadline: request.deadline.journalDeadline) { lease in
                guard !request.deadline.expired else { return .timedOut }
                let op: UUID
                do { op = try lease.begin(request.journal.request) }
                catch { return .requestNotSent(String(describing: error)) }
                guard let frame = makeWorkerFrame(operationID: op, command: request.command, deadline: request.deadline) else {
                    try? lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    return .requestNotSent("identity-unavailable")
                }
                let encoded: Data
                do { encoded = try JSONEncoder().encode(frame) }
                catch {
                    try? lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    return .requestNotSent(String(describing: error))
                }
                return launchOutcome(from: exchange(request: request, frame: frame, encoded: encoded, lease: lease, preparedOperationID: op))
            }
        } catch AppleAutomationJournal.Error.lockTimedOut {
            return .timedOut
        }
    }

    package func launchObserved(_ action: WorkerObservedAction) throws -> WorkerObservedOutcome {
        guard !action.deadline.expired else { return .timedOut }
        guard !action.isCancelled() else { return .cancelled }
        func context() -> WorkerObservedContext {
            WorkerObservedContext(deadline: action.deadline, isCancelled: action.isCancelled)
        }
        func cancelledOrExpired() -> WorkerObservedOutcome? {
            if action.isCancelled() { return .cancelled }
            if action.deadline.expired { return .timedOut }
            return nil
        }
        do {
            return try AppleAutomationJournal.withLockedJournal(root: action.stateRoot, deadline: action.deadline.journalDeadline, isCancelled: action.isCancelled) { lease in
                if let outcome = cancelledOrExpired() { return outcome }
                if let pending = try lease.loadSnapshot().pending {
                    return .requestNotSent(AppleAutomationJournal.Error.pendingOperationExists(pending.operationID.uuidString).description)
                }
                let resolved: WorkerResolvedAction
                do { resolved = try action.resolve() }
                catch WorkerProtocolError.cancelled { return .cancelled }
                catch WorkerProtocolError.deadlineExpired { return .timedOut }
                catch let error as AppleError { throw error }
                catch { return .requestNotSent(String(describing: error)) }
                if let outcome = cancelledOrExpired() { return outcome }
                let preflight: WorkerPreflightResult
                do { preflight = try action.preflight(resolved, context()) }
                catch WorkerProtocolError.cancelled { return .cancelled }
                catch WorkerProtocolError.deadlineExpired { return .timedOut }
                catch { return .requestNotSent(String(describing: error)) }
                switch preflight {
                case .alreadyInDesiredState(let verification):
                    if let outcome = cancelledOrExpired() { return outcome }
                    return .alreadyInDesiredState(verification)
                case .requiresMutation:
                    break
                }
                if let outcome = cancelledOrExpired() { return outcome }
                let op: UUID
                do { op = try lease.begin(resolved.journalRequest) }
                catch { return .requestNotSent(String(describing: error)) }
                guard let frame = makeWorkerFrame(operationID: op, command: resolved.command, deadline: action.deadline) else {
                    try? lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    return .requestNotSent("identity-unavailable")
                }
                let encoded: Data
                do { encoded = try JSONEncoder().encode(frame) }
                catch {
                    try? lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    return .requestNotSent(String(describing: error))
                }
                if let outcome = cancelledOrExpired() {
                    try? lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    return outcome
                }
                let request = WorkerLaunchRequest(command: resolved.command,
                                                  deadline: action.deadline,
                                                  journal: WorkerJournalBinding(root: action.stateRoot, request: resolved.journalRequest))
                switch exchange(request: request, frame: frame, encoded: encoded, lease: lease,
                                preparedOperationID: op, isCancelled: action.isCancelled) {
                case .response(let response):
                    if let outcome = cancelledOrExpired() { return outcome }
                    let verification: String?
                    do { verification = try action.verify(resolved, response, context()) }
                    catch WorkerProtocolError.cancelled { return .cancelled }
                    catch WorkerProtocolError.deadlineExpired { return .timedOut }
                    catch WorkerProtocolError.parentIdentityMismatch {
                        return .childRefusedOrFailed(WorkerProtocolError.parentIdentityMismatch.description)
                    }
                    catch { return .childRefusedOrFailed(String(describing: error)) }
                    guard let verification else {
                        return .verificationFailed
                    }
                    if let outcome = cancelledOrExpired() { return outcome }
                    let snapshot = try lease.loadSnapshot()
                    guard let pending = snapshot.pending,
                          pending.operationID == op,
                          pending.phase == .uncertainAfterHandoff,
                          pending.matches(resolved.journalRequest) else {
                        return .protocolViolation("journal-binding")
                    }
                    do { try lease.recordObservedState(operationID: op) }
                    catch { return .protocolViolation(String(describing: error)) }
                    return .observedState(operationID: op, verification: verification)
                case .spawnOrSetupFailedBeforeRequest(let value): return .spawnOrSetupFailedBeforeRequest(value)
                case .requestNotSent(let value): return .requestNotSent(value)
                case .childRefusedOrFailed(let value): return .childRefusedOrFailed(value)
                case .cancelled: return .cancelled
                case .timedOut: return .timedOut
                case .protocolViolation(let value): return .protocolViolation(value)
                }
            }
        } catch AppleAutomationJournal.Error.lockTimedOut {
            return .timedOut
        } catch AppleAutomationJournal.Error.cancelled {
            return .cancelled
        } catch WorkerProtocolError.deadlineExpired {
            return .timedOut
        } catch WorkerProtocolError.parentIdentityMismatch {
            return .childRefusedOrFailed(WorkerProtocolError.parentIdentityMismatch.description)
        } catch let error as AppleError {
            throw error
        } catch {
            return .childRefusedOrFailed(String(describing: error))
        }
    }

    private func makeWorkerFrame(operationID: UUID, command: WorkerCommand, deadline: WorkerDeadline) -> WorkerRequest? {
        guard let parent = WorkerProcessIdentity.current() else { return nil }
        let executable = WorkerExecutableIdentity(uid: parent.uid, gid: parent.gid, device: parent.executableDevice, inode: parent.executableInode, path: parent.executablePath)
        return WorkerRequest(schemaVersion: 1, operationID: operationID, nonce: UUID(),
                             deadline: deadline, parent: parent, workerExecutable: executable, command: command)
    }

    private func launchOutcome(from result: WorkerExchangeResult) -> WorkerLaunchOutcome {
        switch result {
        case .response(let response): return .childReturned(response)
        case .spawnOrSetupFailedBeforeRequest(let value): return .spawnOrSetupFailedBeforeRequest(value)
        case .requestNotSent(let value): return .requestNotSent(value)
        case .childRefusedOrFailed(let value): return .childRefusedOrFailed(value)
        case .cancelled: return .timedOut
        case .timedOut: return .timedOut
        case .protocolViolation(let value): return .protocolViolation(value)
        }
    }

    private func exchange(request: WorkerLaunchRequest, frame: WorkerRequest, encoded: Data,
                          lease: AppleAutomationJournal.JournalLease, preparedOperationID: UUID,
                          isCancelled: () -> Bool = { false }) -> WorkerExchangeResult {
        var owned = Set<Int32>()
        func keep(_ fd: Int32) -> Int32 { owned.insert(fd); return fd }
        func closeOwned(_ fd: Int32) { if owned.remove(fd) != nil { try? io.close(fd) } }
        func closeAll() { for fd in Array(owned) { closeOwned(fd) } }
        var pid: pid_t = 0
        var ownsChild = false
        var maySignal = true
        func observe() {
            guard ownsChild, pid > 1 else { return }
            var info = siginfo_t()
            let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if rc == 0, info.si_pid == pid { maySignal = false }
            else if rc != 0, errno == ECHILD { ownsChild = false; maySignal = false }
        }
        func reapOnce() -> Bool {
            guard ownsChild, pid > 1 else { return true }
            var info = siginfo_t()
            let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG)
            if rc == 0, info.si_pid == pid { ownsChild = false; maySignal = false; return true }
            if rc != 0, errno == ECHILD { ownsChild = false; maySignal = false; return true }
            return false
        }
        func transferReap() {
            guard ownsChild, pid > 1 else { return }
            ownsChild = false
            maySignal = false
            deferredReaping.accept(ScriptPendingReap(pid: pid, reaper: DarwinScriptProcessReaper()))
        }
        func cleanup(killChild: Bool) {
            closeAll()
            observe()
            if killChild, ownsChild, maySignal, pid > 1, pid != getpgrp() { _ = Darwin.kill(-pid, SIGTERM) }
            let termBudget = request.deadline.boundedNanoseconds(signalGraceNanoseconds)
            let termDeadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ termBudget)
            while termBudget > 0, DispatchTime.now() < termDeadline, ownsChild { if reapOnce() { return }; _ = poll(nil, 0, request.deadline.pollMilliseconds) }
            observe()
            if killChild, ownsChild, maySignal, pid > 1, pid != getpgrp() { _ = Darwin.kill(-pid, SIGKILL) }
            let reapBudget = request.deadline.boundedNanoseconds(reapGraceNanoseconds)
            let reapDeadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ reapBudget)
            while reapBudget > 0, DispatchTime.now() < reapDeadline, ownsChild { if reapOnce() { return }; _ = poll(nil, 0, request.deadline.pollMilliseconds) }
            transferReap()
        }

        do {
            let req = try io.pipe(); _ = keep(req.read); _ = keep(req.write)
            let resp = try io.pipe(); _ = keep(resp.read); _ = keep(resp.write)
            let null = try io.nullInput(); _ = keep(null)
            try WorkerFrameIO.validateAnonymousPipe(req.read)
            try WorkerFrameIO.validateAnonymousPipe(req.write)
            try WorkerFrameIO.validateAnonymousPipe(resp.read)
            try WorkerFrameIO.validateAnonymousPipe(resp.write)
            try WorkerFrameIO.setNonblocking(req.write, noSigpipe: true)
            try WorkerFrameIO.setNonblocking(resp.read)
            pid = try spawn(executable: frame.parent.executablePath, requestFD: req.read, responseFD: resp.write, null: null)
            ownsChild = true
            spawnedPIDHook?(pid)
            closeOwned(req.read); closeOwned(resp.write); closeOwned(null)
            try lease.markUncertainAfterHandoff(operationID: preparedOperationID)
            try WorkerFrameIO.writeFrame(encoded, to: req.write, cap: WorkerFrameIO.requestCap, io: io,
                                         deadline: request.deadline, isCancelled: isCancelled)
            closeOwned(req.write)
            let data = try WorkerFrameIO.readOneFrameThenEOF(from: resp.read, cap: WorkerFrameIO.responseCap, io: io,
                                                             deadline: request.deadline, isCancelled: isCancelled)
            closeOwned(resp.read)
            let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
            cleanup(killChild: false)
            guard response.schemaVersion == 1, response.operationID == frame.operationID, response.nonce == frame.nonce else {
                return .protocolViolation("response-binding")
            }
            mutateJournalBeforeAckValidation?(request.journal.root)
            let snapshot = try lease.loadSnapshot()
            guard let pending = snapshot.pending,
                  pending.operationID == frame.operationID,
                  pending.phase == .uncertainAfterHandoff,
                  pending.matches(request.journal.request) else {
                return .protocolViolation("journal-binding")
            }
            guard response.category == .ack else { return .childRefusedOrFailed(response.failureReason) }
            return .response(response)
        } catch WorkerProtocolError.cancelled {
            cleanup(killChild: true)
            return .cancelled
        } catch WorkerProtocolError.deadlineExpired {
            cleanup(killChild: true)
            return .timedOut
        } catch WorkerProtocolError.frameTooLarge {
            cleanup(killChild: true)
            return .protocolViolation("frame-too-large")
        } catch WorkerProtocolError.malformedFrame {
            cleanup(killChild: true)
            return .protocolViolation("malformed-frame")
        } catch WorkerProtocolError.truncatedFrame {
            cleanup(killChild: true)
            return request.deadline.expired ? .timedOut : .childRefusedOrFailed("truncated-frame")
        } catch {
            if pid == 0 { try? lease.recordNoDeliveryBeforeHandoff(operationID: preparedOperationID) }
            cleanup(killChild: true)
            return pid == 0 ? .spawnOrSetupFailedBeforeRequest(String(describing: error)) : .childRefusedOrFailed(String(describing: error))
        }
    }

    private func spawn(executable: String, requestFD: Int32, responseFD: Int32, null: Int32) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        func check(_ code: Int32) throws { guard code == 0 else { throw DarwinScriptProcessIO.posixError(code) } }
        try check(posix_spawnattr_init(&attributes)); defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t(); var defaults = sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] { try check(posix_spawn_file_actions_adddup2(&actions, null, fd)) }
        try check(posix_spawn_file_actions_addinherit_np(&actions, requestFD))
        try check(posix_spawn_file_actions_addinherit_np(&actions, responseFD))
        let strings = [executable, InternalWorkerMain.sentinel, "--request-fd", String(requestFD), "--response-fd", String(responseFD)]
        var argv = strings.map { strdup($0) }
        defer { for pointer in argv { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw DarwinScriptProcessIO.posixError(ENOMEM) }
        argv.append(nil)
        var child: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer { posix_spawn(&child, executable, &actions, &attributes, $0.baseAddress!, environ) }
        try check(code)
        return child
    }
}

extension AppleAutomationJournal.PendingOperation {
    fileprivate func matches(_ request: AppleAutomationJournal.OperationRequest) -> Bool {
        operationType == request.operationType &&
        conversationDigest == request.conversationDigest &&
        messageDigest == request.messageDigest &&
        partDigest == request.partDigest &&
        minimumEvidence == request.minimumEvidence
    }
}
