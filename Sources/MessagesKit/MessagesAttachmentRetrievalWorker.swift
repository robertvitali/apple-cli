import AppleKit
import Foundation

struct MessagesAttachmentRetrievalWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    let driver: any MessagesReactionAXDriving
    let databasePath: String
    let homeDirectory: String

    init(driver: any MessagesReactionAXDriving = LiveMessagesReactionAXDriver(),
         databasePath: String = ChatDB.defaultPath(),
         homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.driver = driver
        self.databasePath = databasePath
        self.homeDirectory = homeDirectory
    }

    func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        guard command.name == "messages.attachment.retrieve", let data = command.payload, data.count <= 4096,
              let payload = try? JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: data) else { return nil }
        return MessagesAttachmentRetrievalWorkerOperation(payload: payload, driver: driver,
            databasePath: databasePath, homeDirectory: homeDirectory)
    }
}

private struct MessagesAttachmentRetrievalWorkerOperation: WorkerOperation, @unchecked Sendable {
    let payload: MessagesAttachmentRetrievalRequest
    let driver: any MessagesReactionAXDriving
    let databasePath: String
    let homeDirectory: String

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let diagnostic = MessagesAttachmentDiagnostic()
        func observe(_ bounded: WorkerDeadline, verification: Bool = false) throws -> MessagesAttachmentObservation.Result {
            try diagnostic.at(verification ? .verificationRead : .initialRead) {
                let capture = try MessagesAttachmentTargetResolver.read(databasePath: databasePath,
                    chat: .rowid(payload.chatRowid), message: .rowid(payload.messageRowid), partIndex: payload.nativePartIndex,
                    sandboxPrefix: payload.sandboxPrefix, deadline: bounded)
                diagnostic.record(verification ? .verificationBinding : .initialBinding)
                guard try capture.request.workerPayloadData() == payload.workerPayloadData() else {
                    throw MessagesAXNavigationError.targetDrift
                }
                diagnostic.record(verification ? .verificationFiles : .initialFiles)
                return try MessagesAttachmentObservation.evaluate(items: capture.items, homeDirectory: homeDirectory,
                    selectedAttachmentGUID: payload.selectedAttachmentGUID, deadline: bounded)
            }
        }
        do {
            let initial = try observe(deadline)
            let sequence = MessagesAttachmentRetrievalSequence(observe: { bounded in
                try observe(bounded, verification: diagnostic.stage == .verificationRead)
            }, requestDownload: { bounded in
                let titles = try diagnostic.at(.titles) {
                    let resolved = try MessagesReactionActionTitleResolver.canonicalize(driver.reactActionTitles(deadline: bounded))
                    guard !resolved.isEmpty else { throw MessagesAXNavigationError.unknownAXValue }
                    return resolved
                }
                let press = MessagesAttachmentAXPress(driver: driver, isTargetEligible: { element, deadline in
                    try diagnostic.at(.eligibility) {
                        let matches = try element.actions(deadline: deadline).filter { action in
                            titles.contains { MessagesReactionAXAutomation.matchesAction(action, title: $0) }
                        }
                        guard matches.count <= 1 else { throw MessagesAXNavigationError.unknownAXValue }
                        return matches.count == 1
                    }
                })
                try press.perform(messageGUID: payload.messageGUID, nativePartIndex: payload.nativePartIndex,
                    nativePartGUID: payload.nativePartGUID, deadline: bounded, diagnostic: diagnostic, validateTarget: { try observe(bounded).pressOutcome })
            }, diagnostic: diagnostic)
            return try sequence.run(expected: initial.membership, deadline: deadline)
        } catch MessagesAttachmentObservation.Failure.membershipDrift {
            return .failed("attachment-retrieval-membership-drift")
        } catch {
            // Native errors and target values never cross the worker protocol.
            return .failed(diagnostic.detail(error))
        }
    }
}
