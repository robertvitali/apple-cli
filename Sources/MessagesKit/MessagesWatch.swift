import AppleKit
import ArgumentParser
import Foundation

struct MessagesWatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Observe Messages changes as newline-delimited JSON and resume from a saved cursor."
    )

    @OptionGroup var options: MessageEventWatchOptions
    @OptionGroup(visibility: .hidden) var global: GlobalOptions

    func run() throws {
        try run(storage: MessageEventWatchStorage.currentUser, output: STDOUT_FILENO)
    }

    func run(storage: () throws -> MessageEventWatchStorage, output: Int32) throws {
        do {
            try MessageEventWatchRuntime.emitWatchFailure(output: output) {
                guard !global.text, !global.dryRun, !global.execute, !global.testMode else {
                    throw Bad.args
                }
                try MessageEventWatchRuntime.run(try options.request(), storage: storage(), output: output)
            }
        } catch let error as AppleError {
            // Stream errors already have a terminating record. The root honors ExitCode.
            throw ExitCode(error.exitCode)
        } catch let error as RecordWriterError {
            // Delivery failed on this output stream. Another write could duplicate a partial record.
            Output.writeStreamDiagnostic("Messages watch output: " + error.reason.rawValue)
            throw ExitCode(AppleExit.unknown)
        } catch MessageEventPollWait.Failure.outputClosed {
            Output.writeStreamDiagnostic("Messages watch output: outputClosed")
            throw ExitCode(AppleExit.unknown)
        }
    }
}
