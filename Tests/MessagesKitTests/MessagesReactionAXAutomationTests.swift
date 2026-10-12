import Foundation
import ApplicationServices
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite("Messages reaction AX automation")
struct MessagesReactionAXAutomationTests {
    private func request(_ operation: MessagesReactionWorkerPayload.Operation = .set,
                         _ reaction: MessagesReaction = .standard(.heart),
                         experimentalUIHandoff: Bool = false) throws -> MessagesReactionRequest {
        try MessagesReactionRequest(operation: operation, chatGUID: "chat-guid", messageGUID: "message-guid",
                                    nativePartIndex: 2, nativePartGUID: "p:2/message-guid", reaction: reaction,
                                    experimentalUIHandoff: experimentalUIHandoff)
    }

    private func apply(_ driver: FakeReactionDriver, _ operation: MessagesReactionWorkerPayload.Operation = .set,
                       _ reaction: MessagesReaction = .standard(.heart),
                       experimentalUIHandoff: Bool = false) throws -> MessagesReactionAXOutcome {
        let request = try MessagesReactionRequest(operation: operation, chatGUID: "chat-guid", messageGUID: "message-guid",
                                                  nativePartIndex: 2, nativePartGUID: "p:2/message-guid",
                                                  reaction: reaction,
                                                  experimentalUIHandoff: experimentalUIHandoff)
        return try MessagesReactionAXAutomation(driver: driver).apply(request, deadline: .millisecondsFromNow(2_000))
    }

    private func workerRequest(command: WorkerCommand) -> WorkerRequest {
        let identity = WorkerProcessIdentity(pid: 1, parentPID: 0, uid: 1, gid: 1,
                                             startTimeMicroseconds: 1, executableDevice: 1,
                                             executableInode: 1, executablePath: "/tmp/apple")
        let executable = WorkerExecutableIdentity(uid: 1, gid: 1, device: 1, inode: 1,
                                                  path: "/tmp/apple")
        return WorkerRequest(schemaVersion: 1, operationID: UUID(), nonce: UUID(),
                             deadline: .millisecondsFromNow(2_000), parent: identity,
                             workerExecutable: executable, command: command)
    }

    @Test func actualNativePartURL() throws {
        let url = try NativeMessagesURL.message(messageGUID: "message-guid", nativePartIndex: 2,
                                                nativePartGUID: "p:2/message-guid")
        #expect(url.absoluteString == "imessage:open?message-guid=p:2/message-guid")
        #expect(try NativeMessagesURL.message(messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: nil) == url)
        let driver = FakeReactionDriver()
        _ = try apply(driver)
        #expect(driver.openedURLs == [url])
    }

