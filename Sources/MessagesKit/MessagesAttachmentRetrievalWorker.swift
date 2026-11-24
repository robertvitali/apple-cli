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
        guard ["messages.attachment.retrieve", WorkerCommand.attachmentObservation, WorkerCommand.attachmentStatus].contains(command.name),
              let data = command.payload, data.count <= 4096,
              let payload = try? JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: data) else { return nil }
        let observation = MessagesAttachmentDownloadObservation(payload: payload, databasePath: databasePath,
                                                               homeDirectory: homeDirectory)
        if command.name != "messages.attachment.retrieve" { return observation }
        return MessagesAttachmentRetrievalWorkerOperation(observation: observation, driver: driver)
    }
}

/// Reads the bound target and its files. Has no Messages UI driver.
struct MessagesAttachmentDownloadObservation: WorkerOperation, Sendable {
    let payload: MessagesAttachmentRetrievalRequest
    let databasePath: String
    let homeDirectory: String

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        if request.command.name == WorkerCommand.attachmentStatus {
            let status = try selectedStatus(deadline: deadline) { item in
                try inspect([item], deadline: deadline).outcome
            }
            return .init(.ack, detail: status.detail)
        }
        let confirmed = try confirmDownloaded(deadline: deadline) { items in
            try inspect(items, deadline: deadline).outcome == .downloaded
        }
        guard confirmed else { return .failed("attachment-retrieval-unavailable") }
        return .init(.ack, detail: "attachment-retrieval-already-downloaded-verified")
    }

    func selectedStatus(deadline: WorkerDeadline,
                        inspectFile: (MessagesAttachmentSnapshot.Item) throws -> WorkerAttachmentStatus) throws -> WorkerAttachmentStatus {
        func selected() throws -> MessagesAttachmentSnapshot.Item {
            let items = try boundItems(deadline: deadline)
            let guid = Data(payload.selectedAttachmentGUID.utf8)
            guard let item = items.first(where: { $0.identity.guid == guid }) else {
                throw MessagesAXNavigationError.targetDrift
            }
            return item
        }
        let before = try selected()
        let status = try inspectFile(before)
        let after = try selected()
        guard Self.sameFileEvidence(before, after) else {
            throw MessagesAXNavigationError.targetDrift
        }
        return status
    }

    /// The verifier releases SQLite before filesystem I/O. Check that the bound database
    /// evidence still agrees before acknowledging the result of those file observations.
    func confirmDownloaded(deadline: WorkerDeadline,
                           filesDownloaded: ([MessagesAttachmentSnapshot.Item]) throws -> Bool) throws -> Bool {
        let initial = try boundItems(deadline: deadline)
        guard try filesDownloaded(initial) else { return false }
        guard initial.allSatisfy({ $0.filename != nil }) else { return false }
        return try filesStillBound(initial, deadline: deadline)
    }

    private static func sameFileEvidence(_ old: MessagesAttachmentSnapshot.Item, _ new: MessagesAttachmentSnapshot.Item) -> Bool {
        guard old.identity == new.identity, old.transfer == new.transfer else { return false }
        switch (old.filename, new.filename) {
        case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
        case (nil, nil): return true
        default: return false
        }
    }

    private func filesStillBound(_ initial: [MessagesAttachmentSnapshot.Item], deadline: WorkerDeadline,
                                 beforeBinding: () -> Void = {}) throws -> Bool {
        let latest = try boundItems(deadline: deadline, beforeBinding: beforeBinding)
        let before = initial.sorted { $0.identity.rowid < $1.identity.rowid }
        let after = latest.sorted { $0.identity.rowid < $1.identity.rowid }
        return before.count == after.count && zip(before, after).allSatisfy { Self.sameFileEvidence($0, $1) }
    }

    private func boundItems(deadline: WorkerDeadline, beforeBinding: () -> Void = {}) throws -> [MessagesAttachmentSnapshot.Item] {
        let capture = try MessagesAttachmentTargetResolver.read(databasePath: databasePath,
            chat: .rowid(payload.chatRowid), message: .rowid(payload.messageRowid), partIndex: payload.nativePartIndex,
            sandboxPrefix: payload.sandboxPrefix, deadline: deadline)
        beforeBinding()
        guard try capture.request.workerPayloadData() == payload.workerPayloadData() else {
            throw MessagesAXNavigationError.targetDrift
        }
        return capture.items
    }

    private func inspect(_ items: [MessagesAttachmentSnapshot.Item],
                         deadline: WorkerDeadline) throws -> MessagesAttachmentObservation.Result {
        try MessagesAttachmentObservation.evaluate(items: items, homeDirectory: homeDirectory,
            selectedAttachmentGUID: payload.selectedAttachmentGUID, deadline: deadline)
    }

    func read(_ bounded: WorkerDeadline, verification: Bool,
              diagnostic: MessagesAttachmentDiagnostic) throws -> MessagesAttachmentObservation.Result {
        try read(bounded, verification: verification, diagnostic: diagnostic) { items in
            try inspect(items, deadline: bounded)
        }
    }

    func read(_ bounded: WorkerDeadline, verification: Bool, diagnostic: MessagesAttachmentDiagnostic,
              inspectFiles: ([MessagesAttachmentSnapshot.Item]) throws -> MessagesAttachmentObservation.Result) throws -> MessagesAttachmentObservation.Result {
        try diagnostic.at(verification ? .verificationRead : .initialRead) {
            let items = try boundItems(deadline: bounded) {
                diagnostic.record(verification ? .verificationBinding : .initialBinding)
            }
            diagnostic.record(verification ? .verificationFiles : .initialFiles)
            let result = try inspectFiles(items)
            diagnostic.record(verification ? .verificationRead : .initialRead)
            let unchanged = try filesStillBound(items, deadline: bounded) {
                diagnostic.record(verification ? .verificationBinding : .initialBinding)
            }
            guard unchanged else { throw MessagesAXNavigationError.targetDrift }
            return result
        }
    }
}

private struct MessagesAttachmentRetrievalWorkerOperation: WorkerOperation, @unchecked Sendable {
    let observation: MessagesAttachmentDownloadObservation
    let driver: any MessagesReactionAXDriving

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let diagnostic = MessagesAttachmentDiagnostic()
        let payload = observation.payload
        func observe(_ bounded: WorkerDeadline, verification: Bool = false) throws -> MessagesAttachmentObservation.Result {
            try observation.read(bounded, verification: verification, diagnostic: diagnostic)
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
