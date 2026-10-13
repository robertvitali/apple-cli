import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleKit
@testable import MessagesKit
import TestSupport

// MARK: - Test-only dependency fixtures

/// The fake edge set every test in this file drives the commands through. It lives in the TEST
/// target, not the product target: shipping a fixture factory inside `MessagesKit` would link
/// test-only code into `apple` and count toward the product's coverage numerator.
///
/// Every closure FAILS CLOSED by default (an unconfigured edge throws rather than reaching a real
/// database, `osascript`, or the network), so a test that forgets to stub the edge it exercises
/// gets an error instead of silently touching the operator's machine.
extension MessagesCommandDependencies {
    static func fixture(
        book: AddressBook = AddressBook(),
        loadAddressBook: (@Sendable () -> AddressBook)? = nil,
        makeChatDB: @escaping @Sendable (AddressBook) throws -> ChatDB = { _ in
            throw AppleError.upstream("test ChatDB dependency not configured")
        },
        performSend: @escaping @Sendable (Send.Request) throws -> Send.Outcome = { _ in
            throw AppleError.upstream("test send dependency not configured")
        },
        dbDiagnostic: @escaping @Sendable () -> ChatDB.DBCheck = {
            ChatDB.DBCheck(path: syntheticChatDBPath, exists: false, readable: false,
                           connected: false, table_count: nil, has_message_table: false,
                           has_handle_table: false, has_chat_table: false, message_count: nil)
        },
        addressBookDiagnostic: @escaping @Sendable () -> AddressBook.Diagnostic = {
            AddressBook.Diagnostic(sources_dir: syntheticAddressBookDir, sources_dir_exists: false,
                                   database_count: 0, databases: [], contacts_with_handles: 0)
        },
        accessibilityDiagnostic: @escaping @Sendable () -> Permissions.AccessibilityPreflight = {
            Permissions.accessibilityPreflight(trusted: false)
        },
        hasFullDiskAccess: @escaping @Sendable () -> Bool = { false },
        messagesAutomationStateRoot: @escaping @Sendable () -> String = { "synthetic/messages-automation" },
        launchObservedWorker: @escaping @Sendable (WorkerObservedAction) throws -> WorkerObservedOutcome = { _ in
            throw AppleError.upstream("test worker dependency not configured")
        },
        allowedRecipients: [String] = []
    ) -> MessagesCommandDependencies {
        MessagesCommandDependencies(
            loadAddressBook: loadAddressBook ?? { book },
            makeChatDB: makeChatDB,
            performSend: performSend,
            dbDiagnostic: dbDiagnostic,
            addressBookDiagnostic: addressBookDiagnostic,
            accessibilityDiagnostic: accessibilityDiagnostic,
            hasFullDiskAccess: hasFullDiskAccess,
            messagesAutomationStateRoot: messagesAutomationStateRoot,
            launchObservedWorker: launchObservedWorker,
            resolveGate: hermeticGate(allowedRecipients: allowedRecipients)
        )
    }

    /// Production's write-posture precedence, evaluated with the v2 environment variables pinned
    /// OFF and the recipient allowlist supplied directly.
    ///
    /// This is the whole point of the `resolveGate` seam. `MessagesWriteGuard.resolve` reads
    /// `APPLE_TEST_MODE`, `APPLE_DRY_RUN` and `APPLE_TEST_RECIPIENTS` from the process
    /// environment; swift-testing runs suites in PARALLEL, so a send test that `setenv`-ed any of
    /// them would race every other reader in the run (the failure mode documented on
    /// `GlobalOptions.willExecute(defaultDryRun:envVar:)`). The flag half of the precedence —
    /// `--dry-run` > `--execute` > default-execute, and `--test-mode` engaging the sandbox — is
    /// still exercised for real, via the same `GlobalOptions.resolveExecute` core production uses.
    static func hermeticGate(
        allowedRecipients: [String]
    ) -> @Sendable (GlobalOptions) throws -> MessagesWriteGuard.Gate {
        { global in
            MessagesWriteGuard.Gate(
                willExecute: GlobalOptions.resolveExecute(dryRunFlag: global.dryRun,
                                                          executeFlag: global.execute,
                                                          envDryRun: false,
                                                          defaultDryRun: false),
                sandboxActive: global.testMode,
                allowedRecipients: allowedRecipients)
        }
    }
}

/// Shorthands for the two `Send.Outcome` shapes the fixtures return, so a stubbed sender reads as
/// what it is ("this went out over iMessage") instead of as five positional fields.
extension Send.Outcome {
    static func sent(_ service: String?, files: Int = 0) -> Send.Outcome {
        Send.Outcome(ok: true, service: service, filesSent: files, failedFile: nil,
                     bodyDelivered: true, error: nil)
    }

    /// `bodyDelivered` defaults to FALSE so a test that cares about the body has to say so —
    /// the opposite default would let the "body was delivered and the envelope must say so"
    /// regression pass by accident.
    static func failed(error: String, filesSent: Int = 0, failedFile: Int? = nil,
                       bodyDelivered: Bool = false) -> Send.Outcome {
        Send.Outcome(ok: false, service: nil, filesSent: filesSent, failedFile: failedFile,
                     bodyDelivered: bodyDelivered, error: error)
    }
}

/// Placeholder path STRINGS for diagnostic payloads. They are never opened — they only have to be
/// recognizable in an envelope — so they are deliberately relative and carry no absolute
/// filesystem prefix. Tests that need a real path on disk take one from `ScratchDirs`.
private let syntheticChatDBPath = "synthetic/chat.db"
private let syntheticAddressBookDir = "synthetic/AddressBook"

private let commandNativePartKey = NSAttributedString.Key("__kIMMessagePartAttributeName")

private func commandNativeArchive(_ text: String, _ attributes: [(NSAttributedString.Key, Any, NSRange)] = []) -> Data {
    let value = NSMutableAttributedString(string: text)
    for (key, object, range) in attributes {
        value.addAttribute(key, value: object, range: range)
    }
    return NSArchiver.archivedData(withRootObject: value)
}

private func commandReactionRange(_ text: String, _ needle: String) -> NSRange {
    let range = (text as NSString).range(of: needle)
    precondition(range.location != NSNotFound)
    return range
}

private extension ChatFixture {
    func addReactionColumns(includeCustomEmoji: Bool = true) throws {
        try exec("ALTER TABLE message ADD COLUMN associated_message_guid TEXT;")
        try exec("ALTER TABLE message ADD COLUMN associated_message_type INTEGER;")
        if includeCustomEmoji {
            try exec("ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;")
        }
    }

    func insertReactionTarget(rowid: Int64, guid: String, text: String = "apple-cli-test target",
                              part: Int = 2, chatRowid: Int64 = 3) throws {
        let body = commandNativeArchive(text, [
            (commandNativePartKey, NSNumber(value: part), commandReactionRange(text, "target")),
        ])
        try insertMessage(rowid: rowid, guid: guid, text: text, attributedBody: body,
                          chatRowid: chatRowid, date: base + 10)
    }

    func insertReaction(rowid: Int64, guid: String, associatedGUID: String, type: Int,
                        isFromMe: Int = 1, handleID: Int64? = 1, date: Int64,
                        chatRowid: Int64 = 3, emoji: String? = nil) throws {
        let handleSQL = handleID.map(String.init) ?? "NULL"
        let emojiSQL = emoji.map { "'\($0)'" } ?? "NULL"
        try exec("""
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,
                associated_message_guid,associated_message_type,associated_message_emoji)
            VALUES (\(rowid),'\(guid)',NULL,\(isFromMe),\(handleSQL),'iMessage',\(date),0,
                '\(associatedGUID)',\(type),\(emojiSQL));
            INSERT INTO chat_message_join VALUES (\(chatRowid),\(rowid));
            """)
    }
}

/// Rebuilds `chat` WITHOUT `style`, keeping `chat_message_join` intact. That is the one schema
/// shape where a store can join messages to chats but cannot classify them, so it is what makes
/// `--direct-only` unable to run — the fail-open case the `direct_only_applied` field exists for.
private let styleLessChatSchema = """
    DROP TABLE chat;
    CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
        room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT);
    """

@Suite("Messages command dependency injection", .serialized)
struct MessagesCommandDependencyTests {
    private let scratch = ScratchDirs("messages-command-dependencies")
    /// Held for the LIFETIME OF THE TEST, not just the statement that builds the dependencies.
    /// `fixtureDependencies` captures only the fixture's path strings, so a locally-scoped
    /// fixture could be released — and its `ScratchDirs` deinit could delete the database — before
    /// the command under test opens it. swift-testing builds a fresh suite instance per test, so a
    /// stored property is both alive for the whole test and reclaimed after it.
    private let chat: ChatFixture

    init() throws {
        chat = try ChatFixture()
    }

    @Test func findContactUsesInjectedAddressBook() throws {
        let command = try FindContact.parse(["Alice"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(
                book: AddressBook(contacts: [
                    "12125550100": "Alice Example",
                ])
            ))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 1)
        let contacts = try #require(data["contacts"] as? [[String: Any]])
        let first = try #require(contacts.first)
        #expect(first["name"] as? String == "Alice Example")
    }

    @Test func recentUsesInjectedChatDB() throws {
        let command = try Recent.parse(["--hours", "24", "--limit", "3"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 3)
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.map { $0["rowid"] as? Int } == [1, 2, 3])
    }

    @Test func recentHandleFilterUsesInjectedLookup() throws {
        let command = try Recent.parse(["--handle", "+1 (212) 555-0101", "--hours", "24"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["resolved_handle_rowids"] as? [Int] == [2])
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.map { $0["rowid"] as? Int } == [4])
    }

    @Test func recentAmbiguousContactReturnsRankedCandidates() throws {
        let path = chat.path
        let homePath = chat.homePath
        let book = AddressBook(contacts: [
            "12125550100": "Alice Example",
            "12125550101": "Alice Example",
        ])
        let command = try Recent.parse(["--contact", "Alice"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(book: book, makeChatDB: { _ in
                try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
            }))
        }

        let data = try payload(from: output)
        #expect(data["ambiguous"] as? Bool == true)
        #expect(data["count"] as? Int == 0)
    }

    /// ORACLE-PARITY BRANCH (`get_recent_messages`). A single fuzzy `--contact` match resolves
    /// through the contact's HANDLE, and the handle decides the lookup: a phone goes to the
    /// phone-format expansion, an email to an exact-id lookup. Covered as a pair because the two
    /// branches are one `contains("@")` apart and only the pair proves which one ran.
    @Test func recentSingleFuzzyContactResolvesAPhoneHandle() throws {
        let path = chat.path
        let homePath = chat.homePath
        let book = AddressBook(contacts: ["12125550100": "Alice Example"])
        let command = try Recent.parse(["--contact", "Alice", "--hours", "24"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(book: book, makeChatDB: { _ in
                try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
            }))
        }

        let data = try payload(from: output)
        #expect(data["ambiguous"] as? Bool == false)
        #expect(data["contact"] as? String == "Alice")
        // handle ROWID 1 is `+12125550100` in the fixture; the phone branch expands formats.
        #expect(data["resolved_handle_rowids"] as? [Int] == [1])
        #expect((data["count"] as? Int ?? 0) > 0)
    }

