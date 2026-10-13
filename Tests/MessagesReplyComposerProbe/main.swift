import CryptoKit
import Foundation
import AppleKit
import MessagesKit

if InternalWorkerMain.isWorkerInvocation(CommandLine.arguments) {
    exit(InternalWorkerMain.run(arguments: CommandLine.arguments, registry: MessagesReplyComposerProbeWorkerRegistry()))
}

private func printJSON(_ value: MessagesReplyAttachmentProbePrivateResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("{\"outcome\":\"refused\",\"schema_version\":1}")
    }
}

if CommandLine.arguments.dropFirst().first == "--inspect-attachment-from-file" {
    guard CommandLine.arguments.count == 5 else { exit(64) }
    var prepared: MessagesReplyComposerProbeRequest?
    var payload: Data?
    var observed: WorkerObservedOutcome?
    var launchStarted = false
    let deadline = WorkerDeadline.millisecondsFromNow(30_000)
    do {
        let basePayload = try MessagesReplyComposerProbeParent.payloadData(fromFile: CommandLine.arguments[2],
                                                                           repoRoot: FileManager.default.currentDirectoryPath)
        let base = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: basePayload)
        payload = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: base,
                                                                                    rawFilePath: CommandLine.arguments[3],
                                                                                    scratchRoot: CommandLine.arguments[4],
                                                                                    repoRoot: FileManager.default.currentDirectoryPath,
                                                                                    deadline: deadline)
        guard let payloadData = payload else { throw CocoaError(.fileReadUnknown) }
        prepared = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payloadData)
        let action = try MessagesReplyComposerProbeParent.observedAction(payloadData: payloadData, deadline: deadline)
        launchStarted = true
        observed = try WorkerLauncher().launchObserved(action)
        try MessagesReplyAttachmentProbePrivateEntrypoint.cleanupBeforeHandoffIfProven(prepared?.attachmentDraft,
                                                                                       launchStarted: launchStarted,
                                                                                       outcome: observed, deadline: deadline)
        let cleanup = MessagesReplyAttachmentProbePrivateEntrypoint.cleanupEvidence(for: prepared?.attachmentDraft)
        let classified = MessagesReplyAttachmentProbePrivateEntrypoint.classify(observed: observed, prepared: prepared,
                                                                                payloadData: payload, cleanup: cleanup)
        printJSON(classified.result)
        exit(classified.exitCode)
    } catch {
        try? MessagesReplyAttachmentProbePrivateEntrypoint.cleanupBeforeHandoffIfProven(prepared?.attachmentDraft,
                                                                                       launchStarted: launchStarted,
                                                                                       outcome: observed, deadline: deadline)
        let cleanup = MessagesReplyAttachmentProbePrivateEntrypoint.cleanupEvidence(for: prepared?.attachmentDraft)
        let classified = MessagesReplyAttachmentProbePrivateEntrypoint.classify(observed: observed, prepared: prepared,
                                                                                payloadData: payload, cleanup: cleanup)
        printJSON(classified.result)
        exit(classified.exitCode)
    }
}

if CommandLine.arguments.dropFirst().first == "--inspect-from-file" {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    do {
        let payload = try MessagesReplyComposerProbeParent.payloadData(
            fromFile: CommandLine.arguments[2],
            repoRoot: FileManager.default.currentDirectoryPath
        )
        let action = try MessagesReplyComposerProbeParent.observedAction(
            payloadData: payload,
            deadline: .millisecondsFromNow(10_000)
        )
        print(try WorkerLauncher().launchObserved(action).description)
        exit(0)
    } catch {
        print("refused")
        exit(65)
    }
}

print("MessagesReplyComposerProbe: internal worker only")
