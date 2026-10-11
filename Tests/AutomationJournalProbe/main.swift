import Darwin
import Foundation
import AppleKit

private enum ExitCode: Int32 {
    case usage = 64
    case timedOutAsExpected = 0
    case acquiredUnexpectedly = 2
    case unexpectedError = 3
    case checkpointReached = 42
    case checkpointDidNotFire = 43
}

private func finish(_ code: ExitCode) -> Never {
    Darwin.exit(code.rawValue)
}

private func digest(_ value: String) throws -> AppleAutomationJournal.TargetDigest {
    try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: value)
}

private func request(_ seed: String) throws -> AppleAutomationJournal.OperationRequest {
    try AppleAutomationJournal.OperationRequest(
        operationType: .reactionSet,
        conversationDigest: digest("conversation-\(seed)"),
        messageDigest: digest("message-\(seed)"),
        partDigest: digest("part-\(seed)"),
        minimumEvidence: .init(targetHash: digest("minimum-evidence-\(seed)"), targetLength: 12)
    )
}

private func crashHook(_ checkpoint: AppleAutomationJournal.WriteCheckpoint) -> AppleAutomationJournal.WriteCheckpointHook {
    AppleAutomationJournal.WriteCheckpointHook(target: checkpoint) { _ in
        Darwin._exit(ExitCode.checkpointReached.rawValue)
    }
}

private func pendingOperationID(root: String) throws -> UUID {
    try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
        if let pending = try lease.loadSnapshot().pending { return pending.operationID }
        return try lease.begin(request("resolve-seed"))
    }
}

private func malformedDeepState(container: String, depth: Int) -> String {
    let open = container == "array" ? "[" : "{\"nested\":"
    let close = container == "array" ? "]" : "}"
    return "{\"version\":1,\"pending\":null,\"receipts\":"
        + String(repeating: open, count: depth)
        + "[]"
        + String(repeating: close, count: depth)
        + "}"
}

private func writeMalformedDeepState(root: String, container: String) throws {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    let stateURL = rootURL.appendingPathComponent(AppleAutomationJournal.stateFileName)
    let depth = container == "array" ? 50_000 : 20_000
    let state = malformedDeepState(container: container, depth: depth)
    precondition(state.utf8.count < 256 * 1024)
    try state.write(to: stateURL, atomically: false, encoding: .utf8)
    chmod(stateURL.path, 0o600)
}

private func rejectMalformedState(root: String) throws {
    try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
        do { _ = try lease.loadSnapshot(); finish(.unexpectedError) }
        catch AppleAutomationJournal.Error.malformedState {}
    }
}

guard CommandLine.arguments.count == 3 else { finish(.usage) }
let mode = CommandLine.arguments[1]
let root = CommandLine.arguments[2]

do {
    switch mode {
    case "lock-probe":
        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(50)) { _ in }
        finish(.acquiredUnexpectedly)
    case "crash-after-begin":
        try AppleAutomationJournal.withLockedJournalForCheckpointTesting(
            root: root,
            deadline: .millisecondsFromNow(1_000),
            checkpointHook: crashHook(.afterDurableBegin)
        ) { lease in
            _ = try lease.begin(request("begin"))
        }
        finish(.checkpointDidNotFire)
    case "crash-after-uncertain":
        let operationID = try pendingOperationID(root: root)
        try AppleAutomationJournal.withLockedJournalForCheckpointTesting(
            root: root,
            deadline: .millisecondsFromNow(1_000),
            checkpointHook: crashHook(.afterDurableMarkUncertain)
        ) { lease in
            try lease.markUncertainAfterHandoff(operationID: operationID)
        }
        finish(.checkpointDidNotFire)
    case "crash-before-rename":
        let operationID = try pendingOperationID(root: root)
        try AppleAutomationJournal.withLockedJournalForCheckpointTesting(
            root: root,
            deadline: .millisecondsFromNow(1_000),
            checkpointHook: crashHook(.beforeRename)
        ) { lease in
            try lease.recordNoDeliveryBeforeHandoff(operationID: operationID)
        }
        finish(.checkpointDidNotFire)
    case "crash-after-rename":
        let operationID = try pendingOperationID(root: root)
        try AppleAutomationJournal.withLockedJournalForCheckpointTesting(
            root: root,
            deadline: .millisecondsFromNow(1_000),
            checkpointHook: crashHook(.afterRename)
        ) { lease in
            try lease.recordNoDeliveryBeforeHandoff(operationID: operationID)
        }
        finish(.checkpointDidNotFire)
    case "deep-array-state":
        try writeMalformedDeepState(root: root, container: "array")
        try rejectMalformedState(root: root)
        finish(.timedOutAsExpected)
    case "deep-object-state":
        try writeMalformedDeepState(root: root, container: "object")
        try rejectMalformedState(root: root)
        finish(.timedOutAsExpected)
    default:
        finish(.usage)
    }
} catch AppleAutomationJournal.Error.lockTimedOut where mode == "lock-probe" {
    finish(.timedOutAsExpected)
} catch {
    finish(.unexpectedError)
}