    @Test func recentSingleFuzzyContactResolvesAnEmailHandle() throws {
        let dbPath = try emailHandleChatDBPath()
        let homePath = try scratch.directory().path
        let book = AddressBook(contacts: ["carol@example.com": "Carol Example"])
        let command = try Recent.parse(["--contact", "Carol", "--hours", "24"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(book: book, makeChatDB: { _ in
                try ChatDB(path: dbPath, book: book, copyToTemp: false,
                           homeDirectoryForTilde: homePath)
            }))
        }

        let data = try payload(from: output)
        // The email branch is the ONLY one that can find this row: the phone branch normalizes
        // `carol@example.com` to an empty digit string and returns no rowids at all.
        #expect(data["resolved_handle_rowids"] as? [Int] == [7])
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.map { $0["rowid"] as? Int } == [70])
    }

    /// The no-match `--contact` branch returns a 0-count envelope with an explanatory note — NOT
    /// an error, and NOT an unfiltered message list. The filter was requested and matched nobody.
    @Test func recentUnmatchedContactEmitsNoteWithoutMessages() throws {
        let command = try Recent.parse(["--contact", "Zzyzx Qqqqq", "--hours", "24"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["ambiguous"] as? Bool == false)
        #expect(data["count"] as? Int == 0)
        #expect(data["resolved_handle_rowids"] == nil)
        #expect(data["note"] as? String == "No contacts found matching 'Zzyzx Qqqqq'.")
        #expect((data["messages"] as? [[String: Any]])?.isEmpty == true)
    }

    /// PARITY PIN. `recent` opens chat.db EAGERLY, before any contact-filter branch can return.
    /// A lazy open would let an unmatched or ambiguous `--contact` exit 0 on a machine where the
    /// database is unreadable, hiding the access failure behind a successful-looking envelope —
    /// the opposite of what every other read command reports on the same machine.
    @Test func recentSurfacesDatabaseFailureBeforeContactFilterBranches() throws {
        let unmatched = try captureCommand {
            let command = try Recent.parse(["--contact", "Nobody"])
            try command.run(dependencies: .fixture())
        }
        #expect(unmatched.exitCode == AppleExit.upstream)
        #expect(try errorPayload(from: unmatched.stdout)["type"] as? String == AppleErrorType.upstream)

        let ambiguous = try captureCommand {
            let command = try Recent.parse(["--contact", "Alice"])
            try command.run(dependencies: .fixture(book: AddressBook(contacts: [
                "12125550100": "Alice Able",
                "12125550101": "Alice Baker",
            ])))
        }
        #expect(ambiguous.exitCode == AppleExit.upstream)
        #expect(try errorPayload(from: ambiguous.stdout)["type"] as? String == AppleErrorType.upstream)
    }

    @Test func sendDryRunDoesNotInvokeSender() throws {
        let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100", "--message", "synthetic hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("dry-run must not invoke sender")
                return .sent(nil)
            }))
        }

        let data = try payload(from: output)
        #expect(data["executed"] as? Bool == false)
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["resolved_handle"] as? String == "12125550100")
    }

    @Test func sendExecuteUsesInjectedSender() throws {
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.handle == "12125550100")
                #expect(request.message == "synthetic hello")
                #expect(request.groupChat == false)
                // The default service, and no attachments, reach the sender as such.
                #expect(request.service == .auto)
                #expect(request.files.isEmpty)
                return .sent("iMessage")
            }))
        }

        let envelope = try successEnvelope(from: output)
        // Unsandboxed writes stay byte-identical to the pre-v2 envelope: the key is OMITTED,
        // never emitted as `false`.
        #expect(envelope["sandbox"] == nil)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["executed"] as? Bool == true)
        #expect(data["dry_run"] as? Bool == false)
        #expect(data["service_used"] as? String == "iMessage")
    }

    @Test func sendGroupExecuteUsesInjectedSender() throws {
        let command = try Send_.parse(["--group", "iMessage;+;chat-example", "--message", "synthetic group hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.handle == "iMessage;+;chat-example")
                #expect(request.message == "synthetic group hello")
                #expect(request.groupChat == true)
                return .sent(nil)
            }))
        }

        let data = try payload(from: output)
        #expect(data["group_chat"] as? Bool == true)
        #expect(data["executed"] as? Bool == true)
    }

    @Test func sendAmbiguousContactDoesNotInvokeSender() throws {
        let command = try Send_.parse(["Alice", "--message", "synthetic hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(
                book: AddressBook(contacts: [
                    "12125550100": "Alice Able",
                    "12125550101": "Alice Baker",
                ]),
                performSend: { _ in
                    Issue.record("ambiguous contact must not invoke sender")
                    return .sent(nil)
                }
            ))
        }

        let data = try payload(from: output)
        #expect(data["ambiguous"] as? Bool == true)
        #expect(data["executed"] as? Bool == false)
    }

    // MARK: - Sandbox (write-model v2 opt-in policy mode)

    /// FAIL-CLOSED PIN. Inside the sandbox an empty allowlist matches nothing, so every recipient
    /// is refused rather than every recipient allowed — the worst possible default on a surface
    /// that reaches a real human. The refusal is a `validation_error` at exit 64 carrying
    /// `error.sandbox: true`, so a caller can tell a sandbox refusal from an ordinary bad argument.
    @Test func sandboxRefusesRecipientOutsideAllowlistAndNeverSends() throws {
        let command = try Send_.parse(["--test-mode", "+1 (212) 555-0100", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("a sandbox-refused recipient must not invoke sender")
                return .sent(nil)
            }, allowedRecipients: []))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect(error["sandbox"] as? Bool == true)
        #expect((error["message"] as? String)?.hasPrefix("refusing send:") == true)
    }

    /// ORDERING PIN. The allowlist runs BEFORE the dry-run preview branch, so a preview refuses
    /// exactly what an execute would. A preview that reported "would send" for a recipient the
    /// execute path rejects is a lie, and on a send surface it is the lie most likely to be acted
    /// on.
    @Test func sandboxRefusalPrecedesDryRunPreview() throws {
        let command = try Send_.parse(["--dry-run", "--test-mode", "+1 (212) 555-0100",
                                       "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(allowedRecipients: []))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["sandbox"] as? Bool == true)
        // The preview envelope must NOT have been emitted before the refusal.
        #expect(!result.stdout.contains("would send"))
        #expect(!result.stdout.contains("dry_run"))
    }

    /// Sandboxed group send is refused even when the operator's own number IS on the allowlist:
    /// AGENTS.md makes group send operator-verify-only because a group has no self-addressed
    /// shape (HUMAN-DECISIONS.md D4).
    @Test func sandboxRefusesGroupChatEvenWithAnAllowlistEntry() throws {
        let command = try Send_.parse(["--test-mode", "--group", "iMessage;+;chat-example",
                                       "--message", "synthetic group hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("sandboxed group send must not invoke sender")
                return .sent(nil)
            }, allowedRecipients: ["+1 (212) 555-0100"]))
        }

        #expect(result.exitCode == AppleExit.usage)
        #expect(try errorPayload(from: result.stdout)["sandbox"] as? Bool == true)
    }

    /// REGRESSION PIN for the escape the "a chat id never matches a phone entry" argument missed.
    /// `Send.resolve` keeps a group id verbatim, `normalizeForAllowlist` strips it to digits on
    /// BOTH sides, and `phonesEquivalent` short-circuits on two equal strings before it checks
    /// they are digits — so an operator who pasted the chat id into the allowlist used to get a
    /// sandboxed group send delivered to real people. The refusal is structural now, so the
    /// allowlist content cannot re-open it. Both the execute and the preview invocation are
    /// covered: the refusal must precede the dry-run branch here too.
    @Test func sandboxRefusesGroupChatWhenTheChatIdItselfIsAllowlisted() throws {
        let chatId = "iMessage;+;chat-example"
        for extraArgs in [[], ["--dry-run"]] {
            let command = try Send_.parse(extraArgs + ["--test-mode", "--group", chatId,
                                                       "--message", "synthetic group hello"])
            let result = try captureCommand {
                try command.run(dependencies: .fixture(performSend: { _ in
                    Issue.record("a sandboxed group send must not invoke sender")
                    return .sent(nil)
                }, allowedRecipients: [chatId]))
            }

            #expect(result.exitCode == AppleExit.usage)
            let error = try errorPayload(from: result.stdout)
            #expect(error["type"] as? String == AppleErrorType.validation)
            #expect(error["sandbox"] as? Bool == true)
            let message = try #require(error["message"] as? String)
            #expect(message.hasPrefix("refusing send:"))
            // The GROUP-SPECIFIC wording, asserted both ways. Without this the test passes on the
            // allowlist-mismatch refusal too — the very path it exists to prove is unreachable —
            // so a regression that deleted the structural guard would stay green here.
            #expect(message.contains("group-chat send is unavailable"))
            #expect(!message.contains("not in the test allowlist"))
            #expect(!result.stdout.contains("would send"))
        }
    }

    /// The group refusal is a SANDBOX restriction, not a capability drop: unsandboxed, `--group`
    /// still reaches the sender exactly as `tool_send_message(group_chat=True)` does. Without
    /// this, tightening the sandbox could quietly become a parity regression.
    @Test func unsandboxedGroupSendStillReachesTheSender() throws {
        let chatId = "iMessage;+;chat-example"
        let command = try Send_.parse(["--group", chatId, "--message", "synthetic group hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.handle == chatId)
                #expect(request.groupChat == true)
                return .sent(nil)
            }, allowedRecipients: [chatId]))
        }

        let envelope = try successEnvelope(from: output)
        #expect(envelope["sandbox"] == nil)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["group_chat"] as? Bool == true)
        #expect(data["executed"] as? Bool == true)
    }

    /// An allowlisted recipient sends, and the envelope is TAGGED `sandbox: true` so a caller can
    /// tell a restricted send from a normal one without re-reading the environment.
    @Test func sandboxTagsEnvelopeForAnAllowlistedRecipient() throws {
        let command = try Send_.parse(["--test-mode", "+1 (212) 555-0100", "--message", "synthetic hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.handle == "12125550100")
                return .sent("iMessage")
            }, allowedRecipients: ["+1 (212) 555-0100"]))
        }

        let envelope = try successEnvelope(from: output)
        #expect(envelope["sandbox"] as? Bool == true)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["executed"] as? Bool == true)
        #expect(data["dry_run"] as? Bool == false)
    }

    /// The dry-run envelope carries the same sandbox tag — a preview taken inside the sandbox must
    /// not read as an unrestricted one.
    @Test func sandboxTagsDryRunPreviewEnvelope() throws {
        let command = try Send_.parse(["--dry-run", "--test-mode", "+1 (212) 555-0100",
                                       "--message", "synthetic hello"])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("dry-run must not invoke sender")
                return .sent(nil)
            }, allowedRecipients: ["+1 (212) 555-0100"]))
        }

        let envelope = try successEnvelope(from: output)
        #expect(envelope["sandbox"] as? Bool == true)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["executed"] as? Bool == false)
    }

    /// `--text` write output is prefixed `[sandbox] ` on both the execute and the preview path.
    @Test func sandboxPrefixesTextWriteOutput() throws {
        let executed = try captureStdout {
            let command = try Send_.parse(["--text", "--test-mode", "+1 (212) 555-0100",
                                           "--message", "synthetic hello"])
            try command.run(dependencies: .fixture(performSend: { _ in .sent("iMessage") },
                                                   allowedRecipients: ["+1 (212) 555-0100"]))
        }
        #expect(executed.hasPrefix("[sandbox] Message sent successfully"))

        let preview = try captureStdout {
            let command = try Send_.parse(["--text", "--dry-run", "--test-mode",
                                           "+1 (212) 555-0100", "--message", "synthetic hello"])
            try command.run(dependencies: .fixture(allowedRecipients: ["+1 (212) 555-0100"]))
        }
        #expect(preview.hasPrefix("[sandbox] [dry-run] would send"))

        // Unsandboxed text output is unprefixed — the tag means something only if it is absent
        // when the sandbox is not engaged.
        let unsandboxed = try captureStdout {
            let command = try Send_.parse(["--text", "+1 (212) 555-0100", "--message", "synthetic hello"])
            try command.run(dependencies: .fixture(performSend: { _ in .sent("iMessage") }))
        }
        #expect(unsandboxed.hasPrefix("Message sent successfully"))
    }

    // MARK: - --service / --file (CLI extras over the oracle surface)

    /// A misspelled service is a BAD ARGUMENT, not a routing surprise: exit 64,
    /// `validation_error`, and the sender is never reached.
    @Test func sendRejectsAnUnknownService() throws {
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                       "--service", "rcs"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("an invalid service must not invoke sender")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect((error["message"] as? String)?.contains("auto, imessage, sms") == true)
    }

    /// `--message` became optional, so a send with neither a body nor a file would otherwise
    /// dispatch an osascript run that delivers nothing and reports success.
    @Test func sendRequiresAMessageOrAFile() throws {
        let command = try Send_.parse(["+1 (212) 555-0100"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("an empty send must not invoke sender")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.usage)
        #expect(try errorPayload(from: result.stdout)["type"] as? String == AppleErrorType.validation)
    }

    /// PRESENCE, not emptiness. `--message ""` still means "send this (empty) body", exactly as it
    /// did when `--message` was mandatory — making it newly invalid would be a behaviour change
    /// dressed up as a validation improvement.
    @Test func anExplicitlyEmptyMessageIsStillASend() throws {
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", ""])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.message == "")
                return .sent("iMessage")
            }))
        }
        #expect(try payload(from: output)["executed"] as? Bool == true)
    }

    /// Attachments are validated BEFORE anything is dispatched. Messages fails on a missing path
    /// only after the body has already gone out, and a half-send cannot be taken back. The
    /// refusal is whatever the SHARED resolver says — `not_found` (65) for a path that names
    /// nothing, the same code Mail's `--attach` has always returned for it.
    @Test func sendRejectsAMissingOrUnusableAttachmentBeforeSending() throws {
        let dir = try scratch.directory()
        let missing = dir.appendingPathComponent("no-such-file.txt").path
        for badPath in [missing, dir.path] {
            let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                           "--file", badPath])
            let result = try captureCommand {
                try command.run(dependencies: .fixture(performSend: { _ in
                    Issue.record("an unusable attachment must not invoke sender")
                    return .sent(nil)
                }))
            }

            #expect(result.exitCode == AppleExit.notFound)
            #expect(try errorPayload(from: result.stdout)["type"] as? String == AppleErrorType.notFound)
        }
    }

    /// `messages send --file` goes through the SHARED outbound-attachment guard, not a
    /// Messages-local check — so the containment Mail's `--attach` has always had now applies
    /// here too. The extension blocklist is what this pins, because it needs nothing but a
    /// scratch file: the credential-directory cases (a direct path, a symlinked parent, a
    /// symlinked directory) are proven against a SYNTHETIC `$HOME` in `AttachmentSourceTests`,
    /// via the resolver's `home:` seam, since the command layer offers no way to redirect it and
    /// this suite must never touch the operator's real `~/.ssh`.
    @Test func sendRoutesAttachmentsThroughTheSharedGuard() throws {
        let path = try scratch.directory().appendingPathComponent("apple-cli-test-payload.sh").path
        try "#!/bin/sh".write(toFile: path, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                       "--file", path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("a blocked attachment type must not invoke sender")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect((error["message"] as? String)?.contains("executable/script") == true)
        // A content-policy refusal, not a sandbox one — it fires with the sandbox off.
        #expect(error["sandbox"] == nil)
    }

    /// DRY-RUN REFUSES IDENTICALLY. A preview that reported "would send" for an attachment the
    /// execute path will refuse is the same class of lie as a preview that promises a refused
    /// recipient, and on this surface it is the one most likely to be acted on.
    @Test func aDryRunRefusesTheSameAttachmentsAnExecuteWould() throws {
        let dir = try scratch.directory()
        let executable = dir.appendingPathComponent("apple-cli-test-payload.sh").path
        try "#!/bin/sh".write(toFile: executable, atomically: true, encoding: .utf8)

        for path in [executable, dir.appendingPathComponent("no-such-file.txt").path,
                     dir.path] {
            var codes: [Int32] = []
            for extraArgs in [["--dry-run"], []] {
                let command = try Send_.parse(extraArgs + ["+1 (212) 555-0100",
                                                           "--message", "synthetic hello",
                                                           "--file", path])
                let result = try captureCommand {
                    try command.run(dependencies: .fixture(performSend: { _ in
                        Issue.record("a refused attachment must not invoke sender")
                        return .sent(nil)
                    }))
                }
                codes.append(result.exitCode ?? 0)
                #expect(!result.stdout.contains("would send"))
            }
            #expect(codes.first == codes.last, "dry-run and execute must refuse identically")
        }
    }

    /// EVERY path is checked before ANY of them is dispatched — a typo in the second path must not
    /// surface only after the first attachment has been delivered.
    @Test func oneBadAttachmentRefusesTheWholeBatch() throws {
        let dir = try scratch.directory()
        let good = dir.appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: good, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--file", good.path,
                                       "--file", dir.appendingPathComponent("missing.txt").path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("a batch with one bad path must not invoke sender at all")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.notFound)
    }

    /// The requested service reaches the sender, and the preview NAMES what the execute path will
    /// do. A preview that said "iMessage→SMS auto" for a send that will never try SMS is the same
    /// class of lie as a preview that promises a refused recipient.
    @Test func serviceFlagReachesTheSenderAndThePreview() throws {
        for (flag, plan) in [("auto", "iMessage→SMS auto"), ("imessage", "iMessage only"),
                             ("sms", "SMS only")] {
            let preview = try captureStdout {
                let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100",
                                               "--message", "synthetic hello", "--service", flag])
                try command.run(dependencies: .fixture())
            }
            let previewData = try payload(from: preview)
            #expect(previewData["service_plan"] as? String == plan)
            #expect(previewData["service_requested"] as? String == flag)
            #expect(previewData["files"] as? [String] == [])

            let executed = try captureStdout {
                let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                               "--service", flag])
                try command.run(dependencies: .fixture(performSend: { request in
                    #expect(request.service == Send.Service(rawValue: flag))
                    return .sent("iMessage")
                }))
            }
            #expect(try payload(from: executed)["service_requested"] as? String == flag)
        }
    }

    /// `auto` stays the default, so an unflagged send is routed exactly as it was before
    /// `--service` existed.
    @Test func theDefaultServiceIsAuto() throws {
        let output = try captureStdout {
            let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100",
                                           "--message", "synthetic hello"])
            try command.run(dependencies: .fixture())
        }
        let data = try payload(from: output)
        #expect(data["service_requested"] as? String == "auto")
        #expect(data["service_plan"] as? String == "iMessage→SMS auto")
    }

    /// A group send's service is the chat's own, so `--service` is ACCEPTED (one flag set works
    /// for both shapes) and has no effect: the plan stays "group chat" and the flag is reported
    /// verbatim so a caller can see it was ignored rather than silently honoured.
    @Test func groupSendAcceptsServiceButThePlanStaysGroupChat() throws {
        let output = try captureStdout {
            let command = try Send_.parse(["--dry-run", "--group", "iMessage;+;chat-example",
                                           "--message", "synthetic group hello", "--service", "sms"])
            try command.run(dependencies: .fixture())
        }
        let data = try payload(from: output)
        #expect(data["service_plan"] as? String == "group chat")
        #expect(data["service_requested"] as? String == "sms")
    }

    /// Attachments reach the sender as absolute standardized paths, in the order given, and both
    /// envelopes carry them: `files` on the preview and the execute, `files_sent` on the execute.
    @Test func attachmentsReachTheSenderAndBothEnvelopes() throws {
        let dir = try scratch.directory()
        let first = dir.appendingPathComponent("apple-cli-test-a.txt")
        let second = dir.appendingPathComponent("apple-cli-test-b.txt")
        try "synthetic a".write(to: first, atomically: true, encoding: .utf8)
        try "synthetic b".write(to: second, atomically: true, encoding: .utf8)

        let preview = try captureStdout {
            let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100",
                                           "--message", "synthetic hello",
                                           "--file", first.path, "--file", second.path])
            try command.run(dependencies: .fixture())
        }
        #expect(try payload(from: preview)["files"] as? [String] == [first.path, second.path])

        let executed = try captureStdout {
            let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                           "--file", first.path, "--file", second.path])
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.files == [first.path, second.path])
                #expect(request.message == "synthetic hello")
                return .sent("iMessage", files: 2)
            }))
        }
        let data = try payload(from: executed)
        #expect(data["files"] as? [String] == [first.path, second.path])
        #expect(data["files_sent"] as? Int == 2)
    }

    /// A file-only send carries no body at all — `message: nil`, not `""` — so the script that is
    /// built reads no body argument and the envelope reports no `message`.
    @Test func aFileOnlySendCarriesNoBody() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-only.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)

        let output = try captureStdout {
            let command = try Send_.parse(["+1 (212) 555-0100", "--file", file.path])
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.message == nil)
                #expect(request.files == [file.path])
                return .sent("iMessage", files: 1)
            }))
        }
        let data = try payload(from: output)
        #expect(data["message"] == nil)
        #expect(data["files_sent"] as? Int == 1)
    }

    /// A multi-part send is NOT atomic: a failure at attachment 2 leaves the body and attachment 1
    /// delivered. The error must therefore name which attachment failed AND list what already went
    /// out in `error.applied`, because a retry that includes those sends them a second time.
    @Test func aMidBatchAttachmentFailureReportsWhatWasAlreadyDelivered() throws {
        let dir = try scratch.directory()
        let first = dir.appendingPathComponent("apple-cli-test-a.txt")
        let second = dir.appendingPathComponent("apple-cli-test-b.txt")
        try "synthetic a".write(to: first, atomically: true, encoding: .utf8)
        try "synthetic b".write(to: second, atomically: true, encoding: .utf8)

        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                       "--file", first.path, "--file", second.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "transfer refused", filesSent: 1, failedFile: 2)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
        let message = try #require(error["message"] as? String)
        #expect(message.contains("attachment 2 of 2"))
        #expect(message.contains(second.path))
        #expect(message.contains("files_sent=1"))
        #expect(error["applied"] as? [String] == [first.path])
        // The raw osascript text stays OFF the envelope and on the human channel, as it already
        // did for a whole-send failure.
        #expect(!result.stdout.contains("transfer refused"))
        #expect(result.stderr == "osascript: transfer refused\n")
    }

    /// A failure that was NOT during a file send delivered nothing, so the generic message stands
    /// and there is no `applied` list to exclude from a retry.
    @Test func aBodyFailureKeepsTheGenericMessageAndNoAppliedList() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                       "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "no iMessage service")
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["message"] as? String == "send failed (Messages returned an error).")
        #expect(error["applied"] == nil)
    }

    /// The reviewer's case, end to end: a FILE-ONLY send where the iMessage half died on the one
    /// attachment and no SMS account exists. The script clears the in-flight counter before the
    /// account lookup, so the outcome carries no failed attachment — and the CLI must then report
    /// the generic failure rather than claiming attachment 1 of 1 went wrong when nothing was
    /// transferred at all.
    @Test func aFallbackThatTransferredNothingDoesNotBlameAnAttachment() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "Both iMessage and SMS failed", filesSent: 0, failedFile: nil)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["message"] as? String == "send failed (Messages returned an error).")
        #expect(error["applied"] == nil)
        #expect((error["message"] as? String)?.contains("attachment") == false)
    }

    /// THE DUPLICATE THE OLD MESSAGE CAUSED. `filesSent` counts attachments only, so a run that
    /// delivered the BODY and then failed on attachment 1 has `filesSent == 0` and an empty
    /// `applied` — and the old wording ("anything already delivered is listed in `applied`") told
    /// an agent that nothing had gone out. Doing exactly what it said re-sent the body to a real
    /// person: the duplicate the fallback latch exists to prevent, reintroduced by the error text.
    @Test func aBodyDeliveredBeforeAFailedAttachmentIsNamedInTheEnvelope() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                       "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "transfer refused", filesSent: 0, failedFile: 1, bodyDelivered: true)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        let message = try #require(error["message"] as? String)
        #expect(message.contains("attachment 1 of 1"))
        #expect(message.contains("The message body WAS already delivered"))
        #expect(message.contains("omit --message from a retry"))
        // No attachment went out, so there is nothing to exclude by path.
        #expect(error["applied"] == nil)
    }

    /// The same fact on the OTHER branch: no attachment was ever in flight (body out, then the SMS
    /// account lookup failed), so `failedFile` is nil and the generic message is used — it must
    /// still say the body went out.
    @Test func aBodyDeliveredWithNoFailedAttachmentIsStillNamed() throws {
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "no enabled SMS account", bodyDelivered: true)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let message = try #require(try errorPayload(from: result.stdout)["message"] as? String)
        #expect(message.hasPrefix("send failed (Messages returned an error)."))
        #expect(message.contains("The message body WAS already delivered"))
    }

    /// And the converse, so the sentence means something: a file-only send that delivered nothing
    /// must NOT claim a body went out — there was no body to deliver.
    @Test func aFileOnlySendNeverClaimsADeliveredBody() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: "Both iMessage and SMS failed", filesSent: 0, failedFile: 1)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let message = try #require(try errorPayload(from: result.stdout)["message"] as? String)
        #expect(message.contains("attachment 1 of 1"))
        #expect(!message.contains("message body"))
    }

    /// `--group --file` is a real, reachable shape: the group script builds the same attachment
    /// loop, so every participant in the chat receives each file. Nothing downstream of the seam
    /// exercised it before, and no document mentioned it.
    @Test func groupSendCarriesAttachmentsToTheChat() throws {
        let dir = try scratch.directory()
        let first = dir.appendingPathComponent("apple-cli-test-a.txt")
        let second = dir.appendingPathComponent("apple-cli-test-b.txt")
        try "synthetic a".write(to: first, atomically: true, encoding: .utf8)
        try "synthetic b".write(to: second, atomically: true, encoding: .utf8)
        let chatId = "iMessage;+;chat-example"

        let preview = try captureStdout {
            let command = try Send_.parse(["--dry-run", "--group", chatId,
                                           "--message", "synthetic group hello",
                                           "--file", first.path, "--file", second.path])
            try command.run(dependencies: .fixture())
        }
        let previewData = try payload(from: preview)
        #expect(previewData["group_chat"] as? Bool == true)
        #expect(previewData["service_plan"] as? String == "group chat")
        #expect(previewData["files"] as? [String] == [first.path, second.path])

        let executed = try captureStdout {
            let command = try Send_.parse(["--group", chatId, "--message", "synthetic group hello",
                                           "--file", first.path, "--file", second.path])
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.groupChat == true)
                #expect(request.handle == chatId)
                #expect(request.files == [first.path, second.path])
                return .sent(nil, files: 2)
            }))
        }
        let data = try payload(from: executed)
        #expect(data["group_chat"] as? Bool == true)
        #expect(data["files"] as? [String] == [first.path, second.path])
        #expect(data["files_sent"] as? Int == 2)
        // A group send still reports no service — Messages does not name the chat's own.
        #expect(data["service_used"] == nil)
    }

    /// `--service sms` to an address with no digits in it is knowably impossible — the oracle's own
    /// phone-shaped test says so, and it is the same test that stops the `auto` fallback trying SMS
    /// for an email. Naming it at exit 64 beats an opaque `upstream_error` after Messages has been
    /// asked to do it.
    @Test func smsToAnEmailRecipientIsRefusedBeforeTheSender() throws {
        let command = try Send_.parse(["jane.doe@example.com", "--message", "synthetic hello",
                                       "--service", "sms"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("an unreachable SMS recipient must not invoke sender")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect((error["message"] as? String)?.contains("SMS needs a phone number") == true)
    }

    /// The refusal is scoped: `auto` and `imessage` must still reach an email address, and a phone
    /// number must still reach `sms`. Without this the pre-validation could quietly become "no
    /// email recipients at all".
    @Test func theSMSPreValidationDoesNotTouchTheOtherServices() throws {
        for flag in ["auto", "imessage"] {
            let output = try captureStdout {
                let command = try Send_.parse(["--dry-run", "jane.doe@example.com",
                                               "--message", "synthetic hello", "--service", flag])
                try command.run(dependencies: .fixture())
            }
            #expect(try payload(from: output)["service_requested"] as? String == flag)
        }
        let phone = try captureStdout {
            let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100",
                                           "--message", "synthetic hello", "--service", "sms"])
            try command.run(dependencies: .fixture())
        }
        #expect(try payload(from: phone)["service_plan"] as? String == "SMS only")
    }

    /// ORDERING PIN. Attachment resolution runs BELOW the sandbox gate. Above it, a sandbox-refused
    /// send with a bad path returned a plain file `validation_error` with no `sandbox: true` for a
    /// caller to branch on — and `--dry-run` stat-ed arbitrary paths, reporting exists/directory
    /// back on stdout, for a send that was never going to happen.
    @Test func theSandboxRefusalPrecedesAttachmentValidation() throws {
        let missing = try scratch.directory().appendingPathComponent("no-such-file.txt").path
        for extraArgs in [[], ["--dry-run"]] {
            let command = try Send_.parse(extraArgs + ["--test-mode", "+1 (212) 555-0100",
                                                       "--message", "synthetic hello",
                                                       "--file", missing])
            let result = try captureCommand {
                try command.run(dependencies: .fixture(allowedRecipients: []))
            }

            #expect(result.exitCode == AppleExit.usage)
            let error = try errorPayload(from: result.stdout)
            // The SANDBOX refusal, not the file one — that is the whole point of the ordering.
            #expect(error["sandbox"] as? Bool == true)
            #expect((error["message"] as? String)?.hasPrefix("refusing send:") == true)
            #expect(!result.stdout.contains("no-such-file"))
        }
    }

    /// The same ordering for the empty-send guard. Every refusal that depends on the RECIPIENT
    /// having been accepted belongs below the sandbox gate, so a caller branching on
    /// `error.sandbox` is never handed an ordinary argument error for a send the sandbox is what
    /// actually stopped.
    @Test func theSandboxRefusalPrecedesTheNothingToSendGuard() throws {
        let command = try Send_.parse(["--test-mode", "+1 (212) 555-0100"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(allowedRecipients: []))
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["sandbox"] as? Bool == true)
        #expect((error["message"] as? String)?.hasPrefix("refusing send:") == true)
        #expect((error["message"] as? String)?.contains("nothing to send") == false)
    }

    /// `files_sent` is an EXECUTE-only key: a dry run sent nothing, and reporting `0` there would
    /// read as "it ran and delivered none of them".
    @Test func theDryRunEnvelopeOmitsFilesSent() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let output = try captureStdout {
            let command = try Send_.parse(["--dry-run", "+1 (212) 555-0100",
                                           "--message", "synthetic hello", "--file", file.path])
            try command.run(dependencies: .fixture())
        }
        let data = try payload(from: output)
        #expect(data["files"] as? [String] == [file.path])
        #expect(data["files_sent"] == nil)
        #expect(data["dry_run"] as? Bool == true)
    }

    /// The RESOLVED path is what reaches the sender and what the envelope reports — a symlink is
    /// sent as the file it points at, which is what the manual, the changelog and the port spec
    /// now say. (The first draft refused a symlink outright while all four documents promised the
    /// opposite.)
    @Test func aSymlinkedAttachmentIsReportedAsItsTarget() throws {
        let dir = try scratch.directory()
        let target = dir.appendingPathComponent("apple-cli-test-target.txt")
        try "synthetic".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("apple-cli-test-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let resolved = target.resolvingSymlinksInPath().path

        let output = try captureStdout {
            let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello",
                                           "--file", link.path])
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.files == [resolved])
                return .sent("iMessage", files: 1)
            }))
        }
        let data = try payload(from: output)
        #expect(data["files"] as? [String] == [resolved])
        #expect((data["files"] as? [String])?.first?.hasSuffix("apple-cli-test-link.txt") == false)
    }

    /// MUTATION KILL for the `message != nil` half of the body note. A file-only send whose
    /// outcome nonetheless reports `bodyDelivered` must NOT claim a body went out — there was no
    /// body. Without this, dropping the `message != nil` conjunct stays green.
    @Test func aFileOnlySendSuppressesTheBodyNoteEvenIfTheOutcomeClaimsIt() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["+1 (212) 555-0100", "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { request in
                #expect(request.message == nil)
                return .failed(error: "transfer refused", filesSent: 0, failedFile: 1,
                               bodyDelivered: true)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        let message = try #require(try errorPayload(from: result.stdout)["message"] as? String)
        #expect(message.contains("attachment 1 of 1"))
        #expect(!message.contains("message body"))
        #expect(!message.contains("omit --message"))
    }

    /// `--text` has to describe an attachment-bearing send too, or a file-only send renders as a
    /// blank line after "would send … via …:".
    @Test func textOutputDescribesAttachments() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)

        let preview = try captureStdout {
            let command = try Send_.parse(["--text", "--dry-run", "+1 (212) 555-0100",
                                           "--file", file.path])
            try command.run(dependencies: .fixture())
        }
        #expect(preview.contains("[1 file(s): \(file.path)]"))
        #expect(preview.contains("via iMessage→SMS auto"))

        let executed = try captureStdout {
            let command = try Send_.parse(["--text", "+1 (212) 555-0100",
                                           "--message", "synthetic hello", "--file", file.path])
            try command.run(dependencies: .fixture(performSend: { _ in .sent("iMessage", files: 1) }))
        }
        #expect(executed.contains("(1 of 1 file(s) sent)"))

        // A plain text send is unchanged — no attachment noise when there are none.
        let plain = try captureStdout {
            let command = try Send_.parse(["--text", "+1 (212) 555-0100", "--message", "synthetic hello"])
            try command.run(dependencies: .fixture(performSend: { _ in .sent("iMessage") }))
        }
        #expect(plain.hasPrefix("Message sent successfully via iMessage"))
        #expect(!plain.contains("file(s)"))
    }

    /// The sandbox restriction is unchanged by either flag: a non-allowlisted recipient is still
    /// refused before anything is validated, dispatched, or previewed.
    @Test func theSandboxAllowlistStillGovernsAnAttachmentSend() throws {
        let file = try scratch.directory().appendingPathComponent("apple-cli-test-a.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        let command = try Send_.parse(["--test-mode", "+1 (212) 555-0100", "--service", "sms",
                                       "--file", file.path])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("a sandbox-refused recipient must not invoke sender")
                return .sent(nil)
            }, allowedRecipients: []))
        }

        #expect(result.exitCode == AppleExit.usage)
        #expect(try errorPayload(from: result.stdout)["sandbox"] as? Bool == true)
    }

    // MARK: - Reads + diagnostics

    @Test func chatsUsesInjectedChatDB() throws {
        let command = try Chats.parse([])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 2)
        #expect(data["name_filter"] is NSNull)
        let chats = try #require(data["chats"] as? [[String: Any]])
        #expect(chats.first?["display_name"] as? String == "Test Group")
    }

    /// The chat-identity keys are contract-documented as `string|null`, so they must be PRESENT
    /// and null for a message in no chat — Swift's synthesized encoder would have omitted them,
    /// which is the shape a consumer cannot tell apart from an older binary.
    @Test func recentEmitsChatIdentityWithExplicitNulls() throws {
        let command = try Recent.parse(["--hours", "24", "--limit", "100"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["direct_only"] as? Bool == false)
        let messages = try #require(data["messages"] as? [[String: Any]])
        let byRow = Dictionary(uniqueKeysWithValues: messages.compactMap { m -> (Int, [String: Any])? in
            (m["rowid"] as? Int).map { ($0, m) }
        })

        let group = try #require(byRow[4])
        #expect(group["chat_identifier"] as? String == "chat999")
        #expect(group["chat_guid"] as? String == "iMessage;+;chat999")
        #expect(group["is_group"] as? Bool == true)

        let orphan = try #require(byRow[3])
        #expect(orphan["chat_identifier"] is NSNull)
        #expect(orphan["chat_guid"] is NSNull)
        #expect(orphan["is_group"] as? Bool == false)
        // `group_name` keeps its pre-existing omit-when-absent shape; only the new keys are nulls.
        #expect(orphan["group_name"] == nil)
    }

    @Test func recentDirectOnlyFiltersAndIsEchoed() throws {
        let command = try Recent.parse(["--hours", "24", "--limit", "100", "--direct-only"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["direct_only"] as? Bool == true)
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.compactMap { $0["rowid"] as? Int } == [1, 2, 3, 6, 8, 9, 10])
        #expect(messages.allSatisfy { $0["is_group"] as? Bool == false })
    }

    /// A `--direct-only` the store cannot honor must SAY so. The caller asked to exclude group
    /// chats and is getting them back, so silence here is a filter failing open — the shape this
    /// module already has a scar from (see the privacy note in `ChatDB.recent`).
    ///
    /// The text assertions are not padding: the warning goes to a terminal verbatim, which
    /// AGENTS.md treats as user-facing documentation, and this string was FIRST WRITTEN with a
    /// nine-space gap in the middle of the sentence — a wrapped source line rejoined without
    /// dropping its continuation indent. Reading the Swift source did not show it; rendering it
    /// did. So the rendering is what gets asserted.
    @Test func directOnlyWarnsOnStderrWhenTheStoreCannotClassifyChats() throws {
        try chat.exec(styleLessChatSchema)
        let result = try captureCommand {
            try Recent.parse(["--hours", "24", "--direct-only"])
                .run(dependencies: fixtureDependencies(chat))
        }

        #expect(result.stderr.contains("warning: --direct-only was not applied."))
        #expect(result.stderr.contains("cannot report which chat a message belongs to"))
        #expect(!result.stderr.contains("  "), "no run of spaces: \(result.stderr.debugDescription)")
        #expect(result.stderr.hasSuffix("excluded.\n"))
        // The read itself still succeeds and excludes nothing — the warning explains the rows,
        // it does not replace them.
        let data = try payload(from: result.stdout)
        #expect(data["direct_only"] as? Bool == true)
        #expect((data["messages"] as? [[String: Any]])?.count == 9)
        // THE JSON CHANNEL CARRIES IT TOO. stderr is not the versioned interface, so a machine
        // consumer that only reads stdout must still be able to see that the filter did not run.
        #expect(data["direct_only_applied"] as? Bool == false)
    }

    /// `search` has the same fail-open surface as `recent`, and had no coverage for it.
    @Test func searchDirectOnlyReportsWhenItCouldNotBeApplied() throws {
        try chat.exec(styleLessChatSchema)
        let result = try captureCommand {
            try Search.parse(["error", "--hours", "24", "--match", "contains", "--direct-only"])
                .run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: result.stdout)
        #expect(data["direct_only"] as? Bool == true)
        #expect(data["direct_only_applied"] as? Bool == false)
        // The group-chat hit is still present, which is exactly why the flag above must say so.
        #expect(data["count"] as? Int == 1)
        #expect(result.stderr.contains("warning: --direct-only was not applied."))
    }

    /// The applied case on both commands, so `direct_only_applied` is not vacuously always false.
    @Test func directOnlyAppliedIsTrueWhenTheFilterRuns() throws {
        let deps = fixtureDependencies(chat)

        let recent = try payload(from: captureStdout {
            try Recent.parse(["--hours", "24", "--direct-only"]).run(dependencies: deps)
        })
        #expect(recent["direct_only"] as? Bool == true)
        #expect(recent["direct_only_applied"] as? Bool == true)

        let search = try payload(from: captureStdout {
            try Search.parse(["hello", "--hours", "24", "--match", "contains", "--direct-only"])
                .run(dependencies: deps)
        })
        #expect(search["direct_only_applied"] as? Bool == true)

        // …and an unrequested filter reports both false rather than a vacuous "applied".
        let plain = try payload(from: captureStdout {
            try Recent.parse(["--hours", "24"]).run(dependencies: deps)
        })
        #expect(plain["direct_only"] as? Bool == false)
        #expect(plain["direct_only_applied"] as? Bool == false)
    }

    /// The `--contact` branches return EARLY. They used to emit `direct_only: true` with no
    /// warning and nothing to say the filter had not run, which is why the capability is now
    /// resolved above them rather than beside the query.
    @Test func directOnlyIsReportedOnTheEarlyContactReturns() throws {
        try chat.exec(styleLessChatSchema)
        let path = chat.path
        let homePath = chat.homePath
        let book = AddressBook(contacts: [
            "12125550100": "Alice Example",
            "12125550101": "Alice Example",
        ])
        let deps = MessagesCommandDependencies.fixture(book: book, makeChatDB: { _ in
            try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
        })

        // Unmatched contact — the "no contacts found" early return.
        let unmatched = try captureCommand {
            try Recent.parse(["--contact", "Zzyzx Qqqqq", "--hours", "24", "--direct-only"])
                .run(dependencies: deps)
        }
        let unmatchedData = try payload(from: unmatched.stdout)
        #expect(unmatchedData["direct_only"] as? Bool == true)
        #expect(unmatchedData["direct_only_applied"] as? Bool == false)
        #expect(unmatched.stderr.contains("warning: --direct-only was not applied."))

        // Ambiguous contact — the ranked-candidates early return.
        let ambiguous = try captureCommand {
            try Recent.parse(["--contact", "Alice", "--hours", "24", "--direct-only"])
                .run(dependencies: deps)
        }
        let ambiguousData = try payload(from: ambiguous.stdout)
        #expect(ambiguousData["ambiguous"] as? Bool == true)
        #expect(ambiguousData["direct_only_applied"] as? Bool == false)
        #expect(ambiguous.stderr.contains("warning: --direct-only was not applied."))
    }

    /// Negative control: a store that CAN classify chats must stay quiet, or the warning would
    /// be noise on every ordinary run and get tuned out.
    @Test func directOnlyIsSilentWhenTheFilterActuallyApplies() throws {
        let result = try captureCommand {
            try Recent.parse(["--hours", "24", "--direct-only"])
                .run(dependencies: fixtureDependencies(chat))
        }
        #expect(result.stderr.isEmpty)
        #expect((try payload(from: result.stdout)["messages"] as? [[String: Any]])?.count == 7)
    }

    @Test func searchDirectOnlyFiltersAndIsEchoed() throws {
        let deps = fixtureDependencies(chat)

        let all = try payload(from: captureStdout {
            try Search.parse(["error", "--hours", "24", "--match", "contains"]).run(dependencies: deps)
        })
        #expect(all["direct_only"] as? Bool == false)
        #expect(all["count"] as? Int == 1)

        let direct = try payload(from: captureStdout {
            try Search.parse(["error", "--hours", "24", "--match", "contains", "--direct-only"])
                .run(dependencies: deps)
        })
        #expect(direct["direct_only"] as? Bool == true)
        #expect(direct["count"] as? Int == 0)
    }

    @Test func chatsReportActivityParticipantsAndFilters() throws {
        let deps = fixtureDependencies(chat)

        let unfiltered = try payload(from: captureStdout {
            try Chats.parse([]).run(dependencies: deps)
        })
        let chats = try #require(unfiltered["chats"] as? [[String: Any]])
        let group = try #require(chats.first)
        // Assert the RENDERING, not merely that a string is there: the docs promise ISO-8601,
        // and a change of `dateEncodingStrategy` away from `.iso8601` would keep a
        // string-is-non-nil check green while breaking the documented contract.
        let expected = ISO8601DateFormatter().string(from: MessageTime.date(fromRaw: chat.base - 300))
        #expect(group["last_activity"] as? String == expected)
        #expect(group["last_activity_timestamp"] as? Int == Int(chat.base - 300))
        #expect(group["participants"] as? [String] == ["+12125550101", "+12125550102"])
        let quiet = try #require(chats.last)
        #expect(quiet["display_name"] as? String == "Other Group")
        #expect(quiet["last_activity"] is NSNull)
        #expect(quiet["last_activity_timestamp"] is NSNull)
        #expect((quiet["participants"] as? [String])?.isEmpty == true)

        let filtered = try payload(from: captureStdout {
            try Chats.parse(["--name", "oTHer"]).run(dependencies: deps)
        })
        #expect(filtered["count"] as? Int == 1)
        #expect(filtered["name_filter"] as? String == "oTHer")
        #expect((filtered["chats"] as? [[String: Any]])?.first?["display_name"] as? String == "Other Group")

        let limited = try payload(from: captureStdout {
            try Chats.parse(["--limit", "1"]).run(dependencies: deps)
        })
        #expect(limited["count"] as? Int == 1)
        #expect(limited["name_filter"] is NSNull)
        #expect((limited["chats"] as? [[String: Any]])?.first?["display_name"] as? String == "Test Group")
    }

    /// An empty `--name` is the reachable form of the envelope-vs-behavior mismatch: an unset
    /// shell variable expands to one. It must read as NO filter on both channels, not as a
    /// filter that happened to match everything.
    @Test func chatsEmptyNameIsNotAFilter() throws {
        let deps = fixtureDependencies(chat)

        let data = try payload(from: captureStdout {
            try Chats.parse(["--name", ""]).run(dependencies: deps)
        })
        #expect(data["name_filter"] is NSNull, "an empty --name must not echo as a filter")
        #expect(data["count"] as? Int == 2, "and must not narrow the listing")

        let text = try captureStdout {
            try Chats.parse(["--text", "--name", ""]).run(dependencies: deps)
        }
        #expect(text.contains("Available group chats:"))
        #expect(!text.contains("matching ''"))
    }

    @Test func chatsTextRendererShowsActivityAndParticipants() throws {
        let deps = fixtureDependencies(chat)

        let listing = try captureStdout {
            try Chats.parse(["--text", "--name", "test"]).run(dependencies: deps)
        }
        #expect(listing.contains("Available group chats matching 'test':"))
        #expect(listing.contains("1. Test Group (ID: chat999)"))
        #expect(listing.contains("last activity "))
        #expect(listing.contains("participants: +12125550101, +12125550102"))

        let empty = try captureStdout {
            try Chats.parse(["--text", "--name", "no-such-chat"]).run(dependencies: deps)
        }
        #expect(empty.contains("No named group chats matching 'no-such-chat'."))
    }

    @Test func conversationsCommandListsAllChatShapesAndPaginates() throws {
        let deps = fixtureDependencies(chat)
        let first = try payload(from: captureStdout {
            try Conversations.parse(["--limit", "1"]).run(dependencies: deps)
        })
        #expect(first["count"] as? Int == 1)
        #expect(first["cursor"] is NSNull)
        let cursor = try #require(first["next_cursor"] as? String)
        let rows = try #require(first["conversations"] as? [[String: Any]])
        #expect(rows.first?["chat_rowid"] != nil)
        #expect(rows.first?["last_activity_normalized_seconds"] != nil)
        #expect(rows.first?["last_activity_normalized_nanoseconds"] != nil)

        let second = try payload(from: captureStdout {
            try Conversations.parse(["--limit", "100", "--cursor", cursor]).run(dependencies: deps)
        })
        #expect(second["next_cursor"] is NSNull)
        let secondRows = try #require(second["conversations"] as? [[String: Any]])
        let ids = Set((rows + secondRows).compactMap { $0["chat_rowid"] as? Int })
        #expect(ids.isSuperset(of: [1, 2, 3]))
    }

    @Test func historyCommandSelectsByRowidAndGuid() throws {
        let deps = fixtureDependencies(chat)
        let byRowid = try payload(from: captureStdout {
            try History.parse(["--chat-rowid", "3", "--limit", "100"]).run(dependencies: deps)
        })
        #expect(byRowid["chat_rowid"] as? Int == 3)
        #expect(byRowid["chat_guid"] as? String == "iMessage;-;+12125550100")
        let rowMessages = try #require(byRowid["messages"] as? [[String: Any]])
        let multichat = try #require(rowMessages.first { $0["rowid"] as? Int == 4 })
        #expect(multichat["selected_chat_rowid"] as? Int == 3)
        #expect(multichat["chat_guid"] as? String == "iMessage;-;+12125550100")

        let byGuid = try payload(from: captureStdout {
            try History.parse(["--chat-guid", "iMessage;+;chat999", "--limit", "100"])
                .run(dependencies: deps)
        })
        #expect(byGuid["chat_rowid"] as? Int == 1)
        let guidMessages = try #require(byGuid["messages"] as? [[String: Any]])
        #expect(guidMessages.first { $0["rowid"] as? Int == 4 }?["selected_chat_rowid"] as? Int == 1)
    }

    @Test func getCommandRequiresSelectedConversationMembership() throws {
        let deps = fixtureDependencies(chat)
        let output = try payload(from: captureStdout {
            try Get.parse(["--chat-rowid", "3", "--message-rowid", "4"]).run(dependencies: deps)
        })
        #expect(output["chat_rowid"] as? Int == 3)
        let message = try #require(output["message"] as? [String: Any])
        #expect(message["rowid"] as? Int == 4)
        #expect(message["selected_chat_rowid"] as? Int == 3)
        #expect(message["native_parts"] is NSNull)
        #expect(message["native_parts_available"] as? Bool == false)
        #expect(message["native_parts_reason"] as? String == "absent-blob")
        let availability = try #require(message["body_availability"] as? [String: Any])
        #expect(availability["status"] as? String == "available")

        let wrongChat = try captureCommand {
            try Get.parse(["--chat-rowid", "1", "--message-rowid", "1"]).run(dependencies: deps)
        }
        #expect(wrongChat.exitCode == AppleExit.notFound)
    }

    @Test func reactionInspectUsesExactTargetAndReportsCurrentOutgoing() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, date: fx.base + 11)
        let addressBookLoads = LockedBox(0)
        let path = fx.path
        let homePath = fx.homePath
        let deps = MessagesCommandDependencies.fixture(
            loadAddressBook: {
                addressBookLoads.withLock { $0 += 1 }
                return AddressBook(contacts: ["12125550199": "Should Not Load"])
            },
            makeChatDB: { _ in
                try ChatDB(path: path, book: AddressBook(), copyToTemp: false,
                           homeDirectoryForTilde: homePath)
            })

        let output = try payload(from: captureStdout {
            try ReactionInspect.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                       "--part-index", "2", "--row-limit", "10"])
                .run(dependencies: deps)
        })

        #expect(addressBookLoads.value == 0)
        #expect(output["status"] as? String == "ok")
        let target = try #require(output["target"] as? [String: Any])
        #expect(target["message_rowid"] as? Int == 70)
        #expect(target["part_index"] as? Int == 2)
        #expect(target["mutation_eligible"] as? Bool == true)
        let current = try #require(output["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "present")
        #expect(current["key"] as? String == "heart")
        let evidence = try #require(output["evidence"] as? [String: Any])
        #expect(evidence["row_limit"] as? Int == 10)
        #expect(evidence["rows_examined"] as? Int == 1)
    }

    @Test func reactionInspectTextOutputPreservesDetailedCompatibilityFormat() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, date: fx.base + 11)
        let deps = fixtureDependencies(fx)

        let text = try captureStdout {
            try ReactionInspect.parse(["--text", "--chat-rowid", "3", "--message-rowid", "70",
                                       "--part-index", "2", "--row-limit", "10"])
                .run(dependencies: deps)
        }

        #expect(text == "reaction status=ok current=heart part=2 eligible=true\n")
    }

    @Test func reactionsInspectCommandReportsBoundedRows() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-like", associatedGUID: "p:2/reaction-target",
                              type: 2001, date: fx.base + 10)
        try fx.insertReaction(rowid: 101, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, isFromMe: 0, date: fx.base + 11)
        let deps = fixtureDependencies(fx)

        let output = try payload(from: captureStdout {
            try ReactionInspect.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                       "--row-limit", "1"])
                .run(dependencies: deps)
        })

        let evidence = try #require(output["evidence"] as? [String: Any])
        #expect(evidence["row_limit"] as? Int == 1)
        #expect(evidence["rows_examined"] as? Int == 1)
        #expect(evidence["rows_capped"] as? Bool == true)
        let reasons = try #require(evidence["unknown_reasons"] as? [String])
        #expect(reasons.contains("reaction-row-limit-exceeded"))
        let current = try #require(output["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "unknown")
    }

    @Test func reactionsInspectValidationErrorsEmitJSONWithoutLiveDependencies() throws {
        try expectValidationError(
            try ReactionInspect.parse(["--chat-rowid", "3", "--chat-guid", "chat",
                                       "--message-rowid", "70"]),
            run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(
            try ReactionInspect.parse(["--chat-rowid", "3"]),
            run: { try $0.run(dependencies: .fixture()) })

        let dbLoads = LockedBox(0)
        let deps = MessagesCommandDependencies.fixture(makeChatDB: { _ in
            dbLoads.withLock { $0 += 1 }
            throw AppleError.upstream("reaction inspect should validate before database construction")
        })
        let badLimit = try captureCommand {
            try ReactionInspect.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                       "--row-limit", "0"])
                .run(dependencies: deps)
        }
        #expect(badLimit.exitCode == AppleExit.usage)
        let error = try errorPayload(from: badLimit.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect((error["message"] as? String)?.contains("rowLimit must be between 1 and 10000") == true)

        let badPart = try captureCommand {
            try ReactionInspect.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                       "--part-index=-1"])
                .run(dependencies: deps)
        }
        #expect(badPart.exitCode == AppleExit.usage)
        let partError = try errorPayload(from: badPart.stdout)
        #expect(partError["type"] as? String == AppleErrorType.validation)
        #expect((partError["message"] as? String)?.contains("partIndex must be >= 0") == true)
        #expect(dbLoads.value == 0)
    }

    @Test func reactionSetDryRunDoesNotLaunchObservedWorkerOrCreateJournal() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let launched = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { _ in
            launched.withLock { $0 = true }
            return .timedOut
        }

        let output = try payload(from: captureStdout {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--dry-run", "--test-mode"])
                .run(dependencies: deps)
        })

        #expect(output["dry_run"] as? Bool == true)
        #expect(output["executed"] as? Bool == false)
        #expect(output["desired_reaction_key"] as? String == "like")
        #expect(launched.value == false)
    }

    @Test func reactionSandboxRequiresLabeledSingleAllowedParticipant() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target", text: "plain target")
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"])

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--dry-run", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.permissionDenied)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.safetyViolation)
        #expect(error["sandbox"] as? Bool == true)
    }

    @Test func reactionProductionDryRunAllowsExactGroupTargets() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target", chatRowid: 1)
        let deps = reactionDependencies(fx)

        let output = try payload(from: captureStdout {
            try ReactionSet.parse(["--chat-rowid", "1", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--dry-run"])
                .run(dependencies: deps)
        })

        #expect(output["dry_run"] as? Bool == true)
        #expect(output["executed"] as? Bool == false)
        #expect(output["desired_reaction_key"] as? String == "like")
    }

    @Test func reactionNoOpRunsThroughObservedLauncherPendingGate() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-like", associatedGUID: "p:2/reaction-target",
                              type: 2001, date: fx.base + 11)
        let sawAction = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            sawAction.withLock { $0 = true }
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected DB no-op: \(verification)")
            case .requiresMutation:
                let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(),
                                              category: .ack, detail: "reaction-set-unchanged-verified")
                let verification = try #require(try action.verify(resolved, response, context))
                return .observedState(operationID: UUID(uuidString: "10101010-1010-4010-8010-101010101010")!,
                                      verification: verification)
            }
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)

        #expect(sawAction.value == true)
        #expect(output["dry_run"] as? Bool == false)
        #expect(output["executed"] as? Bool == true)
        #expect(output["observed_state"] as? String == "observedState")
        #expect(output["verification_source"] as? String == "ui_selected_state_and_database_identity")
        #expect(output["reaction_changed"] as? Bool == false)
    }

    @Test func reactionExecuteRequiresAccessibilityAfterNoOpPreflight() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let attemptedHandoff = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"],
                                        accessibilityTrusted: false) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            do {
                switch try action.preflight(resolved, context) {
                case .alreadyInDesiredState:
                    throw ReactionTestFailure("accessibility is not required for a no-op")
                case .requiresMutation:
                    attemptedHandoff.withLock { $0 = true }
                    return .timedOut
                }
            } catch {
                return .requestNotSent(String(describing: error))
            }
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.permissionDenied)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.permissionDenied)
        #expect(error["status"] as? String == "accessibility_not_trusted")
        #expect(attemptedHandoff.value == false)
    }

    @Test func reactionExecuteBindsWorkerPayloadAndVerifiesFreshDatabaseState() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let observedCommand = LockedBox<WorkerCommand?>(nil)
        let operationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            observedCommand.withLock { $0 = resolved.command }
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-set-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil)
        let output = try payload(from: result.stdout)

        let command = try #require(observedCommand.value)
        #expect(command.name == "messages.reaction.set")
        let payloadData = try #require(command.payload)
        let workerPayload = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: payloadData)
        #expect(workerPayload.operation == .set)
        #expect(workerPayload.chatGUID == "iMessage;-;+12125550100")
        #expect(workerPayload.messageGUID == "reaction-target")
        #expect(workerPayload.nativePartIndex == 2)
        #expect(workerPayload.nativePartGUID == "p:2/reaction-target")
        #expect(output["dry_run"] as? Bool == false)
        #expect(output["executed"] as? Bool == true)
        #expect(output["operation_id"] as? String == operationID.uuidString)
        #expect(output["observed_state"] as? String == "observedState")
        #expect(output["verification_source"] as? String == "ui_selected_state_and_database_identity")
        #expect(output["reaction_changed"] as? Bool == true)
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "absent")
    }

    @Test func reactionExperimentalHandoffFlagBindsPayloadAndOutputMode() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let observedCommand = LockedBox<WorkerCommand?>(nil)
        let operationID = UUID(uuidString: "12121212-1212-4121-8121-121212121212")!
        let reactionDBPath = fx.path
        let reactionDate = fx.base + 12
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            observedCommand.withLock { $0 = resolved.command }
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            guard case .requiresMutation = try action.preflight(resolved, context) else {
                throw ReactionTestFailure("unexpected no-op")
            }
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "reaction-like",
                                  associatedGUID: "p:2/reaction-target", type: 2001,
                                  date: reactionDate)
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-set-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--experimental-ui-handoff", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        let command = try #require(observedCommand.value)
        let payloadData = try #require(command.payload)
        let workerPayload = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: payloadData)

        #expect(workerPayload.experimentalUIHandoff == true)
        #expect(output["targeting_mode"] as? String == "experimental_ui_handoff")
        #expect((output["limitation"] as? String)?.contains("cannot prove original message continuity after modal") == true)
    }

    @Test func reactionVerificationRejectsBareUnknownOrWrongOperationAckDetails() throws {
        for detail in [nil, "reaction-remove-changed-verified", "reaction-set-unknown-verified"] as [String?] {
            let fx = try ChatFixture()
            try fx.addReactionColumns()
            try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
            let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
                let resolved = try action.resolve()
                let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
                guard case .requiresMutation = try action.preflight(resolved, context) else {
                    throw ReactionTestFailure("unexpected no-op")
                }
                let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(),
                                              category: .ack, detail: detail)
                if try action.verify(resolved, response, context) != nil {
                    throw ReactionTestFailure("unexpectedly accepted ACK detail")
                }
                return .verificationFailed
            }

            let result = try captureCommand {
                try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                       "--reaction", "like", "--test-mode"])
                    .run(dependencies: deps)
            }
            #expect(result.exitCode == AppleExit.upstream)
        }
    }

    @Test func reactionImplicitRemoveRequiresSelectorWhenDatabaseHasNoOutgoingReaction() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"])

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.usage)
    }

    @Test func reactionImplicitRemoveKeepsResolvedDesiredKeyAfterStateTurnsAbsent() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, date: fx.base + 11)
        let operationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let reactionDBPath = fx.path
        let reactionDate = fx.base + 12
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "remove-heart",
                                  associatedGUID: "p:2/reaction-target", type: 3000,
                                  date: reactionDate)
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-remove-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)

        #expect(output["desired_reaction_key"] as? String == "heart")
        #expect(output["observed_state"] as? String == "observedState")
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "absent")
    }

    @Test func reactionVerificationRejectsRowidRetargetedToDifferentGuid() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let reactionDBPath = fx.path
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            try updateMessageGUID(path: reactionDBPath, rowid: 70, guid: "retargeted-message")
            let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: "reaction-set-changed-verified")
            if let verification = try action.verify(resolved, response, context) {
                throw ReactionTestFailure("verification unexpectedly accepted retargeted identity: \(verification)")
            }
            return .verificationFailed
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
    }

    @Test func reactionVerificationRejectsFreshAmbiguityForResolvedTarget() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let reactionDBPath = fx.path
        let duplicateDate = fx.base + 14
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            try insertBareMessage(path: reactionDBPath, rowid: 71, guid: "reaction-target", date: duplicateDate)
            let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: "reaction-set-changed-verified")
            if let verification = try action.verify(resolved, response, context) {
                throw ReactionTestFailure("verification unexpectedly accepted ambiguous identity: \(verification)")
            }
            return .verificationFailed
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
    }

    @Test func reactionObservedOutputUsesInspectCapturedBeforePostLockDrift() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let operationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let reactionDBPath = fx.path
        let firstReactionDate = fx.base + 12
        let secondReactionDate = fx.base + 13
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "reaction-like",
                                  associatedGUID: "p:2/reaction-target", type: 2001,
                                  date: firstReactionDate)
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-set-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            try insertReactionRow(path: reactionDBPath, rowid: 102, guid: "reaction-heart",
                                  associatedGUID: "p:2/reaction-target", type: 2000,
                                  date: secondReactionDate)
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["key"] as? String == "like")
    }

    @Test func reactionNoOpOutputUsesPreflightInspectBeforePostLockDrift() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-like", associatedGUID: "p:2/reaction-target",
                              type: 2001, date: fx.base + 11)
        let reactionDBPath = fx.path
        let removalDate = fx.base + 12
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected DB no-op: \(verification)")
            case .requiresMutation:
                let operationID = UUID(uuidString: "20202020-2020-4020-8020-202020202020")!
                let response = WorkerResponse(schemaVersion: 1, operationID: operationID, nonce: operationID,
                                              category: .ack, detail: "reaction-set-unchanged-verified")
                let verification = try #require(try action.verify(resolved, response, context))
                try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "remove-like",
                                      associatedGUID: "p:2/reaction-target", type: 3001,
                                      date: removalDate)
                return .observedState(operationID: operationID, verification: verification)
            }
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["key"] as? String == "like")
        #expect(output["verification_source"] as? String == "ui_selected_state_and_database_identity")
        #expect(output["reaction_changed"] as? Bool == false)
    }

    @Test func reactionExplicitCustomSetLaunchesWorkerWithExactPayload() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let observedCommand = LockedBox<WorkerCommand?>(nil)
        let operationID = UUID(uuidString: "23232323-2323-4323-8323-232323232323")!
        let reactionDBPath = fx.path
        let reactionDate = fx.base + 12
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            observedCommand.withLock { $0 = resolved.command }
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            guard case .requiresMutation = try action.preflight(resolved, context) else {
                throw ReactionTestFailure("unexpected custom set no-op")
            }
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "reaction-custom",
                                  associatedGUID: "p:2/reaction-target", type: 2006,
                                  date: reactionDate, emoji: "👍🏽")
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-set-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionSet.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                   "--emoji", "👍🏽", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        let command = try #require(observedCommand.value)
        #expect(command.name == "messages.reaction.set")
        let payloadData = try #require(command.payload)
        let workerPayload = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: payloadData)
        #expect(workerPayload.operation == .set)
        #expect(workerPayload.reaction == .custom("👍🏽"))
        #expect(output["desired_reaction_key"] as? String == "custom:👍🏽")
        #expect(output["reaction_changed"] as? Bool == true)
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["key"] as? String == "custom:👍🏽")
    }

    @Test func reactionExplicitCustomRemoveLaunchesWorkerWithExactPayload() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-custom", associatedGUID: "p:2/reaction-target",
                              type: 2006, date: fx.base + 11, emoji: "👍🏽")
        let observedCommand = LockedBox<WorkerCommand?>(nil)
        let operationID = UUID(uuidString: "24242424-2424-4242-8424-242424242424")!
        let reactionDBPath = fx.path
        let reactionDate = fx.base + 12
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            observedCommand.withLock { $0 = resolved.command }
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            guard case .requiresMutation = try action.preflight(resolved, context) else {
                throw ReactionTestFailure("unexpected custom remove no-op")
            }
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "remove-custom",
                                  associatedGUID: "p:2/reaction-target", type: 3006,
                                  date: reactionDate, emoji: "👍🏽")
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-remove-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                      "--emoji", "👍🏽", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        let command = try #require(observedCommand.value)
        #expect(command.name == "messages.reaction.remove")
        let payloadData = try #require(command.payload)
        let workerPayload = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: payloadData)
        #expect(workerPayload.operation == .remove)
        #expect(workerPayload.reaction == .custom("👍🏽"))
        #expect(output["desired_reaction_key"] as? String == "custom:👍🏽")
        #expect(output["reaction_changed"] as? Bool == true)
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "absent")
    }

    @Test func reactionExplicitCustomRemoveWorkerFailureLeavesCommandUnverified() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-custom", associatedGUID: "p:2/reaction-target",
                              type: 2006, date: fx.base + 11, emoji: "👍🏽")
        let resolvedBeforeFailure = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            guard case .requiresMutation = try action.preflight(resolved, context) else {
                throw ReactionTestFailure("unexpected custom remove no-op")
            }
            resolvedBeforeFailure.withLock { $0 = true }
            return .childRefusedOrFailed("reaction-unavailable")
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70", "--part-index", "2",
                                      "--emoji", "👍🏽", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
        #expect((error["message"] as? String)?.contains("reaction-unavailable") == true)
        #expect(resolvedBeforeFailure.value == true)
    }

    @Test func reactionImplicitCustomRemoveRemainsSafetyRefused() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-custom", associatedGUID: "p:2/reaction-target",
                              type: 2006, date: fx.base + 11, emoji: "👍")
        let preflightReached = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            do {
                _ = try action.resolve()
                preflightReached.withLock { $0 = true }
                return .timedOut
            } catch {
                return .requestNotSent(String(describing: error))
            }
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.permissionDenied)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.safetyViolation)
        #expect(preflightReached.value == false)
    }

    @Test func reactionLockedResolveRefusesStandardToCustomImplicitRemoveDrift() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, date: fx.base + 11)
        let reactionDBPath = fx.path
        let base = fx.base
        let preflightReached = LockedBox(false)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "reaction-custom",
                                  associatedGUID: "p:2/reaction-target", type: 2006,
                                  date: base + 12, emoji: "👍")
            do {
                _ = try action.resolve()
                preflightReached.withLock { $0 = true }
                return .timedOut
            } catch {
                return .requestNotSent(String(describing: error))
            }
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.permissionDenied)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.safetyViolation)
        #expect(preflightReached.value == false)
    }

    @Test func reactionImplicitRemoveOutputUsesLockedStandardAfterDrift() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        try fx.insertReaction(rowid: 100, guid: "reaction-heart", associatedGUID: "p:2/reaction-target",
                              type: 2000, date: fx.base + 11)
        let operationID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let reactionDBPath = fx.path
        let base = fx.base
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"]) { action in
            try insertReactionRow(path: reactionDBPath, rowid: 101, guid: "reaction-like",
                                  associatedGUID: "p:2/reaction-target", type: 2001,
                                  date: base + 12)
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            switch try action.preflight(resolved, context) {
            case .alreadyInDesiredState(let verification):
                throw ReactionTestFailure("unexpected reaction no-op: \(verification)")
            case .requiresMutation:
                break
            }
            try insertReactionRow(path: reactionDBPath, rowid: 102, guid: "remove-like",
                                  associatedGUID: "p:2/reaction-target", type: 3001,
                                  date: base + 13)
            let response = WorkerResponse(schemaVersion: 1, operationID: operationID,
                                          nonce: operationID, category: .ack,
                                          detail: "reaction-remove-changed-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: operationID, verification: verification)
        }

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--test-mode"])
                .run(dependencies: deps)
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        #expect(output["desired_reaction_key"] as? String == "like")
        let inspect = try #require(output["inspect"] as? [String: Any])
        let current = try #require(inspect["current_outgoing"] as? [String: Any])
        #expect(current["status"] as? String == "absent")
    }


    @Test func reactionExplicitRemoveAlreadyAbsentIsBlockedByPendingJournal() throws {
        let fx = try ChatFixture()
        try fx.addReactionColumns()
        try fx.insertReactionTarget(rowid: 70, guid: "reaction-target")
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        try seedUncertainPendingReaction(root: stateRoot, operationID: pendingID)
        let deps = reactionDependencies(fx, allowedRecipients: ["+12125550100"],
                                        launchObservedWorker: { try WorkerLauncher().launchObserved($0) })

        let result = try captureCommand {
            try ReactionRemove.parse(["--chat-rowid", "3", "--message-rowid", "70",
                                      "--part-index", "2", "--reaction", "like", "--test-mode"])
                .run(dependencies: deps)
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect((error["message"] as? String)?.contains("pending-operation-exists") == true)
    }

    @Test func automationRecoverDryRunFlagPreservesPendingJournal() throws {
        let fx = try ChatFixture()
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        try seedUncertainPendingReaction(root: stateRoot, operationID: pendingID)
        let deps = reactionDependencies(fx)

        let result = try TestEnvironment.withoutWriteModeOverrides {
            try captureCommand {
                try MessagesAutomationRecover.parse(["--op-id", pendingID.uuidString,
                                                     "--acknowledge-possible-late-effects", "--dry-run"])
                    .run(dependencies: deps)
            }
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        #expect(output["dry_run"] as? Bool == true)
        #expect(output["recovered"] as? Bool == false)
        let status = try readReactionJournalSnapshot(root: stateRoot)
        #expect(status.pending?.operationID == pendingID)
        #expect(status.receipts.isEmpty)
    }

    @Test func automationRecoverDryRunRejectsMismatchedOperationAndPreservesPendingJournal() throws {
        let fx = try ChatFixture()
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let otherID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        try seedUncertainPendingReaction(root: stateRoot, operationID: pendingID)
        let deps = reactionDependencies(fx)

        let result = try TestEnvironment.withoutWriteModeOverrides {
            try captureCommand {
                try MessagesAutomationRecover.parse(["--op-id", otherID.uuidString,
                                                     "--acknowledge-possible-late-effects", "--dry-run"])
                    .run(dependencies: deps)
            }
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect((error["message"] as? String)?.contains("operation-not-found") == true)
        let status = try readReactionJournalSnapshot(root: stateRoot)
        #expect(status.pending?.operationID == pendingID)
        #expect(status.receipts.isEmpty)
    }

    @Test func automationRecoverDryRunRejectsAbsentPendingJournal() throws {
        let fx = try ChatFixture()
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let deps = reactionDependencies(fx)

        let result = try TestEnvironment.withoutWriteModeOverrides {
            try captureCommand {
                try MessagesAutomationRecover.parse(["--op-id", pendingID.uuidString,
                                                     "--acknowledge-possible-late-effects", "--dry-run"])
                    .run(dependencies: deps)
            }
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect((error["message"] as? String)?.contains("operation-not-found") == true)
        let status = try readReactionJournalSnapshot(root: stateRoot)
        #expect(status.pending == nil)
        #expect(status.receipts.isEmpty)
    }

    @Test func automationRecoverDryRunRejectsPreparedBeforeHandoffAndPreservesPendingJournal() throws {
        let fx = try ChatFixture()
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        try seedPreparedPendingReaction(root: stateRoot, operationID: pendingID)
        let deps = reactionDependencies(fx)

        let result = try TestEnvironment.withoutWriteModeOverrides {
            try captureCommand {
                try MessagesAutomationRecover.parse(["--op-id", pendingID.uuidString,
                                                     "--acknowledge-possible-late-effects", "--dry-run"])
                    .run(dependencies: deps)
            }
        }

        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect((error["message"] as? String)?.contains("handoff-not-recorded") == true)
        let status = try readReactionJournalSnapshot(root: stateRoot)
        #expect(status.pending?.operationID == pendingID)
        #expect(status.pending?.phase == .preparedBeforeHandoff)
        #expect(status.receipts.isEmpty)
    }

    @Test func automationRecoverDryRunEnvironmentPreservesPendingJournal() throws {
        let fx = try ChatFixture()
        let stateRoot = fx.homePath + "/messages-automation"
        let pendingID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        try seedUncertainPendingReaction(root: stateRoot, operationID: pendingID)
        let deps = reactionDependencies(fx)

        let result = try TestEnvironment.withoutWriteModeOverrides {
            try TestEnvironment.with(["APPLE_DRY_RUN": "1"]) {
                try captureCommand {
                    try MessagesAutomationRecover.parse(["--op-id", pendingID.uuidString,
                                                         "--acknowledge-possible-late-effects"])
                        .run(dependencies: deps)
                }
            }
        }
        #expect(result.exitCode == nil, Comment(rawValue: result.stdout))
        let output = try payload(from: result.stdout)
        #expect(output["dry_run"] as? Bool == true)
        #expect(output["recovered"] as? Bool == false)
        let status = try readReactionJournalSnapshot(root: stateRoot)
        #expect(status.pending?.operationID == pendingID)
        #expect(status.receipts.isEmpty)
    }

    @Test func exactCommandOutputCarriesNativePartsNullAndArrayShapes() throws {
        let fx = try ChatFixture()
        try fx.addThreadOriginatorColumns()
        let blob = commandNativeArchive("Alice", [
            (commandNativePartKey, NSNumber(value: 2), NSRange(location: 0, length: 5))
        ])
        try fx.insertMessage(rowid: 60, guid: "native-command-array", attributedBody: blob,
                             chatRowid: 3, date: fx.base - 60)
        try fx.insertMessage(rowid: 61, guid: "native-command-empty",
                             attributedBody: commandNativeArchive("plain"),
                             chatRowid: 3, date: fx.base - 61)
        try fx.setThreadOriginator(rowid: 60, guidSQL: "'origin-command'", partSQL: "'2:opaque'")
        let deps = fixtureDependencies(fx)

        let getOutput = try payload(from: captureStdout {
            try Get.parse(["--chat-rowid", "3", "--message-rowid", "60"]).run(dependencies: deps)
        })
        let getMessage = try #require(getOutput["message"] as? [String: Any])
        #expect(getMessage["native_parts_available"] as? Bool == true)
        #expect(getMessage["native_parts_reason"] as? String == "available")
        let getParts = try #require(getMessage["native_parts"] as? [[String: Any]])
        #expect(getParts.count == 1)
        #expect(getParts[0]["index"] as? Int == 2)
        let ranges = try #require(getParts[0]["utf16_ranges"] as? [[String: Any]])
        #expect(ranges.count == 1)
        #expect(ranges[0]["location"] as? Int == 0)
        #expect(ranges[0]["length"] as? Int == 5)
        #expect(getParts[0]["attachment_guid"] is NSNull)
        let getOriginator = try #require(getMessage["thread_originator"] as? [String: Any])
        #expect(getOriginator["available"] as? Bool == true)
        #expect(getOriginator["reason"] as? String == "available")
        #expect(getOriginator["message_guid"] as? String == "origin-command")
        #expect(getOriginator["raw_part"] as? String == "2:opaque")
        #expect(getOriginator["native_part"] as? Int == 2)

        let historyOutput = try payload(from: captureStdout {
            try History.parse(["--chat-rowid", "3", "--limit", "100"]).run(dependencies: deps)
        })
        let messages = try #require(historyOutput["messages"] as? [[String: Any]])
        let historyMessage = try #require(messages.first { $0["rowid"] as? Int == 60 })
        #expect(historyMessage["native_parts_available"] as? Bool == true)
        #expect(historyMessage["native_parts_reason"] as? String == "available")
        #expect((historyMessage["native_parts"] as? [[String: Any]])?.count == 1)

        let empty = try #require(messages.first { $0["rowid"] as? Int == 61 })
        #expect(empty["native_parts_available"] as? Bool == true)
        #expect(empty["native_parts_reason"] as? String == "empty-known")
        #expect((empty["native_parts"] as? [[String: Any]])?.isEmpty == true)
        let emptyOriginator = try #require(empty["thread_originator"] as? [String: Any])
        #expect(emptyOriginator["available"] as? Bool == true)
        #expect(emptyOriginator["reason"] as? String == "no-linkage")
        #expect(emptyOriginator["message_guid"] is NSNull)
        #expect(emptyOriginator["raw_part"] is NSNull)
        #expect(emptyOriginator["native_part"] is NSNull)

        let absentOutput = try payload(from: captureStdout {
            try Get.parse(["--chat-rowid", "3", "--message-rowid", "6"]).run(dependencies: deps)
        })
        let absent = try #require(absentOutput["message"] as? [String: Any])
        #expect(absent["native_parts"] is NSNull)
        #expect(absent["native_parts_available"] as? Bool == false)
        #expect(absent["native_parts_reason"] as? String == "absent-blob")
        let absentOriginator = try #require(absent["thread_originator"] as? [String: Any])
        #expect(absentOriginator["available"] as? Bool == true)
        #expect(absentOriginator["reason"] as? String == "no-linkage")
        #expect(absentOriginator["message_guid"] is NSNull)
        #expect(absentOriginator["raw_part"] is NSNull)
        #expect(absentOriginator["native_part"] is NSNull)
    }

    @Test func exactReadCursorsRejectWrongScopeAndMalformedInput() throws {
        let deps = fixtureDependencies(chat)
        let page = try payload(from: captureStdout {
            try History.parse(["--chat-rowid", "3", "--limit", "1"]).run(dependencies: deps)
        })
        let cursor = try #require(page["next_cursor"] as? String)

        let wrongOperation = try captureCommand {
            try Conversations.parse(["--cursor", cursor]).run(dependencies: deps)
        }
        #expect(wrongOperation.exitCode == AppleExit.usage)
        #expect((try errorPayload(from: wrongOperation.stdout)["message"] as? String)?
            .contains("different operation") == true)

        let wrongOrder = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--order", "asc", "--cursor", cursor])
                .run(dependencies: deps)
        }
        #expect(wrongOrder.exitCode == AppleExit.usage)
        #expect((try errorPayload(from: wrongOrder.stdout)["message"] as? String)?
            .contains("different order") == true)

        let wrongChat = try captureCommand {
            try History.parse(["--chat-rowid", "1", "--cursor", cursor]).run(dependencies: deps)
        }
        #expect(wrongChat.exitCode == AppleExit.usage)
        #expect((try errorPayload(from: wrongChat.stdout)["message"] as? String)?
            .contains("different conversation") == true)

        let malformed = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", "not-base64"]).run(dependencies: deps)
        }
        #expect(malformed.exitCode == AppleExit.usage)

        let oversize = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", String(repeating: "a", count: 4097)])
                .run(dependencies: deps)
        }
        #expect(oversize.exitCode == AppleExit.usage)
        #expect((try errorPayload(from: oversize.stdout)["message"] as? String)?
            .contains("cursor too large") == true)


        let missingLastMessage = cursorJSON(#"{"v":1,"op":"history","chatRowid":3,"chatGuid":"iMessage;-;+12125550100","order":"desc","maxMessageRowid":10,"lastSeconds":100,"lastNanoseconds":0}"#)
        let missingLast = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", missingLastMessage]).run(dependencies: deps)
        }
        #expect(missingLast.exitCode == AppleExit.usage)

        let badNanos = cursorJSON(#"{"v":1,"op":"history","chatRowid":3,"chatGuid":"iMessage;-;+12125550100","order":"desc","maxMessageRowid":10,"lastSeconds":100,"lastNanoseconds":1000000000,"lastMessageRowid":1}"#)
        let badSortKey = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", badNanos]).run(dependencies: deps)
        }
        #expect(badSortKey.exitCode == AppleExit.usage)

        let outOfRange = cursorJSON(#"{"v":1,"op":"history","chatRowid":3,"chatGuid":"iMessage;-;+12125550100","order":"desc","maxMessageRowid":10,"lastSeconds":100,"lastNanoseconds":0,"lastMessageRowid":11}"#)
        let badRange = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", outOfRange]).run(dependencies: deps)
        }
        #expect(badRange.exitCode == AppleExit.usage)

        let unknownField = cursorJSON(#"{"v":1,"op":"history","chatRowid":3,"chatGuid":"iMessage;-;+12125550100","order":"desc","maxMessageRowid":10,"lastSeconds":100,"lastNanoseconds":0,"lastMessageRowid":1,"extra":true}"#)
        let unknown = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", unknownField]).run(dependencies: deps)
        }
        #expect(unknown.exitCode == AppleExit.usage)

        let duplicateField = cursorJSON(#"{"v":1,"op":"history","op":"history","chatRowid":3,"chatGuid":"iMessage;-;+12125550100","order":"desc","maxMessageRowid":10,"lastSeconds":100,"lastNanoseconds":0,"lastMessageRowid":1}"#)
        let duplicate = try captureCommand {
            try History.parse(["--chat-rowid", "3", "--cursor", duplicateField]).run(dependencies: deps)
        }
        #expect(duplicate.exitCode == AppleExit.usage)

        let conversationWithChatSelector = cursorJSON(#"{"v":1,"op":"conversations","chatRowid":3,"order":"desc","maxMessageRowid":10,"maxChatRowid":3,"lastSeconds":100,"lastNanoseconds":0,"lastChatRowid":1}"#)
        let wrongConversationShape = try captureCommand {
            try Conversations.parse(["--cursor", conversationWithChatSelector]).run(dependencies: deps)
        }
        #expect(wrongConversationShape.exitCode == AppleExit.usage)
    }

    @Test func exactReadValidationErrorsEmitJSONWithoutLiveDependencies() throws {
        try expectValidationError(try History.parse(["--chat-rowid", "0"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try History.parse(["--chat-rowid", "1", "--chat-guid", "g"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try History.parse(["--chat-guid", ""]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try History.parse(["--chat-rowid", "1", "--limit", "1001"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try History.parse(["--chat-rowid", "1", "--order", "sideways"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Get.parse(["--chat-rowid", "1", "--message-rowid", "0"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Get.parse(["--chat-rowid", "1"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Conversations.parse(["--limit", "0"]),
                                  run: { try $0.run(dependencies: .fixture()) })
    }

    @Test func searchUsesInjectedChatDB() throws {
        let command = try Search.parse(["decoded", "--hours", "24", "--match", "contains"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 1)
        #expect(data["match"] as? String == "contains")
        let messages = try #require(data["messages"] as? [[String: Any]])
        #expect(messages.first?["body"] as? String == "decoded body")
    }

    @Test func checkAvailabilityUsesInjectedChatDB() throws {
        let command = try CheckAvailability.parse(["+1 (212) 555-0100"])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["available"] as? Bool == true)
        #expect(data["service"] as? String == "iMessage")
    }

    @Test func checkDBUsesInjectedDiagnostic() throws {
        let command = try CheckDB.parse([])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(dbDiagnostic: {
                ChatDB.DBCheck(path: syntheticChatDBPath, exists: true, readable: true,
                               connected: true, table_count: 3, has_message_table: true,
                               has_handle_table: true, has_chat_table: true, message_count: 12)
            }))
        }

        let data = try payload(from: output)
        #expect(data["path"] as? String == syntheticChatDBPath)
        #expect(data["connected"] as? Bool == true)
        #expect(data["message_count"] as? Int == 12)
    }

    @Test func checkContactsUsesInjectedAddressBookAndSortsSamples() throws {
        let command = try CheckContacts.parse([])
        let details = [
            "12125550101": AddressBook.Details(firstName: "Bob", lastName: "Yellow",
                                               nickname: "", fullName: "Bob Yellow"),
            "12125550100": AddressBook.Details(firstName: "Alice", lastName: "Able",
                                               nickname: "", fullName: "Alice Able"),
        ]
        let output = try captureStdout {
            try command.run(dependencies: .fixture(
                book: AddressBook(contacts: [
                    "12125550101": "Bob Yellow",
                    "12125550100": "Alice Able",
                ], details: details)
            ))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 2)
        let samples = try #require(data["samples"] as? [[String: Any]])
        #expect(samples.first?["name"] as? String == "Alice Able")
    }

    @Test func checkAddressBookUsesInjectedDiagnostic() throws {
        let command = try CheckAddressBook.parse([])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(addressBookDiagnostic: {
                AddressBook.Diagnostic(
                    sources_dir: syntheticAddressBookDir,
                    sources_dir_exists: true,
                    database_count: 1,
                    databases: [
                        AddressBook.SourceReport(path: syntheticAddressBookDir + "/AddressBook-v22.abcddb",
                                                 readable: true, connected: true, table_count: 4,
                                                 has_zabcdrecord: true, has_zabcdphonenumber: true,
                                                 contact_count: 2),
                    ],
                    contacts_with_handles: 2
                )
            }))
        }

        let data = try payload(from: output)
        #expect(data["sources_dir"] as? String == syntheticAddressBookDir)
        #expect(data["contacts_with_handles"] as? Int == 2)
    }

    @Test func doctorUsesInjectedDiagnostics() throws {
        let command = try Doctor.parse([])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(
                dbDiagnostic: {
                    ChatDB.DBCheck(path: syntheticChatDBPath, exists: true, readable: true,
                                   connected: true, table_count: 3, has_message_table: true,
                                   has_handle_table: true, has_chat_table: true, message_count: 12)
                },
                addressBookDiagnostic: {
                    AddressBook.Diagnostic(sources_dir: syntheticAddressBookDir,
                                           sources_dir_exists: true, database_count: 0,
                                           databases: [], contacts_with_handles: 2)
                },
                accessibilityDiagnostic: { Permissions.accessibilityPreflight(trusted: true) },
                hasFullDiskAccess: { true }
            ))
        }

        let data = try payload(from: output)
        #expect(data["full_disk_access"] as? Bool == true)
        #expect(data["contacts_with_handles"] as? Int == 2)
        let accessibility = try #require(data["accessibility"] as? [String: Any])
        #expect(accessibility["trusted"] as? Bool == true)
        #expect(accessibility["identity"] as? String == "current_process")
        #expect((accessibility["notes"] as? [String]) == ["This status applies only to the current process; other launches may have different permissions."])
        #expect((data["notes"] as? [String])?.isEmpty == true)
    }

    @Test func doctorDeniedAccessibilitySucceedsAndPreservesExistingNotes() throws {
        let command = try Doctor.parse([])
        let output = try captureStdout {
            try command.run(dependencies: .fixture(
                dbDiagnostic: {
                    ChatDB.DBCheck(path: syntheticChatDBPath, exists: true, readable: true,
                                   connected: false, table_count: nil, has_message_table: false,
                                   has_handle_table: false, has_chat_table: false, message_count: nil)
                },
                addressBookDiagnostic: {
                    AddressBook.Diagnostic(sources_dir: syntheticAddressBookDir,
                                           sources_dir_exists: true, database_count: 0,
                                           databases: [], contacts_with_handles: 0)
                },
                accessibilityDiagnostic: { Permissions.accessibilityPreflight(trusted: false) },
                hasFullDiskAccess: { true }
            ))
        }

        let envelope = try successEnvelope(from: output)
        #expect(envelope["schema_version"] as? Int == 1)
        #expect(envelope["ok"] as? Bool == true)
        let data = try #require(envelope["data"] as? [String: Any])
        let accessibility = try #require(data["accessibility"] as? [String: Any])
        #expect(accessibility["trusted"] as? Bool == false)
        #expect(accessibility["identity"] as? String == "current_process")
        let accessibilityNotes = try #require(accessibility["notes"] as? [String])
        #expect(accessibilityNotes.contains("This status applies only to the current process; other launches may have different permissions."))
        #expect(accessibilityNotes.contains("Accessibility not trusted — enable Accessibility for apple or the host app shown by macOS in System Settings › Privacy & Security › Accessibility, then rerun this check."))
        let notes = try #require(data["notes"] as? [String])
        #expect(notes.contains("Messages chat.db not accessible."))
        #expect(notes.contains("Accessibility not trusted — enable Accessibility for apple or the host app shown by macOS in System Settings › Privacy & Security › Accessibility, then rerun this check."))
        #expect(notes.contains("No AddressBook contacts with phone/email found."))
    }

    @Test func textRenderersUseInjectedDependencies() throws {
        let deps = fixtureDependencies(chat)

        let recent = try captureStdout {
            let command = try Recent.parse(["--text", "--hours", "24", "--limit", "1"])
            try command.run(dependencies: deps)
        }
        #expect(recent.contains("Friend Name: hello from friend"))

        let chats = try captureStdout {
            let command = try Chats.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(chats.contains("Available group chats:"))

        let search = try captureStdout {
            let command = try Search.parse(["--text", "decoded", "--hours", "24", "--match", "contains"])
            try command.run(dependencies: deps)
        }
        #expect(search.contains("Found 1 messages matching"))

        let availability = try captureStdout {
            let command = try CheckAvailability.parse(["--text", "+1 (212) 555-0100"])
            try command.run(dependencies: deps)
        }
        #expect(availability.contains("iMessage available"))
    }

    /// The ranked-candidate `--text` renderings. These are the human half of the oracle's stateful
    /// `contact:N` replacement — the list a caller reads before re-running with an explicit
    /// handle — so a renderer that dropped the number, the handle or the score would leave the
    /// disambiguation unusable while the JSON path stayed green.
    @Test func ambiguousTextRenderersListRankedCandidates() throws {
        let path = chat.path
        let homePath = chat.homePath
        let book = AddressBook(contacts: [
            "12125550100": "Alice Example",
            "12125550101": "Alice Example",
        ])
        let deps = MessagesCommandDependencies.fixture(book: book, makeChatDB: { _ in
            try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
        }, performSend: { _ in
            Issue.record("an ambiguous recipient must not invoke sender")
            return .sent(nil)
        })

        let recent = try captureStdout {
            let command = try Recent.parse(["--text", "--contact", "Alice", "--hours", "24"])
            try command.run(dependencies: deps)
        }
        #expect(recent.contains("Multiple contacts found matching 'Alice':"))
        #expect(recent.contains("1. Alice Example (12125550100) - confidence "))

        let send = try captureStdout {
            let command = try Send_.parse(["--text", "Alice", "--message", "synthetic hello"])
            try command.run(dependencies: deps)
        }
        #expect(send.contains("Multiple contacts found matching 'Alice':"))
        #expect(send.contains("1. Alice Example (12125550100)"))
        // The send rendering deliberately omits the score the read paths show.
        #expect(!send.contains("confidence"))

        let findContact = try captureStdout {
            let command = try FindContact.parse(["--text", "Alice"])
            try command.run(dependencies: deps)
        }
        #expect(findContact.contains("Found 2 contacts matching 'Alice':"))
        #expect(findContact.contains("1. Alice Example (12125550100) - confidence "))
    }

    @Test func diagnosticTextRenderersUseInjectedDependencies() throws {
        let deps = MessagesCommandDependencies.fixture(
            dbDiagnostic: {
                ChatDB.DBCheck(path: syntheticChatDBPath, exists: true, readable: true,
                               connected: true, table_count: 3, has_message_table: true,
                               has_handle_table: true, has_chat_table: true, message_count: 12)
            },
            addressBookDiagnostic: {
                AddressBook.Diagnostic(
                    sources_dir: syntheticAddressBookDir,
                    sources_dir_exists: true,
                    database_count: 1,
                    databases: [
                        AddressBook.SourceReport(path: syntheticAddressBookDir + "/AddressBook-v22.abcddb",
                                                 readable: true, connected: true, table_count: 4,
                                                 has_zabcdrecord: true, has_zabcdphonenumber: true,
                                                 contact_count: 2),
                    ],
                    contacts_with_handles: 2
                )
            },
            accessibilityDiagnostic: { Permissions.accessibilityPreflight(trusted: false) },
            hasFullDiskAccess: { false }
        )

        let checkDB = try captureStdout {
            let command = try CheckDB.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(checkDB.contains("path: " + syntheticChatDBPath))

        let checkAddressBook = try captureStdout {
            let command = try CheckAddressBook.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(checkAddressBook.contains("contacts with handles: 2"))

        let trustedDoctor = try captureStdout {
            let command = try Doctor.parse(["--text"])
            try command.run(dependencies: .fixture(
                dbDiagnostic: {
                    ChatDB.DBCheck(path: syntheticChatDBPath, exists: true, readable: true,
                                   connected: true, table_count: 3, has_message_table: true,
                                   has_handle_table: true, has_chat_table: true, message_count: 12)
                },
                addressBookDiagnostic: {
                    AddressBook.Diagnostic(sources_dir: syntheticAddressBookDir,
                                           sources_dir_exists: true, database_count: 1,
                                           databases: [], contacts_with_handles: 2)
                },
                accessibilityDiagnostic: { Permissions.accessibilityPreflight(trusted: true) },
                hasFullDiskAccess: { true }
            ))
        }
        #expect(trustedDoctor.contains("Accessibility: trusted=true identity=current_process"))
        #expect(trustedDoctor.contains("This status applies only to the current process; other launches may have different permissions."))

        let doctor = try captureStdout {
            let command = try Doctor.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(doctor.contains("Full Disk Access: false"))
        #expect(doctor.contains("Accessibility: trusted=false identity=current_process"))
        #expect(doctor.contains("This status applies only to the current process; other launches may have different permissions."))
        #expect(doctor.contains("Full Disk Access not detected"))
        #expect(doctor.contains("Accessibility not trusted"))
        #expect(doctor.components(separatedBy: "This status applies only to the current process; other launches may have different permissions.").count == 2)
        #expect(doctor.components(separatedBy: "Accessibility not trusted").count == 2)
    }

    @Test func emptyTextRenderersUseInjectedDependencies() throws {
        let emptyPath = try emptyChatDBPath()
        let emptyHome = try scratch.directory().path
        let deps = MessagesCommandDependencies.fixture(
            book: AddressBook(),
            makeChatDB: { _ in
                try ChatDB(path: emptyPath, book: AddressBook(), copyToTemp: false,
                           homeDirectoryForTilde: emptyHome)
            },
            dbDiagnostic: {
                ChatDB.DBCheck(path: syntheticChatDBPath, exists: false, readable: false,
                               connected: false, table_count: nil, has_message_table: false,
                               has_handle_table: false, has_chat_table: false, message_count: nil)
            },
            addressBookDiagnostic: {
                AddressBook.Diagnostic(sources_dir: syntheticAddressBookDir,
                                       sources_dir_exists: false, database_count: 0,
                                       databases: [], contacts_with_handles: 0)
            }
        )

        let recent = try captureStdout {
            let command = try Recent.parse(["--text", "--hours", "24"])
            try command.run(dependencies: deps)
        }
        #expect(recent.contains("No messages found"))

        let findContact = try captureStdout {
            let command = try FindContact.parse(["--text", "Nobody"])
            try command.run(dependencies: deps)
        }
        #expect(findContact.contains("No contacts found"))

        let chats = try captureStdout {
            let command = try Chats.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(chats.contains("No named group chats"))

        let search = try captureStdout {
            let command = try Search.parse(["--text", "missing", "--hours", "24", "--match", "contains"])
            try command.run(dependencies: deps)
        }
        #expect(search.contains("No messages found matching"))

        let contacts = try captureStdout {
            let command = try CheckContacts.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(contacts.contains("No contacts found in AddressBook"))
    }

    @Test func validationErrorsEmitJSONWithoutLiveDependencies() throws {
        try expectValidationError(try Recent.parse(["--hours=-1"]), run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Recent.parse(["--limit", "0"]), run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try FindContact.parse([String(repeating: "a", count: 1025)]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Search.parse(["   "]), run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Search.parse(["term", "--threshold", "1.1"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Search.parse(["term", "--match", "bogus"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        // Upper bounds, alongside the lower bounds already pinned above. Both are resource
        // guards, and both must fail BEFORE any dependency is touched — the fail-closed fixture
        // would throw `upstream`, not `validation`, if the guard let the command through.
        try expectValidationError(try Recent.parse(["--hours", String(MessageTime.maxHours + 1)]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Search.parse(["term", "--hours", String(MessageTime.maxHours + 1)]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Search.parse([String(repeating: "a", count: 1025)]),
                                  run: { try $0.run(dependencies: .fixture()) })
        // `chats --limit` takes the same bound as `recent --limit`, and rejects it before the
        // fail-closed fixture would throw `upstream` instead.
        try expectValidationError(try Chats.parse(["--limit", "0"]),
                                  run: { try $0.run(dependencies: .fixture()) })
        try expectValidationError(try Chats.parse(["--limit", "10001"]),
                                  run: { try $0.run(dependencies: .fixture()) })
    }

    @Test("send preserves marked output-limit errors and identical unmarked errors")
    func sendOutputLimitErrorsAtCommandBoundary() throws {
        let cases: [(error: AppleError, type: String, exit: Int32, message: String)] = [
            (.outputLimitEnvironmentInvalid(), AppleErrorType.validation, AppleExit.usage,
             "APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count"),
            (.outputLimitExplicitInvalid(), AppleErrorType.validation, AppleExit.usage,
             "maximumOutputBytes must be a positive byte count"),
            (.outputLimitExceeded(maximumOutputBytes: 17), AppleErrorType.upstream, AppleExit.upstream,
             "osascript output exceeded the configured limit of 17 bytes; no partial result returned. "
             + "The operation may have completed; verify its state before retrying."),
        ]
        for item in cases {
            for marked in [true, false] {
                let injected = marked ? item.error
                    : AppleError(type: item.error.type, message: item.error.message,
                                 exitCode: item.error.exitCode)
                #expect(AppleScriptRunner.isOutputLimitError(injected) == marked)
                for group in [false, true] {
                    let handle = group ? "iMessage;+;chat-example" : "12125550100"
                    let arguments = (group ? ["--group"] : [])
                        + [handle, "--message", "synthetic output-limit send"]
                    let command = try Send_.parse(arguments)
                    let calls = LockedBox<Int>(0)
                    let result = try captureCommand {
                        try command.run(dependencies: .fixture(performSend: { request in
                            calls.withLock { $0 += 1 }
                            #expect(request.handle == handle)
                            #expect(request.message == "synthetic output-limit send")
                            #expect(request.groupChat == group)
                            throw injected
                        }))
                    }
                    #expect(calls.value == 1)
                    #expect(result.exitCode == item.exit)
                    #expect(result.stderr.isEmpty)
                    let envelope = try #require(
                        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
                    #expect(Set(envelope.keys) == Set(["schema_version", "tool", "ok", "error"]))
                    #expect(envelope["schema_version"] as? Int == 1)
                    #expect(envelope["tool"] as? String == "messages")
                    #expect(envelope["ok"] as? Bool == false)
                    let error = try #require(envelope["error"] as? [String: Any])
                    #expect(Set(error.keys) == Set(["type", "message"]))
                    #expect(error["type"] as? String == item.type)
                    #expect(error["message"] as? String == item.message)
                }
            }
        }
    }


    /// The raw `osascript` failure text is UNSTABLE and can echo store-derived content, so it goes
    /// to stderr (the human channel) only; stdout carries a fixed, parseable message. Asserting the
    /// stderr text, the EXACT stdout message, and the raw text's ABSENCE from stdout is what makes
    /// a regression that leaks it into the envelope fail here.
    @Test func sendFailureKeepsRawSenderErrorOffTheJSONEnvelope() throws {
        let rawError = "synthetic osascript failure"
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                .failed(error: rawError)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        #expect(result.stderr == "osascript: " + rawError + "\n")
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
        #expect(error["message"] as? String == "send failed (Messages returned an error).")
        #expect(!result.stdout.contains(rawError))
        #expect(!result.stdout.contains("osascript"))
    }

    /// An UNPARSEABLE sender result must not be reported as "nothing was sent": the counters
    /// were never observed, so the envelope says delivery is unknown and withholds the retry
    /// advice that the parsed-failure branches build from those counters.
    @Test func sendUnknownResultSaysDeliveryIsUnknown() throws {
        let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Send.interpret("garbled line the grammar does not know")
            }))
        }
        #expect(result.exitCode == AppleExit.upstream)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
        let message = error["message"] as? String ?? ""
        #expect(message.contains("WHAT WAS DELIVERED IS UNKNOWN"))
        #expect(message.contains("Check the conversation before retrying"))
        #expect(!message.contains("files_sent="), "no counter-derived retry advice")
        #expect(error["applied"] == nil)
        #expect((error["remediation"] as? String)?.hasPrefix("delivery unknown:") == true,
                "the machine-visible signal rides the existing remediation key")
        // The raw, unparseable sender text stays off the JSON channel, as on every failure path.
        #expect(!result.stdout.contains("garbled line"))
    }

    @Test func sendNotFoundEmitsNotFoundWithoutInvokingSender() throws {
        let command = try Send_.parse(["Unknown", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _ in
                Issue.record("not-found recipient must not invoke sender")
                return .sent(nil)
            }))
        }

        #expect(result.exitCode == AppleExit.notFound)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.notFound)
    }

    @Test func addressBookLoadIngestsSyntheticPhoneAndEmailRows() throws {
        let dbPath = try syntheticAddressBookPath()
        let missingPath = try nonexistentPath("missing-addressbook.abcddb")
        let warnings = LockedBox<[String]>([])

        let book = AddressBook.load(paths: [dbPath, missingPath]) { warning in
            warnings.withLock { $0.append(warning) }
        }

        #expect(book.nameForHandle("+1 (212) 555-0100") == "Alice Able")
        #expect(book.nameForHandle("bob@example.com") == "Bob Baker")
        #expect(book.findByName("Ally").first?.phone == "12125550100")
        #expect(warnings.value.contains { $0.contains("Cannot access") })
    }

    @Test func addressBookDiagnoseReadsSyntheticDatabaseMetadata() throws {
        let dbPath = try syntheticAddressBookPath()
        let missingPath = try nonexistentPath("missing-addressbook.abcddb")
        let loadedBook = AddressBook.load(paths: [dbPath])

        let diagnostic = AddressBook.diagnose(
            paths: [dbPath, missingPath],
            sourcesDir: syntheticAddressBookDir,
            sourcesDirExists: true,
            loadBook: { loadedBook }
        )

        #expect(diagnostic.sources_dir == syntheticAddressBookDir)
        #expect(diagnostic.sources_dir_exists == true)
        #expect(diagnostic.database_count == 2)
        #expect(diagnostic.contacts_with_handles == 2)
        #expect(diagnostic.databases[0].readable == true)
        #expect(diagnostic.databases[0].connected == true)
        #expect(diagnostic.databases[0].has_zabcdrecord == true)
        #expect(diagnostic.databases[0].has_zabcdphonenumber == true)
        #expect(diagnostic.databases[0].contact_count == 2)
        #expect(diagnostic.databases[1].readable == false)
        #expect(diagnostic.databases[1].connected == false)
    }

    @Test func chatDBDiagnoseReadsSyntheticDatabaseMetadata() throws {
        let diagnostic = ChatDB.diagnose(path: chat.path)

        #expect(diagnostic.exists == true)
        #expect(diagnostic.readable == true)
        #expect(diagnostic.connected == true)
        #expect(diagnostic.has_message_table == true)
        #expect(diagnostic.has_handle_table == true)
        #expect(diagnostic.has_chat_table == true)
        #expect(diagnostic.message_count == 11)
    }

    @Test func chatDBDiagnoseReportsMissingDatabase() throws {
        let diagnostic = ChatDB.diagnose(path: try nonexistentPath("missing-chat.db"))

        #expect(diagnostic.exists == false)
        #expect(diagnostic.readable == false)
        #expect(diagnostic.connected == false)
        #expect(diagnostic.table_count == nil)
        #expect(diagnostic.message_count == nil)
    }

    @Test func attributedBodyDecodesThreeAndFourByteLengths() {
        let threeByteBody = String(repeating: "x", count: 70_000)
        #expect(AttributedBody.decode(syntheticAttributedBody(threeByteBody, marker: 0x82)) == threeByteBody)

        let fourByteBody = String(repeating: "y", count: 70_000)
        #expect(AttributedBody.decode(syntheticAttributedBody(fourByteBody, marker: 0x83)) == fourByteBody)
    }

    @Test func attributedBodyRejectsUnsupportedLengthMarkerAndMissingPattern() {
        var unsupported = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, 0x84]
        unsupported.append(contentsOf: Array("body".utf8))
        #expect(AttributedBody.decode(bytes: unsupported) == nil)
        #expect(AttributedBody.decode(bytes: Array("short".utf8)) == nil)
    }

    @Test func topLevelMessagesCommandEmitsSubcommandValidationError() throws {
        let result = try captureCommand {
            try MessagesCommand().run()
        }

        #expect(result.exitCode == AppleExit.usage)
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.validation)
    }

    @Test func defaultFixtureClosuresFailClosed() throws {
        let recent = try captureCommand {
            let command = try Recent.parse([])
            try command.run(dependencies: .fixture())
        }
        #expect(recent.exitCode == AppleExit.upstream)

        let send = try captureCommand {
            let command = try Send_.parse(["+1 (212) 555-0100", "--message", "synthetic hello"])
            try command.run(dependencies: .fixture())
        }
        #expect(send.exitCode == AppleExit.upstream)

        let checkDB = try captureStdout {
            let command = try CheckDB.parse([])
            try command.run(dependencies: .fixture())
        }
        let dbData = try payload(from: checkDB)
        #expect(dbData["path"] as? String == syntheticChatDBPath)

        let checkAddressBook = try captureStdout {
            let command = try CheckAddressBook.parse([])
            try command.run(dependencies: .fixture())
        }
        let abData = try payload(from: checkAddressBook)
        #expect(abData["sources_dir"] as? String == syntheticAddressBookDir)
    }

    @Test func defaultPathsAndUnknownSendResultStayDeterministic() {
        #expect(ChatDB.defaultPath().hasSuffix("/Library/Messages/chat.db"))
        let result = Send.interpret("unexpected")
        #expect(result.ok == false)
        #expect(result.error == "Unknown result: unexpected")
    }

    // MARK: - Fixture helpers

    /// A guaranteed-unique path that does NOT exist, inside a directory this suite instance owns.
    /// A predictable name in the SHARED temp root (a `missing-*.db` under it) is not safe here:
    /// another process could create a file or a symlink at that name between runs, and the code
    /// under test would then open whatever it pointed at — including a real Apple database.
    private func nonexistentPath(_ name: String) throws -> String {
        let path = try scratch.directory().appendingPathComponent(name).path
        #expect(!FileManager.default.fileExists(atPath: path))
        return path
    }

    private func emptyChatDBPath() throws -> String {
        let root = try scratch.directory()
        let dbPath = root.appendingPathComponent("empty-chat.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw SQLiteFixtureError.open }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT, style INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                is_from_me INTEGER, handle_id INTEGER, cache_roomnames TEXT, service TEXT,
                cache_has_attachments INTEGER, date INTEGER, error INTEGER);
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT,
                mime_type TEXT, uti TEXT, transfer_name TEXT, total_bytes INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            """, nil, nil, nil)
        return dbPath
    }

    /// A chat.db whose only handle is an EMAIL address. Purpose-built rather than added to the
    /// shared `ChatFixture`, whose rowid expectations several other tests pin exactly.
    private func emailHandleChatDBPath() throws -> String {
        let root = try scratch.directory()
        let dbPath = root.appendingPathComponent("email-handle-chat.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw SQLiteFixtureError.open }
        defer { sqlite3_close(db) }
        // Recent enough that a `--hours 24` window always includes it, regardless of run time.
        let date = Int64((Date().timeIntervalSince1970 - 3600 - MessageTime.appleUnixOffset) * 1_000_000_000)
        sqlite3_exec(db, """
            CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                room_name TEXT, guid TEXT, service_name TEXT, group_id TEXT, style INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE message(ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
                is_from_me INTEGER, handle_id INTEGER, cache_roomnames TEXT, service TEXT,
                cache_has_attachments INTEGER, date INTEGER, error INTEGER);
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT,
                mime_type TEXT, uti TEXT, transfer_name TEXT, total_bytes INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            INSERT INTO handle VALUES (7, 'carol@example.com', 'iMessage');
            INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error)
                VALUES (70,'e70','synthetic email-handle message',0,7,'iMessage',\(date),0);
            """, nil, nil, nil)
        return dbPath
    }

    private func syntheticAddressBookPath() throws -> String {
        let root = try scratch.directory()
        let dbPath = root.appendingPathComponent("AddressBook-v22.abcddb").path
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw SQLiteFixtureError.open }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE ZABCDRECORD(Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZNICKNAME TEXT);
            CREATE TABLE ZABCDPHONENUMBER(ZOWNER INTEGER, ZFULLNUMBER TEXT, ZORDERINGINDEX INTEGER);
            CREATE TABLE ZABCDEMAILADDRESS(ZOWNER INTEGER, ZADDRESS TEXT);
            INSERT INTO ZABCDRECORD VALUES
                (1, 'Alice', 'Able', 'Ally'),
                (2, 'Bob', 'Baker', '');
            INSERT INTO ZABCDPHONENUMBER VALUES (1, '+1 (212) 555-0100;X-IMAGETYPE=0', 0);
            INSERT INTO ZABCDEMAILADDRESS VALUES (2, 'bob@example.com');
            """, nil, nil, nil)
        return dbPath
    }

    private func syntheticAttributedBody(_ body: String, marker: UInt8) -> Data {
        let bodyBytes = Array(body.utf8)
        var out = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, marker]
        switch marker {
        case 0x82:
            out.append(UInt8(bodyBytes.count & 0xff))
            out.append(UInt8((bodyBytes.count >> 8) & 0xff))
            out.append(UInt8((bodyBytes.count >> 16) & 0xff))
        case 0x83:
            out.append(UInt8(bodyBytes.count & 0xff))
            out.append(UInt8((bodyBytes.count >> 8) & 0xff))
            out.append(UInt8((bodyBytes.count >> 16) & 0xff))
            out.append(UInt8((bodyBytes.count >> 24) & 0xff))
        default:
            out.append(UInt8(bodyBytes.count))
        }
        out.append(contentsOf: bodyBytes)
        return Data(out)
    }
}

private func captureStdout(_ body: () throws -> Void) throws -> String {
    try captureCommand(body).stdout
}

private func captureCommand(_ body: () throws -> Void) throws -> (stdout: String, stderr: String, exitCode: Int32?) {
    let stdout = MemoryOutputSink()
    let stderr = MemoryOutputSink()
    var exitCode: Int32?
    do {
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr), operation: body)
    } catch let code as ExitCode {
        exitCode = code.rawValue
    }
    return (
        String(decoding: stdout.data, as: UTF8.self),
        String(decoding: stderr.data, as: UTF8.self),
        exitCode
    )
}

private func successEnvelope(from output: String) throws -> [String: Any] {
    let data = Data(output.utf8)
    let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(envelope["ok"] as? Bool == true)
    return envelope
}

private func payload(from output: String) throws -> [String: Any] {
    try #require(try successEnvelope(from: output)["data"] as? [String: Any])
}

private func cursorJSON(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
}

private func errorPayload(from output: String) throws -> [String: Any] {
    let data = Data(output.utf8)
    let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(envelope["ok"] as? Bool == false)
    return try #require(envelope["error"] as? [String: Any])
}

private func expectValidationError<T>(_ command: T, run: (T) throws -> Void) throws {
    let result = try captureCommand { try run(command) }
    #expect(result.exitCode == AppleExit.usage)
    let error = try errorPayload(from: result.stdout)
    #expect(error["type"] as? String == AppleErrorType.validation)
}

private func fixtureDependencies(_ fx: ChatFixture) -> MessagesCommandDependencies {
    let path = fx.path
    let homePath = fx.homePath
    let book = AddressBook(contacts: ["12125550100": "Friend Name"])
    return .fixture(book: book, makeChatDB: { _ in
        try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
    })
}

private func reactionDependencies(
    _ fx: ChatFixture,
    allowedRecipients: [String] = ["+12125550100"],
    accessibilityTrusted: Bool = true,
    launchObservedWorker: @escaping @Sendable (WorkerObservedAction) throws -> WorkerObservedOutcome = { _ in
        throw AppleError.upstream("test worker dependency not configured")
    }
) -> MessagesCommandDependencies {
    let path = fx.path
    let homePath = fx.homePath
    let book = AddressBook(contacts: ["12125550100": "Friend Name"])
    return .fixture(book: book, makeChatDB: { _ in
        try ChatDB(path: path, book: book, copyToTemp: false, homeDirectoryForTilde: homePath)
    }, accessibilityDiagnostic: { Permissions.accessibilityPreflight(trusted: accessibilityTrusted) },
       messagesAutomationStateRoot: { homePath + "/messages-automation" },
       launchObservedWorker: launchObservedWorker,
       allowedRecipients: allowedRecipients)
}

private func insertReactionRow(path: String, rowid: Int64, guid: String, associatedGUID: String,
                               type: Int, date: Int64, chatRowid: Int64 = 3, emoji: String? = nil) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw SQLiteFixtureError.open }
    defer { sqlite3_close(db) }
    let emojiSQL = emoji.map { "'\($0)'" } ?? "NULL"
    let sql = """
        INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error,
            associated_message_guid,associated_message_type,associated_message_emoji)
        VALUES (\(rowid),'\(guid)',NULL,1,1,'iMessage',\(date),0,
            '\(associatedGUID)',\(type),\(emojiSQL));
        INSERT INTO chat_message_join VALUES (\(chatRowid),\(rowid));
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureError.exec }
}

private func updateMessageGUID(path: String, rowid: Int64, guid: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw SQLiteFixtureError.open }
    defer { sqlite3_close(db) }
    let sql = "UPDATE message SET guid='\(guid)' WHERE ROWID=\(rowid);"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureError.exec }
}

private func readReactionJournalSnapshot(root: String) throws -> AppleAutomationJournal.Snapshot {
    try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
        try lease.loadSnapshot()
    }
}

private func pendingReactionRequest() throws -> AppleAutomationJournal.OperationRequest {
    try AppleAutomationJournal.OperationRequest(
        operationType: .reactionSet,
        conversationDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "chat:test"),
        messageDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "message:test"),
        partDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "part:2"),
        minimumEvidence: .init(targetHash: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "target:test"),
                               targetLength: "target:test".utf8.count)
    )
}

private func seedPreparedPendingReaction(root: String, operationID: UUID) throws {
    let request = try pendingReactionRequest()
    try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
        try lease.beginForTesting(operationID, request: request)
    }
}

private func seedUncertainPendingReaction(root: String, operationID: UUID) throws {
    try seedPreparedPendingReaction(root: root, operationID: operationID)
    try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
        try lease.markUncertainAfterHandoff(operationID: operationID)
    }
}

private func insertBareMessage(path: String, rowid: Int64, guid: String, date: Int64,
                               chatRowid: Int64 = 3) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw SQLiteFixtureError.open }
    defer { sqlite3_close(db) }
    let sql = """
        INSERT INTO message (ROWID,guid,text,is_from_me,handle_id,service,date,error)
        VALUES (\(rowid),'\(guid)','apple-cli-test duplicate',0,1,'iMessage',\(date),0);
        INSERT INTO chat_message_join VALUES (\(chatRowid),\(rowid));
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureError.exec }
}

private struct ReactionTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        lock.withLock { storage }
    }

    func withLock(_ body: (inout T) -> Void) {
        lock.withLock { body(&storage) }
    }
}

private enum SQLiteFixtureError: Error {
    case open
    case exec
}