    @Test func malformedTargetsNeverHaveGenericURLFallback() {
        for (guid, index, part) in [("", 0, nil), ("message-guid", -1, nil),
                                    ("message-guid", Int(Int32.max) + 1, nil),
                                    ("message-guid", 2, "p:1/message-guid"),
                                    ("message-guid", 2, "p:2/other-guid"),
                                    ("message-guid", 2, "attachment-guid"),
                                    ("p:2/message-guid", 2, nil), ("message_guid", 2, nil),
                                    (String(repeating: "a", count: 513), 0, nil)] as [(String, Int, String?)] {
            #expect(throws: (any Error).self) {
                try NativeMessagesURL.message(messageGUID: guid, nativePartIndex: index, nativePartGUID: part)
            }
        }
    }

    @Test func workerRegistryDecodesValidatedPayloads() throws {
        let registry = MessagesReactionWorkerRegistry(driver: FakeReactionDriver())
        for operation in [MessagesReactionWorkerPayload.Operation.set, .remove] {
            let payload = try MessagesReactionWorkerPayload(operation: operation, chatGUID: "chat-guid",
                messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: "p:2/message-guid", reaction: .custom("👩🏽‍💻"))
            let data = try payload.workerPayloadData()
            #expect(try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: data) == payload)
            #expect(registry.operation(for: try WorkerCommand(name: "messages.reaction.\(operation.rawValue)", payload: data)) != nil)
            #expect(registry.operation(for: try WorkerCommand(name: "messages.reaction.replace", payload: data)) == nil)
        }
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reaction.set")) == nil)
    }

    @Test func workerPayloadBindsExperimentalHandoffModeAndDefaultsMissingFalse() throws {
        let strictJSON = Data(#"{"chat_guid":"chat-guid","message_guid":"message-guid","native_part_index":2,"native_part_guid":"p:2/message-guid","operation":"set","reaction":{"standard":"heart"}}"#.utf8)
        let strict = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: strictJSON)
        #expect(strict.experimentalUIHandoff == false)
        #expect(try strict.request().experimentalUIHandoff == false)

        let experimental = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-guid",
            messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: "p:2/message-guid",
            reaction: .standard(.heart), experimentalUIHandoff: true)
        #expect(experimental.experimentalUIHandoff == true)
        #expect(try experimental.request().experimentalUIHandoff == true)
        let encoded = try JSONSerialization.jsonObject(with: experimental.workerPayloadData()) as? [String: Any]
        #expect(encoded?["experimental_ui_handoff"] as? Bool == true)

        let invalid = Data(#"{"chat_guid":"chat-guid","message_guid":"message-guid","native_part_index":2,"native_part_guid":"p:2/message-guid","operation":"set","reaction":{"standard":"heart"},"experimental_ui_handoff":"true"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: invalid)
        }
    }

    @Test func workerOperationPreservesSafeRefusedAndFailedReasons() throws {
        let refusedDriver = FakeReactionDriver()
        refusedDriver.message.actionNames = []
        let failedDriver = FakeReactionDriver()
        failedDriver.button.onAction = { _ in throw MessagesReactionAXError.axFailure }

        for (driver, expected) in [
            (refusedDriver, WorkerOperationResult.refused("target-drift")),
            (failedDriver, WorkerOperationResult.failed("ax-failure-press")),
        ] {
            let payload = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-guid",
                messageGUID: "message-guid", nativePartIndex: 2,
                nativePartGUID: "p:2/message-guid", reaction: .standard(.heart))
            let command = try WorkerCommand(name: "messages.reaction.set", payload: payload.workerPayloadData())
            let operation = try #require(MessagesReactionWorkerRegistry(driver: driver).operation(for: command))

            let result = try operation.run(workerRequest(command: command), deadline: .millisecondsFromNow(2_000))

            #expect(result == expected)
        }
    }

    @Test func workerOperationPreservesSafeStagedAXFailureReasons() throws {
        let failedDriver = FakeReactionDriver()
        failedDriver.button.onAction = { _ in throw MessagesReactionAXError.axFailure }
        let payload = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-guid",
            messageGUID: "message-guid", nativePartIndex: 2,
            nativePartGUID: "p:2/message-guid", reaction: .standard(.heart))
        let command = try WorkerCommand(name: "messages.reaction.set", payload: payload.workerPayloadData())
        let operation = try #require(MessagesReactionWorkerRegistry(driver: failedDriver).operation(for: command))

        let result = try operation.run(workerRequest(command: command), deadline: .millisecondsFromNow(2_000))

        #expect(result == WorkerOperationResult.failed("ax-failure-press"))
    }

    @Test(arguments: [
        ("preflight", "ax-failure-preflight"),
        ("open", "ax-failure-open"),
        ("initial-route", "ax-failure-initial-route"),
        ("menu-open", "ax-failure-menu-open"),
        ("picker-readiness", "ax-failure-picker-readiness"),
        ("pre-press", "ax-failure-pre-press"),
        ("press", "ax-failure-press"),
        ("post-press", "ax-failure-post-press"),
        ("cleanup", "ax-failure-cleanup"),
        ("verification", "ax-failure-verification"),
    ])
    func genericAXFailuresReportTheCurrentStage(_ injectedStage: String, _ expectedDetail: String) throws {
        let driver = FakeReactionDriver()
        switch injectedStage {
        case "preflight":
            driver.actionTitlesError = .axFailure
        case "open":
            driver.openError = .axFailure
        case "initial-route":
            driver.transcript.readError = .axFailure
        case "menu-open":
            driver.message.onAction = { _ in throw MessagesReactionAXError.axFailure }
        case "picker-readiness":
            driver.picker.linkError = .axFailure
        case "pre-press":
            driver.onProcessRead = { count in
                if count == 3 { driver.root.readError = .axFailure }
            }
        case "press":
            driver.button.onAction = { _ in throw MessagesReactionAXError.axFailure }
        case "post-press":
            driver.button.onAction = { _ in
                driver.button.isSelected = true
                driver.root.readError = .axFailure
            }
        case "cleanup":
            driver.button.isSelected = true
            driver.picker.onAction = { _ in throw MessagesReactionAXError.axFailure }
        case "verification":
            driver.button.onAction = { _ in
                driver.button.isSelected = true
                driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
            }
            var postPressProcessReads = 0
            driver.onProcessRead = { _ in
                guard driver.button.performed == ["AXPress"] else { return }
                postPressProcessReads += 1
                if postPressProcessReads >= 3 { driver.transcript.readError = .axFailure }
            }
        default:
            Issue.record("unhandled injected stage")
        }

        let outcome = try apply(driver, experimentalUIHandoff: true)
        #expect(outcome == .failed(expectedDetail))
    }

    @Test func decodingCannotBypassInitializerValidation() throws {
        let base: [String: Any] = ["operation": "set", "chat_guid": "chat-guid", "message_guid": "message-guid",
                                  "native_part_index": 2, "native_part_guid": "p:2/message-guid",
                                  "reaction": ["standard": "heart"]]
        let mutations: [(String, Any)] = [
            ("chat_guid", ""), ("chat_guid", String(repeating: "a", count: 513)), ("chat_guid", "chat\n"),
            ("message_guid", ""), ("message_guid", String(repeating: "a", count: 513)),
            ("native_part_index", -1), ("native_part_index", Int(Int32.max) + 1),
            ("native_part_guid", "p:3/message-guid"), ("native_part_guid", "p:2/other-guid"),
            ("reaction", ["standard": "heart", "custom": "🙂"]),
            ("reaction", ["standard": NSNull(), "custom": "🙂"]),
            ("reaction", ["custom": "a"]), ("reaction", ["custom": "🙂🙂"]),
            ("reaction", ["custom": String(repeating: "👩\u{200D}", count: 50) + "💻"]),
        ]
        let registry = MessagesReactionWorkerRegistry(driver: FakeReactionDriver())
        for (key, value) in mutations {
            var object = base
            object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: data) }
            #expect(registry.operation(for: try WorkerCommand(name: "messages.reaction.set", payload: data)) == nil)
        }
        let valid = try JSONSerialization.data(withJSONObject: base)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reaction.remove", payload: valid)) == nil)
    }

    @Test(arguments: ["🙂", "👍🏽", "👩🏽‍💻", "❤️", "❤", "❤︎", "🇬🇧", "1️⃣", "#️⃣", "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"])
    func emojiPayloadRoundTripsOriginalUTF8(_ emoji: String) throws {
        let reaction = MessagesReaction.custom(emoji)
        let encoded = try JSONEncoder().encode(reaction)
        let decoded = try JSONDecoder().decode(MessagesReaction.self, from: encoded)
        #expect(decoded.pickerIdentifier.utf8.elementsEqual(emoji.utf8))
    }

    @Test(arguments: ["", "a", "1", "#", "ab", "🙂🙂", "🙂\u{301}", "🇬", "🏽", "🙂🏽", "\n", "👩\u{200D}"])
    func invalidCustomGraphemesRefused(_ value: String) {
        #expect(throws: (any Error).self) { try request(.set, .custom(value)) }
    }

    @Test func deniedAccessibilityDoesNotOpenOrPrompt() throws {
        let driver = FakeReactionDriver()
        driver.trusted = false
        #expect(try apply(driver) == .refused("accessibility-denied"))
        #expect(driver.openedURLs.isEmpty)
        #expect(!driver.prompted)
    }

    @Test func localizedTitleUsesExactBoundary() throws {
        let driver = FakeReactionDriver()
        driver.actionTitles = ["Réagir"]
        driver.message.actionNames = ["Name:Réagir\nTarget:0x0\nSelector:(null)"]
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed == driver.message.actionNames)
        #expect(MessagesReactionAXAutomation.matchesAction("Name:Tapback", title: "Tapback"))
        #expect(MessagesReactionAXAutomation.matchesAction("Name:Tapback\nTarget:0x0", title: "Tapback"))
        #expect(!MessagesReactionAXAutomation.matchesAction("Name:TapbackExtra", title: "Tapback"))
        #expect(!MessagesReactionAXAutomation.matchesAction("Name:Tapback something", title: "Tapback"))
        #expect(!MessagesReactionAXAutomation.matchesAction("Name:React", title: "Tapback"))
    }

    @Test func fullLocalizedTitleActionIsAcceptedBeforeMetadata() throws {
        let driver = FakeReactionDriver()
        driver.message.actionNames = ["Name:Tapback Details\u{2026}\nTarget:0x0\nSelector:(null)"]
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed == driver.message.actionNames)
    }

    @Test func baseOnlyResolverStillMissesFullLocalizedTitleAction() throws {
        let driver = FakeReactionDriver()
        driver.actionTitles = ["Tapback"]
        driver.message.actionNames = ["Name:Tapback Details\u{2026}\nTarget:0x0\nSelector:(null)"]
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func malformedFullTitleSuffixIsRejected() throws {
        let driver = FakeReactionDriver()
        driver.message.actionNames = ["Name:Tapback Details\u{2026} extra\nTarget:0x0\nSelector:(null)"]
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func duplicateMatchingActionsAreAmbiguous() throws {
        let driver = FakeReactionDriver()
        driver.message.actionNames = [
            "Name:Tapback Details\u{2026}\nTarget:0x0\nSelector:(null)",
            "Name:Tapback\nTarget:0x0\nSelector:(null)"
        ]
        #expect(try apply(driver) == .refused("unknown-ax-value"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func duplicateResolvedTitlesAreDeduplicatedBeforeMatching() throws {
        let driver = FakeReactionDriver()
        driver.actionTitles = ["Tapback", "Tapback"]
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed == driver.message.actionNames)
    }

    @Test func missingFullTitleFallsBackToBaseTitle() throws {
        let titles = try MessagesReactionActionTitleResolver(
            baseTitle: { _ in "Tapback" },
            fullTitle: { _ in nil }
        ).resolve(deadline: .millisecondsFromNow(1_000))
        #expect(titles == ["Tapback"])
    }

    @Test func noResolvedActionTitlesRefusesBeforeOpeningMessages() throws {
        let driver = FakeReactionDriver()
        driver.actionTitles = []
        #expect(try apply(driver) == .refused("unknown-ax-value"))
        #expect(driver.openedURLs.isEmpty)
    }

    @Test(arguments: ["Tapback\n", "Tapback\r", ""])
    func malformedResolvedActionTitleRefusesBeforeOpeningMessages(_ title: String) throws {
        let driver = FakeReactionDriver()
        driver.actionTitles = [title]
        #expect(try apply(driver) == .refused("unknown-ax-value"))
        #expect(driver.openedURLs.isEmpty)
    }

    @Test func arbitraryReactPrefixIsNotAccepted() throws {
        let driver = FakeReactionDriver()
        driver.message.actionNames = ["Name:TapbackExtra", "Name:React"]
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func duplicateCanonicalAppsRefused() throws {
        let identity = FakeReactionDriver.identity
        #expect(try LiveMessagesReactionAXDriver.uniqueIdentity([identity]) == identity)
        #expect(throws: (any Error).self) { try LiveMessagesReactionAXDriver.uniqueIdentity([identity, identity]) }
        #expect(throws: (any Error).self) { try LiveMessagesReactionAXDriver.uniqueIdentity([]) }
        let wrongBundle = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/tmp/Messages.app"), launchDate: identity.launchDate)
        #expect(throws: (any Error).self) { try LiveMessagesReactionAXDriver.uniqueIdentity([wrongBundle]) }
    }

    @Test(arguments: ["process", "pid", "bundle", "launch", "window", "transcript", "message"])
    func identicalPropertiesDoNotAllowIdentityReplacementBeforeAction(_ level: String) throws {
        let driver = FakeReactionDriver()
        driver.onProcessRead = { count in
            guard count == 2 else { return }
            driver.replace(level)
        }
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.isEmpty)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["process", "pid", "bundle", "launch", "window", "transcript", "message", "picker", "button"])
    func identityReplacementBeforePressRefuses(_ level: String) throws {
        let driver = FakeReactionDriver()
        driver.onProcessRead = { count in
            guard count == 4 else { return }
            driver.replace(level)
        }
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.button.performed.isEmpty)
    }

    @Test func duplicateSelectedMessagesRefused() throws {
        let driver = FakeReactionDriver()
        driver.transcript.nodes.append(driver.message.clone())
        #expect(try apply(driver) == .refused("ambiguous-selected-message"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func duplicateTranscriptRefused() throws {
        let driver = FakeReactionDriver()
        driver.window.nodes.append(driver.transcript.clone())
        #expect(try apply(driver) == .refused("target-drift"))
    }

    @Test(arguments: ["message", "button", "unselected-message"])
    func unknownSelectedIsNeverFalse(_ kind: String) throws {
        let driver = FakeReactionDriver()
        if kind == "message" { driver.message.isSelected = nil }
        if kind == "button" { driver.button.isSelected = nil }
        if kind == "unselected-message" {
            let other = driver.message.clone()
            other.isSelected = nil
            driver.transcript.nodes.append(other)
        }
        #expect(try apply(driver, .remove) == .refused("unknown-ax-value"))
        #expect(driver.button.performed.isEmpty)
    }

    @Test func onlyRealAXBooleansProveSelection() throws {
        #expect(try LiveAXElement.checkedBoolean(kCFBooleanTrue) == true)
        #expect(try LiveAXElement.checkedBoolean(kCFBooleanFalse) == false)
        #expect(try LiveAXElement.checkedBoolean(nil) == nil)
        for value in [NSNumber(value: 0), NSNumber(value: 1), "false" as NSString, "true" as NSString] {
            #expect(throws: (any Error).self) { try LiveAXElement.checkedBoolean(value) }
        }
    }

    @Test func absentRelationshipsAreEmptyButTransportErrorsFail() throws {
        try LiveAXElement.validateChildCount(status: .success, count: 0, limit: 256)
        for status in [AXError.attributeUnsupported, .noValue] {
            try LiveAXElement.validateChildCount(status: status, count: 0, limit: 256)
        }
        for status in [AXError.cannotComplete, .invalidUIElement, .notImplemented] {
            #expect(throws: (any Error).self) { try LiveAXElement.validateChildCount(status: status, count: 0, limit: 256) }
        }
        #expect(throws: (any Error).self) { try LiveAXElement.validateChildCount(status: .success, count: 257, limit: 256) }
        #expect(throws: (any Error).self) { try LiveAXElement.validateChildCount(status: .success, count: -1, limit: 256) }
    }

    @Test func attributeErrorsFailClosed() throws {
        let driver = FakeReactionDriver()
        driver.transcript.readError = .axFailure
        #expect(try apply(driver) == .failed("ax-failure-initial-route"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func deadlineExpiresInsideTraversal() throws {
        let driver = FakeReactionDriver()
        let deadline = WorkerDeadline.millisecondsFromNow(1_000)
        var traversed = false
        driver.transcript.onChildren = {
            traversed = true
            Thread.sleep(forTimeInterval: Double(deadline.remainingNanoseconds) / 1_000_000_000 + 0.005)
        }
        let result = try MessagesReactionAXAutomation(driver: driver).apply(request(), deadline: deadline)
        #expect(traversed)
        #expect(result == .failed("deadline-expired"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func deadlineBeforeRouteDoesNotOpen() throws {
        let driver = FakeReactionDriver()
        let result = try MessagesReactionAXAutomation(driver: driver).apply(request(), deadline: WorkerDeadline(uptimeNanoseconds: 0))
        #expect(result == .failed("deadline-expired"))
        #expect(driver.openedURLs.isEmpty)
    }

    @Test(arguments: ["nodes", "depth", "children"])
    func boundedTraversal(_ limit: String) throws {
        let driver = FakeReactionDriver()
        if limit == "children" { driver.transcript.nodes.append(FakeAXNode(role: "AXGroup")) }
        let automation = MessagesReactionAXAutomation(driver: driver, maxTraversalNodes: limit == "nodes" ? 2 : 30,
            maxTraversalDepth: limit == "depth" ? 1 : 8, maxChildren: limit == "children" ? 1 : 10)
        #expect(try automation.apply(request(), deadline: .millisecondsFromNow(1_000)) == .refused("traversal-limit"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test(arguments: [MessagesReactionWorkerPayload.Operation.set, .remove])
    func pressOnceAndDisappearingPickerIsSuccessfulAction(_ operation: MessagesReactionWorkerPayload.Operation) throws {
        let driver = FakeReactionDriver()
        driver.button.isSelected = operation == .remove
        driver.button.onAction = { _ in
            driver.button.isSelected = operation == .set
            driver.window.nodes = [driver.transcript]
        }
        #expect(try apply(driver, operation) == .ack(operation == .set ? "reaction-set-changed-verified" : "reaction-remove-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func menuHidingTranscriptRefusesBeforeReactionPress() throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            driver.window.nodes = [driver.picker]
        }

        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test func menuLookalikeSelectedMessageRefusesBeforeReactionPress() throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            let message = FakeAXNode(role: "AXGroup", selected: true, actions: driver.message.actionNames)
            let transcript = FakeAXNode(role: "AXCollection", id: "TranscriptCollectionView", children: [message])
            transcript.owningWindow = driver.window
            message.owningWindow = driver.window
            driver.window.nodes = [transcript, driver.picker]
        }

        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test func experimentalHandoffAllowsPickerWhenMenuHidesTranscript() throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            driver.window.nodes = [driver.picker]
        }

        #expect(try apply(driver, experimentalUIHandoff: true) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test(arguments: ["process", "window", "duplicate-window"])
    func experimentalHandoffRefusesPostMenuRouteDrift(_ drift: String) throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            driver.window.nodes = [driver.picker]
            if drift == "process" {
                driver.processIdentity = MessagesAXProcessIdentity(pid: 124, bundleURL: driver.processIdentity.bundleURL,
                                                                   launchDate: driver.processIdentity.launchDate)
            } else if drift == "window" {
                driver.root.nodes = [FakeAXNode(role: "AXWindow", children: [driver.picker])]
            } else {
                driver.root.nodes.append(FakeAXNode(role: "AXWindow"))
            }
        }

        #expect(try apply(driver, experimentalUIHandoff: true) == .refused("target-drift"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test func experimentalHandoffRefusesSelectedStateDriftBeforePress() throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            driver.window.nodes = [driver.picker]
        }
        driver.onProcessRead = { count in
            if count == 4 { driver.button.isSelected = true }
        }

        #expect(try apply(driver, experimentalUIHandoff: true) == .refused("target-drift"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test func changedReactionRequiresRetainedProofAfterOnePress() throws {
        let driver = FakeReactionDriver()

        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
    }

    @Test func changedReactionRefusesWhenReadOnlyVerificationDoesNotObserveDesiredSelection() throws {
        let driver = FakeReactionDriver()
        driver.button.onAction = { _ in }

        #expect(try apply(driver) == .refused("post-press-selection-timeout"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func postPressRouteReadinessPropagatesAmbiguousSelectionWithoutRetry() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            let other = driver.message.clone()
            other.identity = UUID()
            driver.transcript.nodes = [driver.message, other]
            driver.window.nodes = [driver.transcript]
        }

        #expect(try apply(driver, clock: clock) == .refused("ambiguous-selected-message"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func postPressReadinessRefusesTransientDifferentEmptyWindowWithoutRetry() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let otherWindow = FakeAXNode(role: "AXWindow")
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
            driver.root.nodes = [otherWindow]
        }
        clock.onPause = {
            driver.window.nodes = [driver.transcript]
            driver.root.nodes = [driver.window]
        }

        #expect(try apply(driver, clock: clock) == .refused("post-press-window-drift"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.button.performed == ["AXPress"])
        withExtendedLifetime(otherWindow) {}
    }

    @Test func postPressReadinessRefusesDuplicateEmptyWindowsWithoutRetry() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let otherWindow = FakeAXNode(role: "AXWindow")
        driver.button.onAction = { _ in
            driver.button.isSelected = true
        }
        driver.onProcessRead = { _ in
            guard driver.button.performed == ["AXPress"] else { return }
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
            driver.root.nodes = [driver.window, otherWindow]
        }
        clock.onPause = {
            driver.window.nodes = [driver.transcript]
            driver.root.nodes = [driver.window]
        }

        #expect(try apply(driver, clock: clock) == .refused("post-press-window-drift"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.button.performed == ["AXPress"])
        withExtendedLifetime(otherWindow) {}
    }

    @Test func postPressRetainedRouteWaitsPastPickerCapForReadOnlyRoute() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        var observedVerifyReadDeadline: WorkerDeadline?
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        driver.root.onChildrenRead = { effective in
            guard driver.button.performed == ["AXPress"], observedVerifyReadDeadline == nil,
                  effective.remainingNanoseconds > 1_500_000_000 else { return }
            observedVerifyReadDeadline = effective
        }
        clock.onPause = {
            guard clock.now > 1_500_000_000,
                  !driver.window.nodes.contains(where: { $0.sameIdentity(as: driver.transcript) }) else { return }
            driver.window.nodes.insert(driver.transcript, at: 0)
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true, deadline: .millisecondsFromNow(10_000)) == .ack("reaction-set-changed-verified"))
        #expect(clock.now > 1_500_000_000)
        let effectiveRemaining = try #require(observedVerifyReadDeadline).remainingNanoseconds
        #expect(effectiveRemaining > 1_500_000_000)
        #expect(effectiveRemaining <= 8_000_000_000)
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 2)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteStopsAtExtendedLocalBudget() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true, deadline: .millisecondsFromNow(10_000)) == .refused("post-press-verify-route-drift"))
        #expect(clock.pauses.count == 160)
        #expect(clock.now == 8_000_000_000)
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteUsesShorterGlobalReadDeadline() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let global = WorkerDeadline.millisecondsFromNow(500)
        var observedEffectiveDeadline: WorkerDeadline?
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        driver.root.onChildrenRead = { effective in
            guard driver.button.performed == ["AXPress"], observedEffectiveDeadline == nil else { return }
            observedEffectiveDeadline = effective
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true, deadline: global) == .refused("post-press-verify-route-drift"))
        #expect(observedEffectiveDeadline == global)
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func pickerDismissalRechecksCanonicalWindowBeforeAck() throws {
        let driver = FakeReactionDriver()
        driver.picker.onAction = { name in
            guard name == "AXCancel" else { return }
            driver.processIdentity = MessagesAXProcessIdentity(pid: 124, bundleURL: driver.processIdentity.bundleURL,
                                                               launchDate: driver.processIdentity.launchDate)
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }

        #expect(try apply(driver) == .refused("picker-dismissal-window-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
    }

    @Test func alreadyDesiredReactionUsesReadOnlyProofWithoutPress() throws {
        let driver = FakeReactionDriver()
        driver.button.isSelected = true

        #expect(try apply(driver) == .ack("reaction-set-unchanged-verified"))
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
        #expect(driver.picker.performed == ["AXCancel"])
    }

    @Test func alreadyDesiredCleanupUsesPhaseNeutralDismissalReason() throws {
        let timeoutDriver = FakeReactionDriver()
        timeoutDriver.button.isSelected = true
        timeoutDriver.picker.onAction = { _ in }

        #expect(try apply(timeoutDriver) == .refused("picker-dismissal-timeout"))
        #expect(timeoutDriver.button.performed.isEmpty)
        #expect(timeoutDriver.picker.performed == ["AXCancel"])

        let driftDriver = FakeReactionDriver()
        driftDriver.button.isSelected = true
        driftDriver.onProcessRead = { count in if count == 4 { driftDriver.replace("window") } }
        #expect(try apply(driftDriver) == .refused("target-drift"))
        #expect(driftDriver.button.performed.isEmpty)
    }

    @Test(arguments: ["👍🏽", "👩🏽‍💻", "❤️", "❤︎", "🇬🇧", "1️⃣"])
    func exactCustomSelectionAndRemoval(_ emoji: String) throws {
        for operation in [MessagesReactionWorkerPayload.Operation.set, .remove] {
            let driver = FakeReactionDriver()
            driver.button.id = emoji
            driver.button.isSelected = operation == .remove
            #expect(try apply(driver, operation, .custom(emoji)) == .ack(operation == .set ? "reaction-set-changed-verified" : "reaction-remove-changed-verified"))
            #expect(driver.button.performed == ["AXPress"])
            #expect(driver.button.id?.utf8.elementsEqual(emoji.utf8) == true)
        }
    }

    @Test(arguments: [("👍🏽", "👍"), ("❤️", "❤"), ("❤︎", "❤️"), ("👩🏽‍💻", "👩‍💻")])
    func customVariantMismatchRefuses(_ requested: String, _ displayed: String) throws {
        let driver = FakeReactionDriver()
        driver.button.id = displayed
        #expect(try apply(driver, .set, .custom(requested)) == .refused("reaction-unavailable"))
        #expect(driver.button.performed.isEmpty)
    }

    @Test func duplicateExactButtonsRefuse() throws {
        let driver = FakeReactionDriver()
        driver.picker.nodes.append(driver.button.clone())
        #expect(try apply(driver) == .refused("reaction-unavailable"))
        #expect(driver.button.performed.isEmpty)
    }

    @Test func pickerOutsideRetainedWindowRefuses() throws {
        let driver = FakeReactionDriver()
        driver.message.onAction = { _ in
            driver.root.nodes.append(FakeAXNode(role: "AXWindow", children: [driver.picker]))
        }
        #expect(try apply(driver) == .refused("picker-unavailable"))
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["window", "picker", "button"])
    func linkedForeignPickerOrButtonRefuses(_ entry: String) throws {
        let driver = FakeReactionDriver()
        let otherWindow = FakeAXNode(role: "AXWindow", children: [driver.picker])
        driver.picker.owningWindow = otherWindow
        driver.button.owningWindow = otherWindow
        driver.message.onAction = { _ in
            if entry == "button" {
                // Even a retained-window picker can link directly to a foreign button.
                driver.picker.owningWindow = driver.window
                driver.picker.nodes = []
                driver.picker.links = [driver.button]
                driver.window.nodes.append(driver.picker)
            } else {
                driver.transcript.links = [entry == "window" ? otherWindow : driver.picker]
            }
        }
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["transcript", "message", "picker", "button"], ["absent", "error", "different", "equal"])
    func matchedElementsRequireWindowEvidence(_ element: String, _ evidence: String) throws {
        let driver = FakeReactionDriver()
        let node = switch element {
        case "transcript": driver.transcript
        case "message": driver.message
        case "picker": driver.picker
        default: driver.button
        }
        let windowEvidence = driver.window.clone()
        if evidence == "equal" { windowEvidence.identity = driver.window.identity }
        switch evidence {
        case "absent": node.owningWindow = nil
        case "error": node.windowError = .axFailure
        default: node.owningWindow = windowEvidence
        }
        let expected: MessagesReactionAXOutcome = switch evidence {
        case "absent": .refused("unknown-ax-value")
        case "error": .failed(element == "transcript" || element == "message" ? "ax-failure-initial-route" : "ax-failure-picker-readiness")
        case "different": .refused("target-drift")
        default: .ack("reaction-set-changed-verified")
        }
        #expect(try apply(driver) == expected)
        #expect(driver.button.performed == (evidence == "equal" ? ["AXPress"] : []))
        if evidence != "equal", element == "transcript" || element == "message" {
            #expect(driver.message.performed.isEmpty)
        }
        withExtendedLifetime(windowEvidence) {}
    }

    @Test(arguments: ["transcript", "message", "picker", "button"])
    func windowOwnershipDriftBeforeActionRefuses(_ element: String) throws {
        let driver = FakeReactionDriver()
        let otherWindow = FakeAXNode(role: "AXWindow")
        let beforeReact = element == "transcript" || element == "message"
        driver.onProcessRead = { count in
            guard count == (beforeReact ? 2 : 4) else { return }
            switch element {
            case "transcript": driver.transcript.owningWindow = otherWindow
            case "message": driver.message.owningWindow = otherWindow
            case "picker": driver.picker.owningWindow = otherWindow
            default: driver.button.owningWindow = otherWindow
            }
        }
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.count == (beforeReact ? 0 : 1))
        #expect(driver.button.performed.isEmpty)
    }

    @Test func customRemovalRequiresSelectedTrue() throws {
        for selected in [false, nil] as [Bool?] {
            let driver = FakeReactionDriver()
            driver.button.id = "👍🏽"
            driver.button.isSelected = selected
            #expect(try apply(driver, .remove, .custom("👍🏽")) ==
                    (selected == nil ? .refused("unknown-ax-value") : .ack("reaction-remove-unchanged-verified")))
            #expect(driver.button.performed.isEmpty)
        }
    }

    @Test(arguments: [MessagesReactionStandard.heart, .thumbsUp, .thumbsDown, .ha, .exclamation, .questionMark])
    func standardIdentifiersPreserved(_ standard: MessagesReactionStandard) throws {
        let driver = FakeReactionDriver()
        driver.button.id = standard.rawValue
        #expect(try apply(driver, .set, .standard(standard)) == .ack("reaction-set-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func linkedOnlyGroupTranscript() throws {
        let driver = FakeReactionDriver()
        let list = FakeAXNode(role: "AXOutline")
        list.links = [driver.transcript]
        driver.window.nodes = [list]
        driver.transcript.roleName = "AXGroup"
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func cyclesAndDuplicateReachabilityPreserveUniqueCandidates() throws {
        let driver = FakeReactionDriver()
        driver.window.links = [driver.transcript]
        driver.transcript.links = [driver.transcript, driver.message]
        driver.message.links = [driver.transcript]
        driver.picker.links = [driver.button]
        defer {
            driver.transcript.links = []
            driver.message.links = []
        }
        // Exactly six unique nodes after the picker opens; duplicate edges do
        // not consume node slots or make a second selected-message candidate.
        let automation = MessagesReactionAXAutomation(driver: driver, maxTraversalNodes: 6)
        #expect(try automation.apply(request(), deadline: .millisecondsFromNow(2_000)) == .ack("reaction-set-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test(arguments: [2, 4])
    func changedLinkedTranscriptIdentityAborts(_ processRead: Int) throws {
        let driver = FakeReactionDriver()
        let list = FakeAXNode(role: "AXOutline")
        list.links = [driver.transcript]
        driver.window.nodes = [list]
        driver.transcript.roleName = "AXGroup"
        driver.onProcessRead = { count in
            if count == processRead { list.links = [driver.transcript.clone()] }
        }
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.count == (processRead == 2 ? 0 : 1))
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["linked", "combined", "nodes", "depth"])
    func linkedRelationshipLimitsFailClosed(_ kind: String) throws {
        let driver = FakeReactionDriver()
        let list = FakeAXNode(role: "AXOutline")
        driver.window.nodes = [list]
        list.links = [driver.transcript]
        if kind == "linked" { list.links.append(driver.transcript) }
        if kind == "combined" { list.nodes = [driver.transcript] }
        let automation = MessagesReactionAXAutomation(driver: driver,
            maxTraversalNodes: kind == "nodes" ? 4 : 30,
            maxTraversalDepth: kind == "depth" ? 2 : 8, maxChildren: 1)
        #expect(try automation.apply(request(), deadline: .millisecondsFromNow(2_000)) == .refused("traversal-limit"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func deadlineExpiresInsideLinkedRelationship() throws {
        let driver = FakeReactionDriver()
        let deadline = WorkerDeadline.millisecondsFromNow(100)
        var read = false
        driver.transcript.onLinkedElements = {
            read = true
            Thread.sleep(forTimeInterval: Double(deadline.remainingNanoseconds) / 1_000_000_000 + 0.005)
        }
        #expect(try MessagesReactionAXAutomation(driver: driver).apply(request(), deadline: deadline) == .failed("deadline-expired"))
        #expect(read)
        #expect(driver.message.performed.isEmpty)
    }

    @Test func linkedTransportErrorNeverBecomesEmptyGraph() throws {
        let driver = FakeReactionDriver()
        driver.transcript.linkError = .axFailure
        #expect(try apply(driver) == .failed("ax-failure-initial-route"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func transcriptIdentifierStillMandatory() throws {
        let driver = FakeReactionDriver()
        driver.transcript.roleName = "AXGroup"
        driver.transcript.id = "OtherCollectionView"
        #expect(try apply(driver) == .refused("target-drift"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func equalityPreservesOriginalBytes() throws {
        // Swift String equality folds canonical equivalents; payload equality
        // must not, even for enum values that validation would later refuse.
        #expect("é" == "e\u{301}")
        #expect(MessagesReaction.custom("é") != .custom("e\u{301}"))
        let a = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-é",
            messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: nil, reaction: .custom("❤️"))
        let b = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-e\u{301}",
            messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: nil, reaction: .custom("❤️"))
        #expect(a != b)
        #expect(try a.request() != b.request())
    }

    @Test func workerJSONHasStableSortedKeys() throws {
        let payload = try MessagesReactionWorkerPayload(operation: .set, chatGUID: "chat-guid",
            messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: nil, reaction: .standard(.heart))
        let expected = Data(#"{"chat_guid":"chat-guid","experimental_ui_handoff":false,"message_guid":"message-guid","native_part_index":2,"operation":"set","reaction":{"standard":"heart"}}"#.utf8)
        for _ in 0..<10 { #expect(try payload.workerPayloadData() == expected) }
    }

    @Test func actionListAbsenceIsDistinctFromUnsupportedProcessAndTransportFailure() throws {
        for status in [AXError.actionUnsupported, .attributeUnsupported, .noValue] {
            #expect(try LiveAXElement.checkedActions(status: status, names: nil).isEmpty)
        }
        #expect(throws: MessagesReactionAXError.unknownAXValue) {
            try LiveAXElement.checkedActions(status: .notImplemented, names: nil)
        }
        for status in [AXError.cannotComplete, .invalidUIElement, .failure, .illegalArgument] {
            #expect(throws: MessagesReactionAXError.axFailure) {
                try LiveAXElement.checkedActions(status: status, names: nil)
            }
        }
        #expect(try LiveAXElement.checkedActions(status: .success, names: [] as CFArray).isEmpty)
        #expect(try LiveAXElement.checkedActions(status: .success, names: ["AXPress"] as CFArray) == ["AXPress"])
        for names in [nil, [NSNumber(value: 1)] as CFArray,
                      Array(repeating: "AXPress", count: 129) as CFArray,
                      [String(repeating: "a", count: 2049)] as CFArray] as [CFArray?] {
            #expect(throws: MessagesReactionAXError.unknownAXValue) {
                try LiveAXElement.checkedActions(status: .success, names: names)
            }
        }
    }

    @Test func adapterWindowEvidenceRequiresNativeElementAndSuccessfulRead() throws {
        for status in [AXError.attributeUnsupported, .noValue] {
            #expect(try LiveAXElement.checkedWindow(status: status, value: nil) == nil)
        }
        #expect(throws: MessagesReactionAXError.unknownAXValue) {
            try LiveAXElement.checkedWindow(status: .notImplemented, value: nil)
        }
        for status in [AXError.cannotComplete, .invalidUIElement, .failure, .illegalArgument] {
            #expect(throws: MessagesReactionAXError.axFailure) {
                try LiveAXElement.checkedWindow(status: status, value: nil)
            }
        }
        for value in [nil, "AXWindow" as CFString, kCFBooleanTrue, ["AXWindow"] as CFArray] as [CFTypeRef?] {
            #expect(throws: MessagesReactionAXError.unknownAXValue) {
                try LiveAXElement.checkedWindow(status: .success, value: value)
            }
        }
        // Opaque local AX references only: no remote reads, actions, or UI.
        let native = AXUIElementCreateApplication(123)
        let owner = try #require(try LiveAXElement.checkedWindow(status: .success, value: native))
        let alias = try #require(try LiveAXElement.checkedWindow(status: .success, value: native))
        #expect(owner !== alias)
        #expect(owner.sameIdentity(as: alias))
        #expect(!owner.sameIdentity(as: LiveAXElement(element: AXUIElementCreateApplication(124))))
    }

    @Test func adapterStringsHaveTypeAndUTF8Bounds() throws {
        #expect(try LiveAXElement.checkedString("AXGroup" as CFString, limit: 128) == "AXGroup")
        for value in [NSNumber(value: 1), String(repeating: "a", count: 129) as NSString,
                      String(repeating: "🙂", count: 40) as NSString] {
            #expect(throws: MessagesReactionAXError.unknownAXValue) {
                try LiveAXElement.checkedString(value, limit: 128)
            }
        }
    }

    @Test(arguments: ["role", "identifier"])
    func traversalBoundsStringsEvenOnNonmatchingNodes(_ attribute: String) throws {
        let driver = FakeReactionDriver()
        let unrelated = FakeAXNode(role: "AXGroup")
        if attribute == "role" { unrelated.roleName = String(repeating: "a", count: 129) }
        else { unrelated.id = String(repeating: "a", count: 2049) }
        driver.window.links = [unrelated]
        #expect(try apply(driver) == .refused("unknown-ax-value"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func differentWrappersWithSameAXIdentityAreDeduplicated() throws {
        let driver = FakeReactionDriver()
        let alias = driver.message.clone()
        alias.identity = driver.message.identity
        driver.transcript.links = [alias]
        #expect(driver.message !== alias)
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.message.performed.count == 1)
        #expect(alias.performed.isEmpty)
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func cyclesAtDepthLimitDoNotConsumeAnotherDepth() throws {
        let driver = FakeReactionDriver()
        driver.message.links = [driver.transcript]
        defer { driver.message.links = [] }
        // Application -> window -> transcript -> selected message is depth 3.
        #expect(try MessagesReactionAXAutomation(driver: driver, maxTraversalDepth: 3)
            .apply(request(), deadline: .millisecondsFromNow(2_000)) == .ack("reaction-set-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test func actionFailureNeverRetries() throws {
        let driver = FakeReactionDriver()
        driver.button.onAction = { _ in throw MessagesReactionAXError.axFailure }
        #expect(try apply(driver) == .failed("ax-failure-press"))
        #expect(driver.button.performed == ["AXPress"])
    }

    @Test(arguments: ["picker", "button"])
    func delayedReadinessDoesNotRepeatTapback(_ delayed: String) throws {
        let driver = FakeReactionDriver()
        var reads = 0
        if delayed == "picker" {
            var pendingPickerAppearance = false
            driver.message.onAction = { _ in
                pendingPickerAppearance = true
                reads = 0
            }
            driver.window.onChildren = {
                guard pendingPickerAppearance else { return }
                reads += 1
                if reads >= 2, !driver.window.nodes.contains(where: { $0.sameIdentity(as: driver.picker) }) {
                    driver.window.nodes.append(driver.picker)
                    pendingPickerAppearance = false
                }
            }
        } else {
            driver.picker.nodes = []
            driver.picker.onChildren = {
                reads += 1
                if reads == 3 { driver.picker.nodes = [driver.button] }
            }
        }
        #expect(try apply(driver) == .ack("reaction-set-changed-verified"))
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed == ["AXPress"])
    }

    private func apply(_ driver: FakeReactionDriver, _ operation: MessagesReactionWorkerPayload.Operation = .set,
                       clock: FakeReadinessClock, experimentalUIHandoff: Bool = false,
                       deadline: WorkerDeadline = .millisecondsFromNow(2_000)) throws -> MessagesReactionAXOutcome {
        try MessagesReactionAXAutomation(driver: driver, readinessNow: { clock.now }, readinessPause: { clock.pause($0) })
            .apply(request(operation, experimentalUIHandoff: experimentalUIHandoff), deadline: deadline)
    }

    @Test(arguments: ["picker", "button"], [false, true])
    func readinessExhaustionIsBounded(_ missing: String, _ frozenClock: Bool) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        clock.advanceOnPause = !frozenClock
        if missing == "picker" { driver.message.onAction = { _ in } }
        else { driver.picker.nodes = [] }
        #expect(try apply(driver, clock: clock) == .refused(missing == "picker" ? "picker-unavailable" : "reaction-unavailable"))
        #expect(clock.pauses.count == 30)
        #expect(clock.pauses.allSatisfy { $0 > 0 && $0 <= 50_000_000 })
        #expect(driver.processReads > 2) // Retained route revalidated between attempts.
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test func localCapIsCheckedAfterReadBeforeAcceptingReadyButton() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.picker.onChildren = { clock.now = 1_500_000_000 }
        #expect(try apply(driver, clock: clock) == .refused("picker-unavailable"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["picker", "button", "revalidation"], [false, true])
    func readinessDeadlineStopsReadsDuringTraversal(_ phase: String, _ earlierGlobal: Bool) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        clock.advanceOnPause = false
        let global = WorkerDeadline.millisecondsFromNow(earlierGlobal ? 500 : 10_000)
        let target = phase == "revalidation" ? driver.root : driver.picker
        var childReads = 0
        var expiredDuringRead = false
        var readsAfterExpiry = 0
        let installExpiry = {
            target.onChildrenRead = { effective in
                childReads += 1
                // Picker discovery reads its children once; button discovery
                // reads them a second time, under the same readiness budget.
                guard childReads == (phase == "button" ? 2 : 1) else { return }
                if earlierGlobal {
                    #expect(effective == global)
                } else {
                    #expect(effective.uptimeNanoseconds < global.uptimeNanoseconds)
                    #expect(effective.remainingNanoseconds <= 1_500_000_000)
                }
                Thread.sleep(forTimeInterval: Double(min(effective.remainingNanoseconds, 1_500_000_000)) / 1_000_000_000 + 0.005)
                expiredDuringRead = true
            }
            target.onLinkedElements = {
                if expiredDuringRead { readsAfterExpiry += 1 }
            }
            driver.button.onChildren = {
                if expiredDuringRead { readsAfterExpiry += 1 }
            }
        }
        if phase == "revalidation" {
            driver.message.onAction = { _ in }
            clock.onPause = {
                driver.window.nodes.append(driver.picker)
                installExpiry()
            }
        } else {
            installExpiry()
        }
        let expected: MessagesReactionAXOutcome = earlierGlobal ? .failed("deadline-expired") :
            .refused(phase == "button" ? "reaction-unavailable" : "picker-unavailable")
        #expect(try apply(driver, clock: clock, deadline: global) == expected)
        #expect(expiredDuringRead)
        #expect(readsAfterExpiry == 0)
        #expect(clock.pauses.count == (phase == "revalidation" ? 1 : 0))
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
        if !earlierGlobal { #expect(!global.expired) }
    }

    @Test func pauseIsClampedToRemainingLocalBudget() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.message.onAction = { _ in
            driver.window.onChildren = { clock.now = 1_490_000_000 }
        }
        #expect(try apply(driver, clock: clock) == .refused("picker-unavailable"))
        #expect(clock.pauses == [10_000_000])
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["pause", "read", "press"])
    func globalDeadlineIsCheckedAfterReadinessWork(_ phase: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let deadline = WorkerDeadline.millisecondsFromNow(100)
        let expire = {
            Thread.sleep(forTimeInterval: Double(deadline.remainingNanoseconds) / 1_000_000_000 + 0.005)
        }
        switch phase {
        case "pause":
            driver.message.onAction = { _ in }
            clock.onPause = expire
        case "read": driver.picker.onChildren = expire
        default: driver.button.onAction = { _ in expire() }
        }
        #expect(try apply(driver, clock: clock, deadline: deadline) == .failed("deadline-expired"))
        #expect(clock.pauses.count == (phase == "pause" ? 1 : 0))
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.count == (phase == "press" ? 1 : 0))
    }

    @Test(arguments: ["duplicate-picker", "duplicate-button", "foreign-picker", "foreign-button",
                      "unknown", "invalid-selected", "transport"])
    func readinessErrorsAreNeverRetried(_ failure: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let foreign = FakeAXNode(role: "AXWindow")
        driver.message.onAction = { _ in
            driver.window.nodes.append(driver.picker)
            switch failure {
            case "duplicate-picker": driver.window.nodes.append(driver.picker.clone())
            case "duplicate-button": driver.picker.nodes.append(driver.button.clone())
            case "foreign-picker": driver.picker.owningWindow = foreign
            case "foreign-button": driver.button.owningWindow = foreign
            case "unknown": driver.button.isSelected = nil
            case "invalid-selected": driver.button.selectedError = .unknownAXValue
            default: driver.picker.linkError = .axFailure
            }
        }
        let expected: MessagesReactionAXOutcome = switch failure {
        case "duplicate-picker": .refused("picker-unavailable")
        case "duplicate-button": .refused("reaction-unavailable")
        case "foreign-picker", "foreign-button": .refused("target-drift")
        case "unknown", "invalid-selected": .refused("unknown-ax-value")
        default: .failed("ax-failure-picker-readiness")
        }
        #expect(try apply(driver, clock: clock) == expected)
        #expect(clock.pauses.isEmpty)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
        withExtendedLifetime(foreign) {}
    }


    @Test(arguments: ["process", "window", "transcript", "message", "picker", "missing-picker"])
    func readinessRetryRefusesRetainedIdentityDrift(_ level: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.picker.nodes = []
        clock.onPause = {
            if level == "missing-picker" { driver.window.nodes = [driver.transcript] }
            else { driver.replace(level) }
        }
        #expect(try apply(driver, clock: clock) == .refused("target-drift"))
        #expect(clock.pauses.count == 1)
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: ["picker", "button"], [3, 4])
    func finalRevalidationAbsenceNeverStartsReadinessAgain(_ missing: String, _ processRead: Int) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.onProcessRead = { count in
            guard count == processRead else { return }
            if missing == "picker" { driver.window.nodes = [driver.transcript] }
            else { driver.picker.nodes = [] }
        }
        #expect(try apply(driver, clock: clock) == .refused(missing == "picker" ? "picker-unavailable" : "reaction-unavailable"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.isEmpty)
    }

    @Test(arguments: [MessagesReactionWorkerPayload.Operation.set, .remove])
    func postPressRetainedProofAcksAfterCleanupWhenSelectionVanishes(_ operation: MessagesReactionWorkerPayload.Operation) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.isSelected = operation == .remove
        driver.button.onAction = { _ in
            driver.button.isSelected = operation == .set
        }
        driver.picker.onAction = { name in
            guard name == "AXCancel" else { return }
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
            driver.message.isSelected = false
        }
        let automation = MessagesReactionAXAutomation(driver: driver, readinessNow: { clock.now },
                                                      readinessPause: { clock.pause($0) })

        #expect(try automation.apply(request(operation, experimentalUIHandoff: true),
                                     deadline: .millisecondsFromNow(2_000)) ==
                .ack(operation == .set ? "reaction-set-changed-verified" : "reaction-remove-changed-verified"))
        #expect(driver.openedURLs.count == 1)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
    }

    @Test func postPressWaitsForRetainedButtonBeforeAckWhenModalBlocksOpen() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.ignoreOpenWhilePickerPresent = true
        var pressed = false
        driver.button.onAction = { _ in
            pressed = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.transcript) }
        }
        clock.onPause = { if pressed { driver.button.isSelected = true } }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .ack("reaction-set-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
        #expect(!clock.pauses.isEmpty)
    }

    @Test(arguments: [MessagesReactionWorkerPayload.Operation.set, .remove])
    func postPressAutoDismissVerifiesRetainedRouteWithoutSecondNavigation(_ operation: MessagesReactionWorkerPayload.Operation) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.isSelected = operation == .remove
        driver.button.onAction = { _ in
            driver.button.isSelected = operation == .set
            driver.message.isSelected = false
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }

        #expect(try apply(driver, operation, clock: clock, experimentalUIHandoff: true) ==
                .ack(operation == .set ? "reaction-set-changed-verified" : "reaction-remove-changed-verified"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
        #expect(driver.message.performed.count == 2)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressSelectionNeverConvergesFailsWithoutSecondPress() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-selection-timeout"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressIdentityDriftFailsWithoutSecondNavigation() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in }
        clock.onPause = { driver.replace("window") }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-window-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test(arguments: [("picker", "post-press-picker-identity-drift"),
                      ("button", "post-press-button-identity-drift")])
    func postPressRetainedPickerAndButtonIdentityDriftAreLocalized(_ drift: String, _ detail: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in }
        clock.onPause = { driver.replace(drift) }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused(detail))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressSelectedNilIsLocalizedWithoutSecondPress() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in }
        clock.onPause = { driver.button.isSelected = nil }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-selected-unknown"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressCleanupFailureFailsAfterSelectedProof() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.picker.onAction = { _ in }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("picker-dismissal-timeout"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test(arguments: ["process", "pid", "bundle", "launch", "window", "transcript", "message"])
    func postPressRetainedRouteIdentityDriftFailsClosed(_ drift: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        var postPressProcessReads = 0
        driver.onProcessRead = { _ in
            guard driver.button.performed == ["AXPress"] else { return }
            postPressProcessReads += 1
            if ["process", "pid", "bundle", "launch", "window"].contains(drift), postPressProcessReads == 3 {
                driver.replace(drift)
            }
        }
        driver.window.onChildren = {
            guard drift == "transcript", driver.button.performed == ["AXPress"], postPressProcessReads >= 3 else { return }
            driver.replace("transcript")
        }
        driver.transcript.onChildren = {
            guard drift == "message", driver.button.performed == ["AXPress"], postPressProcessReads >= 3 else { return }
            driver.replace("message")
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-route-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteForeignOwnershipFailsClosed() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let foreignWindow = FakeAXNode(role: "AXWindow")
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
            driver.message.owningWindow = foreignWindow
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-route-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
        withExtendedLifetime(foreignWindow) {}
    }

    @Test func postPressRetainedRouteAbsentMessageTimesOut() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
            driver.transcript.nodes = []
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true, deadline: .millisecondsFromNow(10_000)) == .refused("post-press-verify-route-drift"))
        #expect(clock.now == 8_000_000_000)
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteActionGoneIsLocalized() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
            driver.message.actionNames = []
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-action-missing"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteWrongReactionStateFailsAfterOnePress() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-picker-state-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed.isEmpty)
        #expect(driver.message.performed.count == 2)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteCleanupFailureRefuses() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        driver.picker.onAction = { _ in }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("picker-dismissal-timeout"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.picker.performed == ["AXCancel"])
        #expect(driver.message.performed.count == 2)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteRechecksIdentityImmediatelyBeforeMenu() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        var childReadsAfterPress = 0
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        driver.transcript.onChildren = {
            guard driver.button.performed == ["AXPress"] else { return }
            childReadsAfterPress += 1
            if childReadsAfterPress == 2 { driver.transcript.nodes = [driver.message.clone()] }
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-route-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test func postPressRetainedRouteRefusesPickerInterferenceBeforeMenu() throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        var childReadsAfterPress = 0
        driver.button.onAction = { _ in
            driver.button.isSelected = true
            driver.window.nodes.removeAll { $0.sameIdentity(as: driver.picker) }
        }
        driver.transcript.onChildren = {
            guard driver.button.performed == ["AXPress"] else { return }
            childReadsAfterPress += 1
            if childReadsAfterPress == 2,
               !driver.window.nodes.contains(where: { $0.sameIdentity(as: driver.picker) }) {
                driver.window.nodes.append(driver.picker)
            }
        }

        #expect(try apply(driver, clock: clock, experimentalUIHandoff: true) == .refused("post-press-verify-route-drift"))
        #expect(driver.button.performed == ["AXPress"])
        #expect(driver.message.performed.count == 1)
        #expect(driver.openedURLs.count == 1)
    }

    @Test(arguments: ["tapback", "press"])
    func mutatingErrorsNeverRetryDuringReadiness(_ phase: String) throws {
        let driver = FakeReactionDriver()
        let clock = FakeReadinessClock()
        let target = phase == "tapback" ? driver.message : driver.button
        target.onAction = { _ in throw MessagesReactionAXError.axFailure }
        #expect(try apply(driver, clock: clock) == .failed(phase == "tapback" ? "ax-failure-menu-open" : "ax-failure-press"))
        #expect(clock.pauses.isEmpty)
        #expect(driver.message.performed.count == 1)
        #expect(driver.button.performed.count == (phase == "press" ? 1 : 0))
    }
}

