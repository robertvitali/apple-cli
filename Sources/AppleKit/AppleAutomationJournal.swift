import Foundation
import Darwin
import CryptoKit

public enum AppleAutomationJournal {
    public static let stateFileName = "automation-state.json"
    public static let lockFileName = "automation.lock"
    private static let schemaVersion = 1
    private static let maxStateBytes = 256 * 1024
    private static let maxReceipts = 32
    private static let maxDigestBytes = 71 // "sha256:" + 64 hex chars

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsafeStateDirectory
        case unsafeStateFile
        case lockTimedOut
        case cancelled
        case leaseExpired
        case malformedState
        case pendingOperationExists(String)
        case operationNotFound(String)
        case replayedOperationID(String)
        case handoffAlreadyOccurred
        case handoffNotRecorded
        case recoveryAcknowledgementRequired
        case syscall(String)

        public var description: String {
            switch self {
            case .unsafeStateDirectory: return "unsafe-state-directory"
            case .unsafeStateFile: return "unsafe-state-file"
            case .lockTimedOut: return "lock-timed-out"
            case .cancelled: return "cancelled"
            case .leaseExpired: return "lease-expired"
            case .malformedState: return "malformed-state"
            case .pendingOperationExists(let op): return "pending-operation-exists:\(op)"
            case .operationNotFound(let op): return "operation-not-found:\(op)"
            case .replayedOperationID(let op): return "replayed-operation-id:\(op)"
            case .handoffAlreadyOccurred: return "handoff-already-occurred"
            case .handoffNotRecorded: return "handoff-not-recorded"
            case .recoveryAcknowledgementRequired: return "recovery-acknowledgement-required"
            case .syscall(let name): return "syscall-failed:\(name)"
            }
        }
    }

    public struct MonotonicDeadline: Equatable {
        fileprivate let uptimeNanoseconds: UInt64
        public static func millisecondsFromNow(_ milliseconds: UInt64) -> MonotonicDeadline {
            let now = DispatchTime.now().uptimeNanoseconds
            let add = milliseconds > UInt64.max / 1_000_000 ? UInt64.max : milliseconds * 1_000_000
            return MonotonicDeadline(uptimeNanoseconds: now > UInt64.max - add ? UInt64.max : now + add)
        }
        fileprivate var expired: Bool { DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds }
    }

    package enum WriteCheckpoint: String, Equatable {
        case beforeRename
        case afterRename
        case afterDurableBegin
        case afterDurableMarkUncertain
    }

    package struct WriteCheckpointHook {
        let target: WriteCheckpoint
        let action: (WriteCheckpoint) -> Void
        package init(target: WriteCheckpoint, action: @escaping (WriteCheckpoint) -> Void) {
            self.target = target
            self.action = action
        }
    }

    enum WritePurpose { case ordinary, begin, markUncertain, resolve }

    public struct TargetDigest: Equatable {
        public let value: String
        fileprivate init(value: String) { self.value = value }
    }

    /// Hashes an exact target identifier before persistence. Future worker/verifier code must
    /// keep the raw identifier in memory and bind it to this digest when proving completion;
    /// this substrate intentionally persists only the fixed SHA-256 digest string.
    public static func targetDigest(forOpaqueIdentifier identifier: String) throws -> TargetDigest {
        guard let data = identifier.data(using: .utf8), !data.isEmpty, data.count <= 4096 else { throw Error.malformedState }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return TargetDigest(value: "sha256:\(hex)")
    }

    public struct Snapshot: Equatable {
        public var pending: PendingOperation?
        public var receipts: [Receipt]
        public init(pending: PendingOperation? = nil, receipts: [Receipt] = []) {
            self.pending = pending
            self.receipts = receipts
        }
    }

    public struct OperationRequest: Equatable {
        public let operationType: PendingOperation.OperationType
        public let conversationDigest: TargetDigest
        public let messageDigest: TargetDigest?
        public let partDigest: TargetDigest?
        public let minimumEvidence: PendingOperation.MinimumEvidence
        public init(operationType: PendingOperation.OperationType,
                    conversationDigest: TargetDigest,
                    messageDigest: TargetDigest?,
                    partDigest: TargetDigest?,
                    minimumEvidence: PendingOperation.MinimumEvidence) {
            self.operationType = operationType
            self.conversationDigest = conversationDigest
            self.messageDigest = messageDigest
            self.partDigest = partDigest
            self.minimumEvidence = minimumEvidence
        }
    }

    public struct PendingOperation: Equatable {
        public enum OperationType: String, Equatable, CaseIterable { case reactionSet, replySend, editMessage, undoSend, readState, muteState }
        public enum Phase: String, Equatable, CaseIterable { case preparedBeforeHandoff, uncertainAfterHandoff }
        public struct MinimumEvidence: Equatable {
            public let targetHash: TargetDigest
            public let targetLength: Int
            public init(targetHash: TargetDigest, targetLength: Int) {
                self.targetHash = targetHash
                self.targetLength = targetLength
            }
        }
        public let operationID: UUID
        public let operationType: OperationType
        public let conversationDigest: TargetDigest
        public let messageDigest: TargetDigest?
        public let partDigest: TargetDigest?
        public let minimumEvidence: MinimumEvidence
        public let phase: Phase
        public let createdMonotonicNanos: UInt64

        fileprivate init(operationID: UUID,
                         operationType: OperationType,
                         conversationDigest: TargetDigest,
                         messageDigest: TargetDigest?,
                         partDigest: TargetDigest?,
                         minimumEvidence: MinimumEvidence,
                         phase: Phase,
                         createdMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.operationID = operationID
            self.operationType = operationType
            self.conversationDigest = conversationDigest
            self.messageDigest = messageDigest
            self.partDigest = partDigest
            self.minimumEvidence = minimumEvidence
            self.phase = phase
            self.createdMonotonicNanos = createdMonotonicNanos
        }

        fileprivate func replacingPhase(_ phase: Phase) -> PendingOperation {
            PendingOperation(operationID: operationID,
                             operationType: operationType,
                             conversationDigest: conversationDigest,
                             messageDigest: messageDigest,
                             partDigest: partDigest,
                             minimumEvidence: minimumEvidence,
                             phase: phase,
                             createdMonotonicNanos: createdMonotonicNanos)
        }
    }

    public struct Receipt: Equatable {
        public enum Disposition: String, Equatable, CaseIterable { case recovered, noDelivery }
        public let operationID: UUID
        public let disposition: Disposition
        public let recordedMonotonicNanos: UInt64
        public init(operationID: UUID, disposition: Disposition, recordedMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.operationID = operationID
            self.disposition = disposition
            self.recordedMonotonicNanos = recordedMonotonicNanos
        }
    }

    public struct RecoveryAcknowledgement: Equatable {
        public let operationID: UUID
        public let lateEffectAcknowledged: Bool
        public init(operationID: UUID, lateEffectAcknowledged: Bool) {
            self.operationID = operationID
            self.lateEffectAcknowledged = lateEffectAcknowledged
        }
    }

    public final class JournalLease {
        private let rootFD: Int32
        private let checkpointHook: WriteCheckpointHook?
        private var active = true
        fileprivate init(rootFD: Int32, checkpointHook: WriteCheckpointHook? = nil) {
            self.rootFD = rootFD
            self.checkpointHook = checkpointHook
        }
        deinit { active = false }

        public func loadSnapshot() throws -> Snapshot {
            try requireActive()
            return try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
        }

        public func begin(_ request: OperationRequest) throws -> UUID {
            try requireActive()
            try validate(request)
            var snapshot = try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
            if let existing = snapshot.pending { throw Error.pendingOperationExists(existing.operationID.uuidString) }
            var operationID = UUID()
            while hasReceipt(operationID, in: snapshot) { operationID = UUID() }
            let operation = PendingOperation(operationID: operationID,
                                             operationType: request.operationType,
                                             conversationDigest: request.conversationDigest,
                                             messageDigest: request.messageDigest,
                                             partDigest: request.partDigest,
                                             minimumEvidence: request.minimumEvidence,
                                             phase: .preparedBeforeHandoff)
            snapshot.pending = operation
            try AppleAutomationJournal.writeSnapshot(snapshot, rootFD: rootFD, purpose: .begin, checkpointHook: checkpointHook)
            return operationID
        }

        /// Durably records that the operation may have crossed the worker handoff boundary.
        ///
        /// Callers must invoke this before performing any action that could hand the request to
        /// another process or subsystem. The method name describes the persisted phase, not the
        /// call order: writing uncertainty first ensures a crash around handoff leaves a blocking
        /// pending operation instead of a falsely recoverable prepared operation.
        public func markUncertainAfterHandoff(operationID: UUID) throws {
            try requireActive()
            var snapshot = try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
            guard let pending = snapshot.pending, pending.operationID == operationID else { throw Error.operationNotFound(operationID.uuidString) }
            snapshot.pending = pending.replacingPhase(.uncertainAfterHandoff)
            try AppleAutomationJournal.writeSnapshot(snapshot, rootFD: rootFD, purpose: .markUncertain, checkpointHook: checkpointHook)
        }

        /// Public post-handoff causal completion is intentionally deferred until a real worker
        /// verifier exists. Recovery is the explicit operator path for unresolved uncertainty.
        public func recover(operationID: UUID, acknowledgement: RecoveryAcknowledgement) throws {
            try requireActive()
            guard acknowledgement.operationID == operationID, acknowledgement.lateEffectAcknowledged else {
                throw Error.recoveryAcknowledgementRequired
            }
            try resolve(operationID: operationID, disposition: .recovered)
        }

        public func recordNoDeliveryBeforeHandoff(operationID: UUID) throws {
            try requireActive()
            var snapshot = try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
            guard let pending = snapshot.pending, pending.operationID == operationID else { throw Error.operationNotFound(operationID.uuidString) }
            guard pending.phase == .preparedBeforeHandoff else { throw Error.handoffAlreadyOccurred }
            snapshot.pending = nil
            appendReceipt(&snapshot, Receipt(operationID: operationID, disposition: .noDelivery))
            try AppleAutomationJournal.writeSnapshot(snapshot, rootFD: rootFD, purpose: .resolve, checkpointHook: checkpointHook)
        }

        // Test seam for replay-guard regression only; production callers use begin(_:) so
        // operation IDs are generated inside the journal substrate.
        func beginForTesting(_ operationID: UUID, request: OperationRequest) throws {
            try requireActive()
            try validate(request)
            var snapshot = try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
            if let existing = snapshot.pending { throw Error.pendingOperationExists(existing.operationID.uuidString) }
            guard !hasReceipt(operationID, in: snapshot) else { throw Error.replayedOperationID(operationID.uuidString) }
            snapshot.pending = PendingOperation(operationID: operationID,
                                                operationType: request.operationType,
                                                conversationDigest: request.conversationDigest,
                                                messageDigest: request.messageDigest,
                                                partDigest: request.partDigest,
                                                minimumEvidence: request.minimumEvidence,
                                                phase: .preparedBeforeHandoff)
            try AppleAutomationJournal.writeSnapshot(snapshot, rootFD: rootFD, purpose: .begin, checkpointHook: checkpointHook)
        }

        fileprivate func expire() { active = false }

        private func resolve(operationID: UUID, disposition: Receipt.Disposition) throws {
            var snapshot = try AppleAutomationJournal.readSnapshot(rootFD: rootFD)
            guard let pending = snapshot.pending, pending.operationID == operationID else { throw Error.operationNotFound(operationID.uuidString) }
            guard pending.phase == .uncertainAfterHandoff else { throw Error.handoffNotRecorded }
            snapshot.pending = nil
            appendReceipt(&snapshot, Receipt(operationID: operationID, disposition: disposition))
            try AppleAutomationJournal.writeSnapshot(snapshot, rootFD: rootFD, purpose: .resolve, checkpointHook: checkpointHook)
        }

        private func appendReceipt(_ snapshot: inout Snapshot, _ receipt: Receipt) {
            snapshot.receipts.append(receipt)
            if snapshot.receipts.count > AppleAutomationJournal.maxReceipts {
                snapshot.receipts.removeFirst(snapshot.receipts.count - AppleAutomationJournal.maxReceipts)
            }
        }

        private func hasReceipt(_ operationID: UUID, in snapshot: Snapshot) -> Bool {
            snapshot.receipts.contains { $0.operationID == operationID }
        }

        private func requireActive() throws {
            guard active else { throw Error.leaseExpired }
        }
    }

    public static func withLockedJournal<T>(root: String,
                                            deadline: MonotonicDeadline,
                                            isCancelled: () -> Bool = { false },
                                            _ body: (JournalLease) throws -> T) throws -> T {
        let handles = try openRootAndLock(root: root)
        defer {
            _ = flock(handles.lockFD, LOCK_UN)
            close(handles.lockFD)
            close(handles.rootFD)
        }
        try acquireLock(handles.lockFD, deadline: deadline, isCancelled: isCancelled)
        let lease = JournalLease(rootFD: handles.rootFD)
        defer { lease.expire() }
        return try body(lease)
    }

    package static func withLockedJournalForCheckpointTesting<T>(root: String,
                                                                  deadline: MonotonicDeadline,
                                                                  checkpointHook: WriteCheckpointHook,
                                                                  _ body: (JournalLease) throws -> T) throws -> T {
        let handles = try openRootAndLock(root: root)
        defer {
            _ = flock(handles.lockFD, LOCK_UN)
            close(handles.lockFD)
            close(handles.rootFD)
        }
        try acquireLock(handles.lockFD, deadline: deadline, isCancelled: { false })
        let lease = JournalLease(rootFD: handles.rootFD, checkpointHook: checkpointHook)
        defer { lease.expire() }
        return try body(lease)
    }

    private struct Handles { let rootFD: Int32; let lockFD: Int32 }

    private static func openRootAndLock(root: String) throws -> Handles {
        try ensureRootDirectory(root)
        var pathStat = stat()
        guard lstat(root, &pathStat) == 0 else { throw Error.unsafeStateDirectory }
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw Error.unsafeStateDirectory }
        do {
            try validateDirectoryFD(rootFD, matches: pathStat)
            let lockFD = try openLock(rootFD: rootFD)
            return Handles(rootFD: rootFD, lockFD: lockFD)
        } catch {
            close(rootFD)
            throw error
        }
    }

    private static func ensureRootDirectory(_ root: String) throws {
        var st = stat()
        if lstat(root, &st) != 0 {
            guard errno == ENOENT else { throw Error.unsafeStateDirectory }
            guard mkdir(root, 0o700) == 0 else { throw Error.syscall("mkdir") }
            guard lstat(root, &st) == 0 else { throw Error.unsafeStateDirectory }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Error.unsafeStateDirectory }
        guard st.st_uid == getuid() else { throw Error.unsafeStateDirectory }
        guard (st.st_mode & 0o077) == 0 else { throw Error.unsafeStateDirectory }
    }

    private static func validateDirectoryFD(_ fd: Int32, matches pathStat: stat) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Error.unsafeStateDirectory }
        guard st.st_dev == pathStat.st_dev, st.st_ino == pathStat.st_ino else { throw Error.unsafeStateDirectory }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Error.unsafeStateDirectory }
        guard st.st_uid == getuid() else { throw Error.unsafeStateDirectory }
        guard (st.st_mode & 0o077) == 0 else { throw Error.unsafeStateDirectory }
    }

    private static func openLock(rootFD: Int32) throws -> Int32 {
        var created = false
        var fd = openat(rootFD, lockFileName, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd >= 0 { created = true }
        else if errno == EEXIST { fd = openat(rootFD, lockFileName, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw Error.unsafeStateFile }
        do {
            var pathStat = stat()
            guard fstatat(rootFD, lockFileName, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw Error.unsafeStateFile }
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw Error.unsafeStateFile }
            guard st.st_dev == pathStat.st_dev, st.st_ino == pathStat.st_ino else { throw Error.unsafeStateFile }
            guard st.st_nlink == 1 else { throw Error.unsafeStateFile }
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw Error.unsafeStateFile }
            guard st.st_uid == getuid() else { throw Error.unsafeStateFile }
            if created { guard fchmod(fd, 0o600) == 0 else { throw Error.syscall("fchmod") } }
            else { guard (st.st_mode & 0o777) == 0o600 else { throw Error.unsafeStateFile } }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func acquireLock(_ fd: Int32, deadline: MonotonicDeadline, isCancelled: () -> Bool) throws {
        while true {
            if isCancelled() { throw Error.cancelled }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else { throw Error.syscall("flock") }
            if deadline.expired { throw Error.lockTimedOut }
            usleep(10_000)
        }
    }

    private static func readSnapshot(rootFD: Int32) throws -> Snapshot {
        let fd = openat(rootFD, stateFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            guard errno == ENOENT else { throw Error.unsafeStateFile }
            return Snapshot()
        }
        defer { close(fd) }
        try validateStateFD(fd, rootFD: rootFD)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Error.unsafeStateFile }
        guard st.st_size <= maxStateBytes else { throw Error.malformedState }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw Error.syscall("read") }
            if count == 0 { break }
            guard data.count + count <= maxStateBytes else { throw Error.malformedState }
            data.append(buffer, count: count)
        }
        return try decodeSnapshot(data)
    }

    private static func validateStateFD(_ fd: Int32, rootFD: Int32) throws {
        var pathStat = stat()
        guard fstatat(rootFD, stateFileName, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw Error.unsafeStateFile }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Error.unsafeStateFile }
        guard st.st_dev == pathStat.st_dev, st.st_ino == pathStat.st_ino else { throw Error.unsafeStateFile }
        guard st.st_nlink == 1 else { throw Error.unsafeStateFile }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Error.unsafeStateFile }
        guard st.st_uid == getuid() else { throw Error.unsafeStateFile }
        guard (st.st_mode & 0o777) == 0o600 else { throw Error.unsafeStateFile }
    }

    private static func writeSnapshot(_ snapshot: Snapshot,
                                      rootFD: Int32,
                                      purpose: WritePurpose = .ordinary,
                                      checkpointHook: WriteCheckpointHook? = nil) throws {
        try validate(snapshot)
        let data = try encodeSnapshot(snapshot)
        guard data.count <= maxStateBytes else { throw Error.malformedState }
        let tempName = ".automation-state.tmp.\(getpid()).\(UUID().uuidString)"
        let fd = openat(rootFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.syscall("openat-temp") }
        var shouldUnlink = true
        defer {
            close(fd)
            if shouldUnlink { unlinkat(rootFD, tempName, 0) }
        }
        guard fchmod(fd, 0o600) == 0 else { throw Error.syscall("fchmod-temp") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 { throw Error.syscall("write") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw Error.syscall("fsync-state") }
        fireCheckpoint(.beforeRename, hook: checkpointHook)
        guard renameat(rootFD, tempName, rootFD, stateFileName) == 0 else { throw Error.syscall("renameat") }
        shouldUnlink = false
        fireCheckpoint(.afterRename, hook: checkpointHook)
        guard fsync(rootFD) == 0 else { throw Error.syscall("fsync-dir") }
        switch purpose {
        case .begin:
            fireCheckpoint(.afterDurableBegin, hook: checkpointHook)
        case .markUncertain:
            fireCheckpoint(.afterDurableMarkUncertain, hook: checkpointHook)
        case .ordinary, .resolve:
            break
        }
    }

    private static func fireCheckpoint(_ checkpoint: WriteCheckpoint, hook: WriteCheckpointHook?) {
        guard hook?.target == checkpoint else { return }
        hook?.action(checkpoint)
    }

    private static func encodeSnapshot(_ snapshot: Snapshot) throws -> Data {
        let pending: JSONValue = snapshot.pending.map(encodePending) ?? .null
        let root: [String: JSONValue] = [
            "version": .number(schemaVersion),
            "pending": pending,
            "receipts": .array(snapshot.receipts.map(encodeReceipt))
        ]
        return serialize(.object(root)).data(using: .utf8)!
    }

    private static func encodePending(_ op: PendingOperation) -> JSONValue {
        var object: [String: JSONValue] = [
            "operationID": .string(op.operationID.uuidString),
            "operationType": .string(op.operationType.rawValue),
            "conversationDigest": .string(op.conversationDigest.value),
            "minimumEvidence": .object([
                "targetHash": .string(op.minimumEvidence.targetHash.value),
                "targetLength": .number(op.minimumEvidence.targetLength)
            ]),
            "phase": .string(op.phase.rawValue),
            "createdMonotonicNanos": .number(Int(op.createdMonotonicNanos))
        ]
        object["messageDigest"] = op.messageDigest.map { .string($0.value) } ?? .null
        object["partDigest"] = op.partDigest.map { .string($0.value) } ?? .null
        return .object(object)
    }

    private static func encodeReceipt(_ receipt: Receipt) -> JSONValue {
        .object([
            "operationID": .string(receipt.operationID.uuidString),
            "disposition": .string(receipt.disposition.rawValue),
            "recordedMonotonicNanos": .number(Int(receipt.recordedMonotonicNanos))
        ])
    }

    private static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        guard !data.isEmpty, data.count <= maxStateBytes else { throw Error.malformedState }
        let value = try StrictJSONParser(data: data).parse()
        guard case .object(let root) = value else { throw Error.malformedState }
        try requireKeys(root, exactly: ["version", "pending", "receipts"])
        guard case .number(let version) = root["version"], version == schemaVersion else { throw Error.malformedState }
        let pending: PendingOperation?
        guard let pendingValue = root["pending"] else { throw Error.malformedState }
        switch pendingValue {
        case .null:
            pending = nil
        case .object(let object):
            pending = try decodePending(.object(object))
        default:
            throw Error.malformedState
        }
        guard case .array(let receiptValues) = root["receipts"] else { throw Error.malformedState }
        guard receiptValues.count <= maxReceipts else { throw Error.malformedState }
        let receipts = try receiptValues.map(decodeReceipt)
        let receiptIDs = receipts.map(\.operationID)
        guard Set(receiptIDs).count == receiptIDs.count else { throw Error.malformedState }
        if let pending, receipts.contains(where: { $0.operationID == pending.operationID }) { throw Error.malformedState }
        return Snapshot(pending: pending, receipts: receipts)
    }

    private static func decodePending(_ value: JSONValue) throws -> PendingOperation {
        guard case .object(let object) = value else { throw Error.malformedState }
        try requireKeys(object, exactly: ["operationID", "operationType", "conversationDigest", "messageDigest", "partDigest", "minimumEvidence", "phase", "createdMonotonicNanos"])
        guard case .string(let operationIDString) = object["operationID"], let operationID = UUID(uuidString: operationIDString) else { throw Error.malformedState }
        guard case .string(let opTypeRaw) = object["operationType"], let operationType = PendingOperation.OperationType(rawValue: opTypeRaw) else { throw Error.malformedState }
        let conversationDigest = try requiredDigest(object["conversationDigest"])
        let messageDigest = try optionalDigest(object["messageDigest"])
        let partDigest = try optionalDigest(object["partDigest"])
        guard case .object(let evidenceObject) = object["minimumEvidence"] else { throw Error.malformedState }
        try requireKeys(evidenceObject, exactly: ["targetHash", "targetLength"])
        let targetHash = try requiredDigest(evidenceObject["targetHash"])
        guard case .number(let targetLength) = evidenceObject["targetLength"], targetLength >= 0 else { throw Error.malformedState }
        guard case .string(let phaseRaw) = object["phase"], let phase = PendingOperation.Phase(rawValue: phaseRaw) else { throw Error.malformedState }
        guard case .number(let created) = object["createdMonotonicNanos"], created >= 0 else { throw Error.malformedState }
        let op = PendingOperation(operationID: operationID,
                                  operationType: operationType,
                                  conversationDigest: conversationDigest,
                                  messageDigest: messageDigest,
                                  partDigest: partDigest,
                                  minimumEvidence: .init(targetHash: targetHash, targetLength: targetLength),
                                  phase: phase,
                                  createdMonotonicNanos: UInt64(created))
        try validate(op)
        return op
    }

    private static func decodeReceipt(_ value: JSONValue) throws -> Receipt {
        guard case .object(let object) = value else { throw Error.malformedState }
        try requireKeys(object, exactly: ["operationID", "disposition", "recordedMonotonicNanos"])
        guard case .string(let operationIDString) = object["operationID"], let operationID = UUID(uuidString: operationIDString) else { throw Error.malformedState }
        guard case .string(let dispositionRaw) = object["disposition"], let disposition = Receipt.Disposition(rawValue: dispositionRaw) else { throw Error.malformedState }
        guard case .number(let recorded) = object["recordedMonotonicNanos"], recorded >= 0 else { throw Error.malformedState }
        return Receipt(operationID: operationID, disposition: disposition, recordedMonotonicNanos: UInt64(recorded))
    }

    private static func optionalDigest(_ value: JSONValue?) throws -> TargetDigest? {
        guard let value else { throw Error.malformedState }
        switch value {
        case .null: return nil
        case .string(let string): return try parseDigest(string)
        default: throw Error.malformedState
        }
    }

    private static func requiredDigest(_ value: JSONValue?) throws -> TargetDigest {
        guard case .string(let string) = value else { throw Error.malformedState }
        return try parseDigest(string)
    }

    private static func parseDigest(_ value: String) throws -> TargetDigest {
        try validateDigest(value)
        return TargetDigest(value: value)
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.receipts.count <= maxReceipts else { throw Error.malformedState }
        if let pending = snapshot.pending {
            try validate(pending)
            guard !snapshot.receipts.contains(where: { $0.operationID == pending.operationID }) else { throw Error.replayedOperationID(pending.operationID.uuidString) }
        }
    }

    private static func validate(_ request: OperationRequest) throws {
        try validateDigest(request.conversationDigest.value)
        if let messageDigest = request.messageDigest { try validateDigest(messageDigest.value) }
        if let partDigest = request.partDigest { try validateDigest(partDigest.value) }
        try validateDigest(request.minimumEvidence.targetHash.value)
        guard request.minimumEvidence.targetLength >= 0 else { throw Error.malformedState }
    }

    private static func validate(_ op: PendingOperation) throws {
        try validateDigest(op.conversationDigest.value)
        if let messageDigest = op.messageDigest { try validateDigest(messageDigest.value) }
        if let partDigest = op.partDigest { try validateDigest(partDigest.value) }
        try validateDigest(op.minimumEvidence.targetHash.value)
        guard op.minimumEvidence.targetLength >= 0 else { throw Error.malformedState }
    }

    private static func validateDigest(_ value: String) throws {
        guard value.utf8.count == maxDigestBytes, value.hasPrefix("sha256:") else { throw Error.malformedState }
        let hex = value.dropFirst(7)
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }) else { throw Error.malformedState }
    }

    private static func requireKeys(_ object: [String: JSONValue], exactly allowed: Set<String>) throws {
        guard Set(object.keys) == allowed else { throw Error.malformedState }
    }
}

private enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Int)
    case null
}

private func serialize(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .number(let number): return String(number)
    case .string(let string): return "\"" + string.flatMap { ch -> String in
        switch ch {
        case "\\": return "\\\\"
        case "\"": return "\\\""
        default: return String(ch)
        }
    } + "\""
    case .array(let array): return "[" + array.map(serialize).joined(separator: ",") + "]"
    case .object(let object):
        return "{" + object.keys.sorted().map { key in serialize(.string(key)) + ":" + serialize(object[key]!) }.joined(separator: ",") + "}"
    }
}

private struct StrictJSONParser {
    private static let maxNestingDepth = 32

    let bytes: [UInt8]
    var index = 0
    init(data: Data) { bytes = Array(data) }

    func parse() throws -> JSONValue {
        var parser = self
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw AppleAutomationJournal.Error.malformedState }
        return value
    }

    mutating private func parseValue(depth: Int) throws -> JSONValue {
        skipWhitespace()
        guard let b = peek() else { throw AppleAutomationJournal.Error.malformedState }
        switch b {
        case 0x7b: return try parseObject(depth: depth)
        case 0x5b: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x6e: try consumeLiteral("null"); return .null
        case 0x2d, 0x30...0x39: return .number(try parseInteger())
        default: throw AppleAutomationJournal.Error.malformedState
        }
    }

    mutating private func parseObject(depth: Int) throws -> JSONValue {
        guard depth < Self.maxNestingDepth else { throw AppleAutomationJournal.Error.malformedState }
        try expect(0x7b)
        skipWhitespace()
        var object: [String: JSONValue] = [:]
        if consumeIf(0x7d) { return .object(object) }
        while true {
            skipWhitespace()
            guard peek() == 0x22 else { throw AppleAutomationJournal.Error.malformedState }
            let key = try parseString()
            guard object[key] == nil else { throw AppleAutomationJournal.Error.malformedState }
            skipWhitespace()
            try expect(0x3a)
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x7d) { break }
            try expect(0x2c)
        }
        return .object(object)
    }

    mutating private func parseArray(depth: Int) throws -> JSONValue {
        guard depth < Self.maxNestingDepth else { throw AppleAutomationJournal.Error.malformedState }
        try expect(0x5b)
        skipWhitespace()
        var array: [JSONValue] = []
        if consumeIf(0x5d) { return .array(array) }
        while true {
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if consumeIf(0x5d) { break }
            try expect(0x2c)
        }
        return .array(array)
    }

    mutating private func parseString() throws -> String {
        try expect(0x22)
        var scalars: [UInt8] = []
        while let b = peek() {
            index += 1
            if b == 0x22 {
                guard let s = String(bytes: scalars, encoding: .utf8) else { throw AppleAutomationJournal.Error.malformedState }
                return s
            }
            if b == 0x5c {
                guard let escaped = peek() else { throw AppleAutomationJournal.Error.malformedState }
                index += 1
                switch escaped {
                case 0x22, 0x5c, 0x2f: scalars.append(escaped)
                case 0x62: scalars.append(0x08)
                case 0x66: scalars.append(0x0c)
                case 0x6e: scalars.append(0x0a)
                case 0x72: scalars.append(0x0d)
                case 0x74: scalars.append(0x09)
                default: throw AppleAutomationJournal.Error.malformedState
                }
            } else {
                guard b >= 0x20 else { throw AppleAutomationJournal.Error.malformedState }
                scalars.append(b)
            }
        }
        throw AppleAutomationJournal.Error.malformedState
    }

    mutating private func parseInteger() throws -> Int {
        let start = index
        _ = consumeIf(0x2d)
        guard let first = peek(), first >= 0x30 && first <= 0x39 else { throw AppleAutomationJournal.Error.malformedState }
        if first == 0x30 { index += 1 }
        else { while let b = peek(), b >= 0x30 && b <= 0x39 { index += 1 } }
        let text = String(bytes: bytes[start..<index], encoding: .utf8)!
        guard let value = Int(text) else { throw AppleAutomationJournal.Error.malformedState }
        return value
    }

    mutating private func consumeLiteral(_ literal: String) throws { for b in literal.utf8 { try expect(b) } }
    mutating private func skipWhitespace() { while let b = peek(), b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 { index += 1 } }
    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    mutating private func consumeIf(_ b: UInt8) -> Bool { if peek() == b { index += 1; return true }; return false }
    mutating private func expect(_ b: UInt8) throws { guard consumeIf(b) else { throw AppleAutomationJournal.Error.malformedState } }
}
