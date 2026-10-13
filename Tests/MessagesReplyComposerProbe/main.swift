import Foundation
import AppleKit
import MessagesKit

if InternalWorkerMain.isWorkerInvocation(CommandLine.arguments) {
    exit(InternalWorkerMain.run(arguments: CommandLine.arguments, registry: MessagesReplyComposerProbeWorkerRegistry()))
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