private final class FakeReadinessClock {
    var now: UInt64 = 0
    var pauses: [UInt64] = []
    var advanceOnPause = true
    var onPause: (() -> Void)?
    func pause(_ nanoseconds: UInt64) {
        pauses.append(nanoseconds)
        if advanceOnPause { now += nanoseconds }
        onPause?()
    }
}

private final class FakeReactionDriver: MessagesReactionAXDriving {
    static let identity = MessagesAXProcessIdentity(pid: 123, bundleURL: LiveMessagesReactionAXDriver.applicationURL,
                                                    launchDate: Date(timeIntervalSince1970: 1_000))
    var processIdentity = identity
    var trusted = true
    var prompted = false
    var actionTitles = ["Tapback Details\u{2026}", "Tapback"]
    var openedURLs: [URL] = []
    var processReads = 0
    var onProcessRead: ((Int) -> Void)?
    var ignoreOpenWhilePickerPresent = false
    var shouldRestoreTranscriptOnOpen: (() -> Bool)?
    var actionTitlesError: MessagesReactionAXError?
    var openError: MessagesReactionAXError?
    var root: FakeAXNode
    var window: FakeAXNode
    var transcript: FakeAXNode
    var message: FakeAXNode
    var picker: FakeAXNode
    var button: FakeAXNode

