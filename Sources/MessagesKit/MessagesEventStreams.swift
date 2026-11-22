import AppleKit
import ArgumentParser
import Foundation

struct MessagesEventStreams: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event-streams",
        abstract: "Inspect and retire local Messages event journals.",
        subcommands: [List.self, Retire.self]
    )

    func run() throws {
        try Self.perform { throw AppleError.validation("Specify list or retire.") }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List local event streams and retention bounds.")
        @OptionGroup var global: GlobalOptions

        func run() throws { try run(registry: .currentUser()) }

        func run(registry: @autoclosure () throws -> MessageEventWatchRegistry) throws {
            try MessagesEventStreams.perform {
                guard !global.execute, !global.dryRun else {
                    throw AppleError.validation("Stream listing has no write options.")
                }
                try MessageEventStreamLifecycle.run(.list, registry: registry(), text: global.text)
            }
        }
    }

    struct Retire: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Retire one exact local event stream.")
        @Argument(help: "Exact lowercase stream ID returned by watch or event-streams list.")
        var streamID: String
        @OptionGroup var global: GlobalOptions

        func run() throws { try run(registry: .currentUser()) }

        func run(registry: @autoclosure () throws -> MessageEventWatchRegistry) throws {
            try MessagesEventStreams.perform {
                let request = try retirementRequest()
                try MessageEventStreamLifecycle.run(request, registry: registry(), text: global.text)
            }
        }

        func retirementRequest() throws -> ExistingEventJournalLease.RegistryRequest {
            guard let stream = try? MessageEventStreamID(streamID), let id = UUID(uuidString: stream.rawValue) else {
                throw AppleError.validation("An exact lowercase stream ID is required.")
            }
            let sandbox = try TestMode.sandboxActive(flag: global.testMode)
            let execute = try global.willExecute(defaultDryRun: false)
            guard !sandbox || !execute else {
                throw AppleError.safetyViolation("Stream retirement in sandbox mode requires a dry run.", sandbox: true)
            }
            return execute ? .retire(id) : .preview(id)
        }
    }

    private static func perform(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let failure as RecordWriterError {
            Output.writeStreamDiagnostic("Messages event stream output: " + failure.reason.rawValue)
            throw ExitCode(AppleExit.unknown)
        } catch MessageEventPollWait.Failure.outputClosed {
            Output.writeStreamDiagnostic("Messages event stream output: outputClosed")
            throw ExitCode(AppleExit.unknown)
        } catch {
            let issue: AppleError
            switch error {
            case let known as AppleError: issue = known
            case ExistingEventJournalLease.Failure.busy: issue = .upstream("streamBusy")
            case ExistingEventJournalLease.Failure.unavailable: issue = .notFound("streamUnavailable")
            default: issue = .upstream("streamRegistryUnavailable")
            }
            Output.emitError(tool: "messages", type: issue.type, message: issue.message,
                             sandbox: issue.sandbox, compact: true)
            throw ExitCode(issue.exitCode)
        }
    }
}
