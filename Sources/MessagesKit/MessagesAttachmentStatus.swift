import AppleKit
import ArgumentParser
import Foundation

struct MessagesAttachmentStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Inspect the transfer and local readability of one exact attachment part.")

    @OptionGroup var global: GlobalOptions
    @OptionGroup var target: MessagesAttachmentTargetOptions

    func run() throws {
        try run(databasePath: ChatDB.defaultPath(), observe: WorkerLauncher().attachmentStatus(payload:deadline:))
    }

    func run(databasePath: String, observe: (Data, WorkerDeadline) throws -> WorkerAttachmentStatus) throws {
        try runGuarded(tool: tool) {
            let gate = try MessagesWriteGuard.resolve(global)
            let deadline = WorkerDeadline.millisecondsFromNow(5000)
            let capture = try target.capture(databasePath: databasePath, gate: gate,
                                             deadline: deadline, isCancelled: { false })
            let request = capture.request
            let status = try observe(request.workerPayloadData(), deadline)
            try emit(global, Result(chat_rowid: request.chatRowid, message_rowid: request.messageRowid,
                                    native_part: request.nativePartIndex, state: status.rawValue)) { status.rawValue }
        }
    }

    private struct Result: Encodable {
        let chat_rowid: Int64
        let message_rowid: Int64
        let native_part: Int
        let state: String
    }
}