    init() {
        message = FakeAXNode(role: "AXGroup", selected: true, actions: ["Name:Tapback\nTarget:0x0\nSelector:(null)"])
        transcript = FakeAXNode(role: "AXCollection", id: "TranscriptCollectionView", children: [message])
        button = FakeAXNode(role: "AXButton", id: "heart", selected: false, actions: ["AXPress"])
        picker = FakeAXNode(role: "AXCollection", id: "TapbackPickerCollectionView", actions: ["AXCancel"], children: [button])
        window = FakeAXNode(role: "AXWindow", children: [transcript])
        root = FakeAXNode(role: "AXApplication", children: [window])
        for node in [transcript, message, picker, button] { node.owningWindow = window }
        message.onAction = { [weak self] _ in
            guard let self else { return }
            if !self.window.nodes.contains(where: { $0.sameIdentity(as: self.picker) }) {
                self.window.nodes.append(self.picker)
            }
        }
        picker.onAction = { [weak self] name in
            guard name == "AXCancel", let self else { return }
            self.window.nodes.removeAll { $0.sameIdentity(as: self.picker) }
        }
    }

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { prompted = prompt; return trusted }
    func reactActionTitles(deadline: WorkerDeadline) throws -> [String] {
        if let actionTitlesError { throw actionTitlesError }
        return actionTitles
    }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess {
        if let openError { throw openError }
        openedURLs.append(url)
        let pickerPresent = window.nodes.contains { $0.sameIdentity(as: picker) }
        if !(ignoreOpenWhilePickerPresent && pickerPresent),
           shouldRestoreTranscriptOnOpen?() ?? true,
           !window.nodes.contains(where: { $0.sameIdentity(as: transcript) }) {
            window.nodes.insert(transcript, at: 0)
        }
        return MessagesAXProcess(identity: processIdentity, root: root)
    }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess {
        processReads += 1
        onProcessRead?(processReads)
        return MessagesAXProcess(identity: processIdentity, root: root)
    }
    func replace(_ level: String) {
        switch level {
        case "process": root = root.clone()
        case "pid": processIdentity = MessagesAXProcessIdentity(pid: 124, bundleURL: processIdentity.bundleURL, launchDate: processIdentity.launchDate)
        case "bundle": processIdentity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/tmp/Other.app"), launchDate: processIdentity.launchDate)
        case "launch": processIdentity = MessagesAXProcessIdentity(pid: 123, bundleURL: processIdentity.bundleURL, launchDate: Date(timeIntervalSince1970: 2_000))
        case "window": root.nodes = [window.clone()]
        case "transcript": window.nodes = [transcript.clone(), picker]
        case "message": transcript.nodes = [message.clone()]
        case "picker": window.nodes = [transcript, picker.clone()]
        case "button": picker.nodes = [button.clone()]
        default: break
        }
    }
}

