import ArgumentParser
import AppleKit
import Foundation

struct Reaction: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reaction",
        abstract: "Inspect reactions on exact Messages targets.",
        subcommands: [ReactionInspect.self])
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            throw AppleError.validation("specify a reaction subcommand: inspect")
        }
    }
}

struct ReactionInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect outgoing and incoming reactions for one exact message.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Conversation GUID from chat.guid.") var chatGuid: String?
    @Option(name: .long, help: "Local conversation ROWID from chat.ROWID.") var chatRowid: Int64?
    @Option(name: .long, help: "Message GUID from message.guid.") var messageGuid: String?
    @Option(name: .long, help: "Local message ROWID from message.ROWID.") var messageRowid: Int64?
    @Option(name: .long, help: "Native Messages part index to inspect.") var partIndex: Int?
    @Option(name: .long, help: "Maximum reaction rows to inspect (default 512, max 10000).") var rowLimit: Int = 512

    func run() throws { try run(dependencies: .live) }

    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            guard (1...10_000).contains(rowLimit) else {
                throw AppleError.validation("rowLimit must be between 1 and 10000")
            }
            if let partIndex {
                guard partIndex >= 0 else { throw AppleError.validation("partIndex must be >= 0") }
            }
            let chatSelector = try parseChatSelector(rowid: chatRowid, guid: chatGuid)
            let messageSelector = try parseMessageSelector(rowid: messageRowid, guid: messageGuid)
            var db = try dependencies.makeChatDB(AddressBook())
            let data = try db.exactReactionInspect(chat: chatSelector, message: messageSelector,
                                                   partIndex: partIndex, rowLimit: rowLimit)
            try emit(global, data) { renderExactReactionInspect(data) }
        }
    }
}

private func renderExactReactionInspect(_ result: ChatDB.ExactReactionInspect) -> String {
    let current = result.current_outgoing.key ?? result.current_outgoing.status
    let part = result.target.part_index.map(String.init) ?? "unknown"
    return "reaction status=\(result.status) current=\(current) part=\(part) eligible=\(result.target.mutation_eligible)"
}
