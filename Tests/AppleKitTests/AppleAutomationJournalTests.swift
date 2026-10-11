import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CheckpointFailure: Error {}

private final class BundleMarker: NSObject {}

@Suite("Apple automation journal", .serialized)
struct AppleAutomationJournalTests {
    private let scratch = ScratchDirs("apple-automation-journal")

    private func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }

    private func withScratch(_ name: String, _ body: (URL) throws -> Void) throws {
        let root = try scratch.directory().appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try body(root)
    }

    private func automationJournalProbeURL() throws -> URL {
        let bundle = Bundle(for: BundleMarker.self).bundleURL
        let candidate = bundle.deletingLastPathComponent().appendingPathComponent("AutomationJournalProbe")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw TestFailure("missing AutomationJournalProbe executable next to test bundle")
        }
        return candidate
    }

    private func waitForExit(_ process: Process, seconds: Double) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw TestFailure("subprocess timed out")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func runProbe(_ mode: String, root: URL, expectedStatus: Int32) throws {
        let process = Process()
        process.executableURL = try automationJournalProbeURL()
        process.arguments = [mode, root.path]
        try process.run()
        try waitForExit(process, seconds: 3)
        try assert(process.terminationReason == .exit, "probe exited normally")
        try assert(process.terminationStatus == expectedStatus, "probe \(mode) exited with \(process.terminationStatus)")
    }

    private func digest(_ value: String) throws -> AppleAutomationJournal.TargetDigest {
        try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: value)
    }

    private func request(_ seed: String = "one") throws -> AppleAutomationJournal.OperationRequest {
        try AppleAutomationJournal.OperationRequest(
            operationType: .reactionSet,
            conversationDigest: digest("conversation-\(seed)"),
            messageDigest: digest("message-\(seed)"),
            partDigest: digest("part-\(seed)"),
            minimumEvidence: .init(targetHash: digest("minimum-evidence-\(seed)"), targetLength: 12)
        )
    }

    private func statePath(_ root: URL) -> URL { root.appendingPathComponent("automation-state.json") }
    private func lockPath(_ root: URL) -> URL { root.appendingPathComponent("automation.lock") }

    @Test("creates protected directory and digest-only state")
        func testCreatesProtectedDirectoryAndDigestOnlyState() throws {
        try withScratch("protected") { root in
            var operationID: UUID?
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                operationID = try lease.begin(request())
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.operationID == operationID, "pending persisted under lease")
            }
            var st = stat()
            try assert(lstat(root.path, &st) == 0, "root exists")
            try assert((st.st_mode & S_IFMT) == S_IFDIR, "root is directory")
            try assert((st.st_mode & 0o077) == 0, "root is private")
            try assert(lstat(statePath(root).path, &st) == 0, "state exists")
            try assert((st.st_mode & 0o777) == 0o600, "state is 0600")
            try assert(st.st_nlink == 1, "state has one link")
            try assert(lstat(lockPath(root).path, &st) == 0, "stable lock exists")
            try assert((st.st_mode & 0o777) == 0o600, "lock is 0600")
            try assert(st.st_nlink == 1, "lock has one link")
            let json = try String(contentsOf: statePath(root), encoding: .utf8)
            try assert(json.contains(operationID!.uuidString), "operation UUID persisted")
            try assert(json.contains("sha256:"), "digest persisted")
            try assert(!json.contains("conversation-one"), "raw conversation ID not persisted")
            try assert(!json.contains("message-one"), "raw message ID not persisted")
            try assert(!json.contains("part-one"), "raw part ID not persisted")
        }
    }

    @Test("existing pending blocks begin regardless of age")
        func testExistingPendingBlocksBeginRegardlessOfAge() throws {
        try withScratch("pending-blocks") { root in
            var first: UUID!
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                first = try lease.begin(request("first"))
            }
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do {
                    _ = try lease.begin(request("second"))
                    throw TestFailure("begin should have been blocked")
                } catch AppleAutomationJournal.Error.pendingOperationExists(let op) {
                    try assert(op == first.uuidString, "blocked by original pending op")
                }
            }
        }
    }

    @Test("pending arrays are rejected on decode")
        func testPendingArraysAreRejectedOnDecode() throws {
        try withScratch("pending-arrays") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let op1 = UUID().uuidString
            let op2 = UUID().uuidString
            let d = try digest("x").value
            let entry = { (id: String) in "{\"createdMonotonicNanos\":1,\"conversationDigest\":\"\(d)\",\"messageDigest\":null,\"minimumEvidence\":{\"targetHash\":\"\(d)\",\"targetLength\":1},\"operationID\":\"\(id)\",\"operationType\":\"reactionSet\",\"partDigest\":null,\"phase\":\"preparedBeforeHandoff\"}" }
            for pending in ["[]", "[\(entry(op1))]", "[\(entry(op1)),\(entry(op2))]"] {
                try "{\"version\":1,\"pending\":\(pending),\"receipts\":[]}".write(to: statePath(root), atomically: false, encoding: .utf8)
                chmod(statePath(root).path, 0o600)
                try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                    do { _ = try lease.loadSnapshot(); throw TestFailure("pending array should fail") }
                    catch AppleAutomationJournal.Error.malformedState {}
                }
            }
        }
    }

    @Test("mark uncertain keeps pending and blocks new begins")
        func testMarkUncertainKeepsPendingAndBlocksNewBegins() throws {
        try withScratch("uncertain") { root in
            var operationID: UUID!
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                operationID = try lease.begin(request())
                try lease.markUncertainAfterHandoff(operationID: operationID)
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.phase == .uncertainAfterHandoff, "uncertainty remains pending")
            }
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.begin(request("later")); throw TestFailure("uncertain pending should block") }
                catch AppleAutomationJournal.Error.pendingOperationExists(let op) { try assert(op == operationID.uuidString, "blocked by uncertain op") }
            }
        }
    }

    @Test("no-delivery only before handoff")
        func testNoDeliveryOnlyBeforeHandoff() throws {
        try withScratch("no-delivery") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request("before"))
                try lease.recordNoDeliveryBeforeHandoff(operationID: op)
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending == nil, "pending cleared before handoff")
                try assert(snapshot.receipts.first?.disposition == .noDelivery, "no-delivery receipt")
            }
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request("after"))
                try lease.markUncertainAfterHandoff(operationID: op)
                do { try lease.recordNoDeliveryBeforeHandoff(operationID: op); throw TestFailure("post-handoff no-delivery should fail") }
                catch AppleAutomationJournal.Error.handoffAlreadyOccurred {}
            }
        }
    }

    @Test("explicit recovery requires operation and acknowledgement")
        func testExplicitRecoveryRequiresOperationAndAcknowledgement() throws {
        try withScratch("recover") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request())
                try lease.markUncertainAfterHandoff(operationID: op)
                do { try lease.recover(operationID: op, acknowledgement: .init(operationID: UUID(), lateEffectAcknowledged: true)); throw TestFailure("wrong op recovery should fail") }
                catch AppleAutomationJournal.Error.recoveryAcknowledgementRequired {}
                do { try lease.recover(operationID: op, acknowledgement: .init(operationID: op, lateEffectAcknowledged: false)); throw TestFailure("missing late-effect ack should fail") }
                catch AppleAutomationJournal.Error.recoveryAcknowledgementRequired {}
                try lease.recover(operationID: op, acknowledgement: .init(operationID: op, lateEffectAcknowledged: true))
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending == nil, "pending cleared by explicit recovery")
                try assert(snapshot.receipts.first?.disposition == .recovered, "recovery receipt")
            }
        }
    }

    @Test("explicit recovery requires uncertain phase")
    func testExplicitRecoveryRequiresUncertainPhase() throws {
        try withScratch("recover-prepared") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request())
                do { try lease.recover(operationID: op, acknowledgement: .init(operationID: op, lateEffectAcknowledged: true)); throw TestFailure("prepared recovery should fail") }
                catch AppleAutomationJournal.Error.handoffNotRecorded {}
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.operationID == op, "prepared pending remains after rejected recovery")
                try assert(snapshot.pending?.phase == .preparedBeforeHandoff, "prepared phase remains after rejected recovery")
                try assert(snapshot.receipts.isEmpty, "rejected recovery writes no receipt")
            }
        }
    }

    @Test("observed-state resolution requires uncertain phase")
    func testObservedStateResolutionRequiresUncertainPhase() throws {
        try withScratch("observed-state") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request("observed"))
                do { try lease.recordObservedState(operationID: op); throw TestFailure("prepared observed-state resolution should fail") }
                catch AppleAutomationJournal.Error.handoffNotRecorded {}
                try lease.markUncertainAfterHandoff(operationID: op)
                try lease.recordObservedState(operationID: op)
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending == nil, "observed-state resolution clears uncertain pending")
                try assert(snapshot.receipts.first?.operationID == op, "observed-state receipt records op id")
                try assert(snapshot.receipts.first?.disposition == .observedState, "observed-state receipt disposition")
            }
        }
    }

    @Test("observed-state receipts reject replayed operation IDs")
    func testObservedStateReceiptsRejectReplayedOperationIDs() throws {
        try withScratch("observed-replay") { root in
            let reused = UUID()
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                try lease.beginForTesting(reused, request: request("first"))
                try lease.markUncertainAfterHandoff(operationID: reused)
                try lease.recordObservedState(operationID: reused)
                do { try lease.beginForTesting(reused, request: request("second")); throw TestFailure("observed-state receipt op should not replay") }
                catch AppleAutomationJournal.Error.replayedOperationID(let op) { try assert(op == reused.uuidString, "replay guard names observed op") }
            }
        }
    }

    @Test("observed-state write failure restores uncertain pending")
    func testObservedStateWriteFailureRestoresUncertainPending() throws {
        try withScratch("observed-restore") { root in
            let op = try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let op = try lease.begin(request("restore"))
                try lease.markUncertainAfterHandoff(operationID: op)
                return op
            }
            try AppleAutomationJournal.withLockedJournalForCheckpointTesting(
                root: root.path,
                deadline: .millisecondsFromNow(1_000),
                checkpointHook: AppleAutomationJournal.WriteCheckpointHook(target: .afterRename) { _ in throw CheckpointFailure() }
            ) { lease in
                do { try lease.recordObservedState(operationID: op); throw TestFailure("observed-state checkpoint failure should throw") }
                catch is CheckpointFailure {}
            }
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.operationID == op, "observed-state failure restores pending op")
                try assert(snapshot.pending?.phase == .uncertainAfterHandoff, "restored pending remains uncertain")
                try assert(snapshot.receipts.isEmpty, "observed-state failure writes no receipt")
            }
        }
    }

    @Test("replay operation ID rejected from retained receipts")
        func testReplayOperationIDRejectedFromRetainedReceipts() throws {
        try withScratch("replay") { root in
            let reused = UUID()
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                try lease.beginForTesting(reused, request: request("first"))
                try lease.recordNoDeliveryBeforeHandoff(operationID: reused)
                do { try lease.beginForTesting(reused, request: request("second")); throw TestFailure("reused operation ID should fail") }
                catch AppleAutomationJournal.Error.replayedOperationID(let op) { try assert(op == reused.uuidString, "replay guard names op") }
            }
        }
    }

    @Test("receipt retention never evicts pending")
        func testReceiptRetentionNeverEvictsPending() throws {
        try withScratch("retention") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                for index in 0..<40 {
                    let op = try lease.begin(request("r\(index)"))
                    if index.isMultiple(of: 2) {
                        try lease.markUncertainAfterHandoff(operationID: op)
                        try lease.recordObservedState(operationID: op)
                    } else {
                        try lease.recordNoDeliveryBeforeHandoff(operationID: op)
                    }
                }
                _ = try lease.begin(request("still-pending"))
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.receipts.count == 32, "receipts retained to 32")
                try assert(snapshot.pending != nil, "pending retained despite receipt pruning")
                try assert(snapshot.receipts.contains(where: { $0.disposition == .observedState }), "observed-state receipts participate in retention")
            }
        }
    }

    @Test("strict JSON rejects unknown duplicate malformed too many and duplicate receipts")
        func testStrictJSONRejectsUnknownDuplicateMalformedTooManyAndDuplicateReceipts() throws {
        try withScratch("strict-json") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try "{\"version\":1,\"version\":1,\"pending\":null,\"receipts\":[]}".write(to: statePath(root), atomically: false, encoding: .utf8)
            chmod(statePath(root).path, 0o600)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("duplicate key should fail") }
                catch AppleAutomationJournal.Error.malformedState {}
            }
            let op = UUID().uuidString
            let receipt = "{\"disposition\":\"noDelivery\",\"operationID\":\"\(op)\",\"recordedMonotonicNanos\":1}"
            let duplicate = [receipt, receipt].joined(separator: ",")
            try "{\"version\":1,\"pending\":null,\"receipts\":[\(duplicate)]}".write(to: statePath(root), atomically: false, encoding: .utf8)
            chmod(statePath(root).path, 0o600)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("duplicate receipt operation ID should fail") }
                catch AppleAutomationJournal.Error.malformedState {}
            }
            let many = Array(repeating: receipt, count: 33).joined(separator: ",")
            try "{\"version\":1,\"pending\":null,\"receipts\":[\(many)]}".write(to: statePath(root), atomically: false, encoding: .utf8)
            chmod(statePath(root).path, 0o600)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("receipt count limit should fail") }
                catch AppleAutomationJournal.Error.malformedState {}
            }
        }
    }

    @Test("unsafe paths symlinks and hardlinks rejected")
        func testUnsafePathsSymlinksAndHardlinksRejected() throws {
        try withScratch("unsafe") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
            do { try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in }; throw TestFailure("unsafe permissions should fail") }
            catch AppleAutomationJournal.Error.unsafeStateDirectory {}
        }
        try withScratch("symlink") { root in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            let link = root.appendingPathComponent("link")
            symlink(target.path, link.path)
            do { try AppleAutomationJournal.withLockedJournal(root: link.path, deadline: .millisecondsFromNow(1_000)) { _ in }; throw TestFailure("symlink root should fail") }
            catch AppleAutomationJournal.Error.unsafeStateDirectory {}
        }
        try withScratch("hardlink-state") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in _ = try lease.begin(request()) }
            let linked = root.appendingPathComponent("state-hardlink")
            link(statePath(root).path, linked.path)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("state hardlink should fail") }
                catch AppleAutomationJournal.Error.unsafeStateFile {}
            }
        }
        try withScratch("hardlink-lock") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in }
            let linked = root.appendingPathComponent("lock-hardlink")
            link(lockPath(root).path, linked.path)
            do { try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in }; throw TestFailure("lock hardlink should fail") }
            catch AppleAutomationJournal.Error.unsafeStateFile {}
        }
    }

    @Test("unsafe state files rejected")
        func testUnsafeStateFilesRejected() throws {
        try withScratch("unsafe-state") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try "{}".write(to: statePath(root), atomically: false, encoding: .utf8)
            chmod(statePath(root).path, 0o644)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("unsafe mode should fail") }
                catch AppleAutomationJournal.Error.unsafeStateFile {}
            }
        }
        try withScratch("state-symlink") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let target = root.appendingPathComponent("target.json")
            try "{}".write(to: target, atomically: false, encoding: .utf8)
            symlink(target.path, statePath(root).path)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("state symlink should fail") }
                catch AppleAutomationJournal.Error.unsafeStateFile {}
            }
        }
    }

    @Test("unknown JSON fields rejected")
        func testUnknownJSONFieldsRejected() throws {
        try withScratch("unknown-json") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try "{\"version\":1,\"pending\":null,\"receipts\":[],\"extra\":1}".write(to: statePath(root), atomically: false, encoding: .utf8)
            chmod(statePath(root).path, 0o600)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                do { _ = try lease.loadSnapshot(); throw TestFailure("unknown field should fail") }
                catch AppleAutomationJournal.Error.malformedState {}
            }
        }
    }

    @Test("deeply nested malformed JSON is rejected without child process crash")
    func testDeeplyNestedMalformedJSONRejectedWithoutChildCrash() throws {
        for mode in ["deep-array-state", "deep-object-state"] {
            try withScratch(mode) { root in
                try runProbe(mode, root: root, expectedStatus: 0)
                let bytesBefore = try Data(contentsOf: statePath(root))
                try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                    do { _ = try lease.loadSnapshot(); throw TestFailure("deep malformed state should fail") }
                    catch AppleAutomationJournal.Error.malformedState {}
                    do { _ = try lease.begin(request("blocked")); throw TestFailure("malformed state should block begin") }
                    catch AppleAutomationJournal.Error.malformedState {}
                }
                let bytesAfter = try Data(contentsOf: statePath(root))
                try assert(bytesAfter == bytesBefore, "malformed state bytes preserved after refused access")
            }
        }
    }

    @Test("competing processes deadline and cancellation")
        func testCompetingProcessesDeadlineAndCancellation() throws {
        try withScratch("lock") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in
                try runProbe("lock-probe", root: root, expectedStatus: 0)
                do { try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000), isCancelled: { true }) { _ in }; throw TestFailure("cancelled lock wait should fail") }
                catch AppleAutomationJournal.Error.cancelled {}
            }
        }
    }

    @Test("lease cannot be used after scope")
        func testLeaseCannotBeUsedAfterScope() throws {
        try withScratch("lease-scope") { root in
            var escaped: AppleAutomationJournal.JournalLease?
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in escaped = lease }
            do { _ = try escaped?.loadSnapshot(); throw TestFailure("escaped lease should be inactive") }
            catch AppleAutomationJournal.Error.leaseExpired {}
        }
    }

    @Test("lock file is stable and never unlinked")
        func testLockFileIsStableAndNeverUnlinked() throws {
        try withScratch("stable-lock") { root in
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in }
            var before = stat()
            try assert(lstat(lockPath(root).path, &before) == 0, "lock exists before second open")
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { _ in }
            var after = stat()
            try assert(lstat(lockPath(root).path, &after) == 0, "lock exists after second open")
            try assert(before.st_ino == after.st_ino && before.st_dev == after.st_dev, "lock inode stays stable")
        }
    }

    @Test("process crash after durable begin leaves pending blocking begin")
        func testProcessCrashAfterDurableBeginLeavesPendingBlockingBegin() throws {
        try withScratch("crash-begin") { root in
            try runProbe("crash-after-begin", root: root, expectedStatus: 42)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.phase == .preparedBeforeHandoff, "durable begin visible after process crash")
                do { _ = try lease.begin(request("blocked")); throw TestFailure("pending should block") }
                catch AppleAutomationJournal.Error.pendingOperationExists {}
            }
        }
    }

    @Test("process crash after mark uncertain leaves uncertain pending")
        func testProcessCrashAfterMarkUncertainLeavesUncertainPending() throws {
        try withScratch("crash-uncertain") { root in
            try runProbe("crash-after-uncertain", root: root, expectedStatus: 42)
            try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                let snapshot = try lease.loadSnapshot()
                try assert(snapshot.pending?.phase == .uncertainAfterHandoff, "uncertain phase persisted before process crash")
                do { _ = try lease.begin(request("blocked")); throw TestFailure("uncertain pending should block") }
                catch AppleAutomationJournal.Error.pendingOperationExists {}
            }
        }
    }

    @Test("process crash during atomic replacement leaves old or new valid snapshot")
        func testProcessCrashDuringAtomicReplacementLeavesOldOrNewValidSnapshot() throws {
        for mode in ["crash-before-rename", "crash-after-rename"] {
            try withScratch(mode) { root in
                try runProbe(mode, root: root, expectedStatus: 42)
                try AppleAutomationJournal.withLockedJournal(root: root.path, deadline: .millisecondsFromNow(1_000)) { lease in
                    let snapshot = try lease.loadSnapshot()
                    let oldValid = snapshot.pending != nil && snapshot.receipts.isEmpty
                    let newValid = snapshot.pending == nil && snapshot.receipts.count == 1 && snapshot.receipts[0].disposition == .noDelivery
                    try assert(oldValid || newValid, "snapshot is old or new valid state after \(mode)")
                    if oldValid {
                        do { _ = try lease.begin(request("blocked")); throw TestFailure("old pending should block") }
                        catch AppleAutomationJournal.Error.pendingOperationExists {}
                        try lease.recordNoDeliveryBeforeHandoff(operationID: try #require(snapshot.pending?.operationID))
                    }
                }
            }
        }
    }

}