private final class FakeAXNode: MessagesAXElement {
    var identity = UUID()
    var roleName: String
    var id: String?
    var isSelected: Bool?
    var actionNames: [String]
    var nodes: [any MessagesAXElement]
    var links: [any MessagesAXElement] = []
    weak var owningWindow: (any MessagesAXElement)?
    var windowError: MessagesReactionAXError?
    var linkError: MessagesReactionAXError?
    var onLinkedElements: (() -> Void)?
    var performed: [String] = []
    var readError: MessagesReactionAXError?
    var selectedError: MessagesReactionAXError?
    var onSelectedRead: (() -> Void)?
    var onChildren: (() -> Void)?
    var onChildrenRead: ((WorkerDeadline) -> Void)?
    var onAction: ((String) throws -> Void)?

    init(role: String, id: String? = nil, selected: Bool? = nil,
         actions: [String] = [], children: [any MessagesAXElement] = []) {
        roleName = role; self.id = id; isSelected = selected; actionNames = actions; nodes = children
    }
    func clone() -> FakeAXNode {
        let copy = FakeAXNode(role: roleName, id: id, selected: isSelected, actions: actionNames, children: nodes)
        copy.owningWindow = owningWindow
        return copy
    }
    func sameIdentity(as other: any MessagesAXElement) -> Bool {
        guard let other = other as? FakeAXNode else { return false }
        return identity == other.identity
    }
    private func check(_ deadline: WorkerDeadline) throws {
        if deadline.expired { throw MessagesReactionAXError.deadlineExpired }
        if let readError { throw readError }
    }
    func role(deadline: WorkerDeadline) throws -> String { try check(deadline); return roleName }
    func identifier(deadline: WorkerDeadline) throws -> String? { try check(deadline); return id }
    func selected(deadline: WorkerDeadline) throws -> Bool? {
        try check(deadline)
        if let selectedError { throw selectedError }
        let value = isSelected
        onSelectedRead?()
        return value
    }
    func actions(deadline: WorkerDeadline) throws -> [String] { try check(deadline); return actionNames }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try check(deadline)
        if let windowError { throw windowError }
        return owningWindow
    }
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try check(deadline)
        onChildren?()
        onChildrenRead?(deadline)
        guard nodes.count <= limit else { throw MessagesReactionAXError.traversalLimit }
        return nodes
    }
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try check(deadline)
        onLinkedElements?()
        if let linkError { throw linkError }
        guard links.count <= limit else { throw MessagesReactionAXError.traversalLimit }
        return links
    }
    func performAction(named name: String, deadline: WorkerDeadline) throws {
        try check(deadline)
        performed.append(name)
        if name == "AXPress", onAction == nil, let selected = isSelected { isSelected = !selected }
        try onAction?(name)
    }
}
