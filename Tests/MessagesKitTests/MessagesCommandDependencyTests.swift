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
        makeChatDB: @escaping @Sendable (AddressBook) throws -> ChatDB = { _ in
            throw AppleError.upstream("test ChatDB dependency not configured")
        },
        performSend: @escaping @Sendable (String, String, Bool) throws -> (ok: Bool, service: String?, error: String?) = { _, _, _ in
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
        hasFullDiskAccess: @escaping @Sendable () -> Bool = { false },
        allowedRecipients: [String] = []
    ) -> MessagesCommandDependencies {
        MessagesCommandDependencies(
            loadAddressBook: { book },
            makeChatDB: makeChatDB,
            performSend: performSend,
            dbDiagnostic: dbDiagnostic,
            addressBookDiagnostic: addressBookDiagnostic,
            hasFullDiskAccess: hasFullDiskAccess,
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

/// Placeholder path STRINGS for diagnostic payloads. They are never opened — they only have to be
/// recognizable in an envelope — so they are deliberately relative and carry no absolute
/// filesystem prefix. Tests that need a real path on disk take one from `ScratchDirs`.
private let syntheticChatDBPath = "synthetic/chat.db"
private let syntheticAddressBookDir = "synthetic/AddressBook"

@Suite("Messages command dependency injection")
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

    /// MCP-PARITY BRANCH (`get_recent_messages`). A single fuzzy `--contact` match resolves
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                Issue.record("dry-run must not invoke sender")
                return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { handle, message, group in
                #expect(handle == "12125550100")
                #expect(message == "synthetic hello")
                #expect(group == false)
                return (true, "iMessage", nil)
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
            try command.run(dependencies: .fixture(performSend: { handle, message, group in
                #expect(handle == "iMessage;+;chat-example")
                #expect(message == "synthetic group hello")
                #expect(group == true)
                return (true, nil, nil)
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
                performSend: { _, _, _ in
                    Issue.record("ambiguous contact must not invoke sender")
                    return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                Issue.record("a sandbox-refused recipient must not invoke sender")
                return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                Issue.record("sandboxed group send must not invoke sender")
                return (true, nil, nil)
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
                try command.run(dependencies: .fixture(performSend: { _, _, _ in
                    Issue.record("a sandboxed group send must not invoke sender")
                    return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { handle, _, isGroup in
                #expect(handle == chatId)
                #expect(isGroup == true)
                return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { handle, _, _ in
                #expect(handle == "12125550100")
                return (true, "iMessage", nil)
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                Issue.record("dry-run must not invoke sender")
                return (true, nil, nil)
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in (true, "iMessage", nil) },
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in (true, "iMessage", nil) }))
        }
        #expect(unsandboxed.hasPrefix("Message sent successfully"))
    }

    // MARK: - Reads + diagnostics

    @Test func chatsUsesInjectedChatDB() throws {
        let command = try Chats.parse([])
        let output = try captureStdout {
            try command.run(dependencies: fixtureDependencies(chat))
        }

        let data = try payload(from: output)
        #expect(data["count"] as? Int == 1)
        let chats = try #require(data["chats"] as? [[String: Any]])
        #expect(chats.first?["display_name"] as? String == "Test Group")
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
                hasFullDiskAccess: { true }
            ))
        }

        let data = try payload(from: output)
        #expect(data["full_disk_access"] as? Bool == true)
        #expect(data["contacts_with_handles"] as? Int == 2)
        #expect((data["notes"] as? [String])?.isEmpty == true)
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

    /// The ranked-candidate `--text` renderings. These are the human half of the MCP's stateful
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
        }, performSend: { _, _, _ in
            Issue.record("an ambiguous recipient must not invoke sender")
            return (true, nil, nil)
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

        let doctor = try captureStdout {
            let command = try Doctor.parse(["--text"])
            try command.run(dependencies: deps)
        }
        #expect(doctor.contains("Full Disk Access: false"))
        #expect(doctor.contains("Full Disk Access not detected"))
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
                        try command.run(dependencies: .fixture(performSend: { recipient, message, isGroup in
                            calls.withLock { $0 += 1 }
                            #expect(recipient == handle)
                            #expect(message == "synthetic output-limit send")
                            #expect(isGroup == group)
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
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                (false, nil, rawError)
            }))
        }

        #expect(result.exitCode == AppleExit.upstream)
        #expect(result.stderr == "osascript: " + rawError + "\n")
        let error = try errorPayload(from: result.stdout)
        #expect(error["type"] as? String == AppleErrorType.upstream)
        #expect(error["message"] as? String == "send failed (Messages returned an error)")
        #expect(!result.stdout.contains(rawError))
        #expect(!result.stdout.contains("osascript"))
    }

    @Test func sendNotFoundEmitsNotFoundWithoutInvokingSender() throws {
        let command = try Send_.parse(["Unknown", "--message", "synthetic hello"])
        let result = try captureCommand {
            try command.run(dependencies: .fixture(performSend: { _, _, _ in
                Issue.record("not-found recipient must not invoke sender")
                return (true, nil, nil)
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
}
