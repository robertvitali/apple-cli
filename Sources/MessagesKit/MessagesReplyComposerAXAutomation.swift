import Foundation
import AppleKit

package enum MessagesReplyComposerProbeDetail {
    package static let verified = "no-send-empty-owned-composer-closed-verified"
}

enum MessagesReplyComposerAXOutcome: Equatable, Sendable {
    case ack(String)
    case refused(String)
    case failed(String)
}

struct MessagesReplyComposerCleanState {
    let process: MessagesAXProcess
    let window: any MessagesAXElement
    let transcript: any MessagesAXElement
    let normalBody: any MessagesAXElement
    let normalDraft: MessagesAXBodyValueEvidence
}

struct MessagesReplyComposerStartingState {
    let process: MessagesAXProcess
    let window: any MessagesAXElement
    let transcript: any MessagesAXElement
    let normalBody: any MessagesAXElement
    let normalDraft: MessagesAXBodyValueEvidence
}

enum MessagesReplyComposerAXError: String, Error, CustomStringConvertible, CaseIterable {
    case accessibilityDenied = "accessibility-denied"
    case axFailure = "ax-failure"
    case deadlineExpired = "deadline-expired"
    case invalidPayload = "invalid-payload"
    case replyActionUnavailable = "reply-action-unavailable"
    case replyComposerExisting = "reply-composer-existing"
    case replyComposerAmbiguous = "reply-composer-ambiguous"
    case replyComposerNotEmpty = "reply-composer-not-empty"
    case replyComposerEvidenceUnavailable = "reply-composer-evidence-unavailable"
    case replyComposerOwnershipDrift = "reply-composer-ownership-drift"
    case replyComposerAttachmentEvidence = "reply-composer-attachment-evidence"
    case replyComposerCleanupUnavailable = "reply-composer-cleanup-unavailable"
    case replyComposerCleanupFailed = "reply-composer-cleanup-failed"
    case replyComposerOriginalDraftDrift = "reply-composer-original-draft-drift"
    case replyComposerTextMismatch = "reply-composer-text-mismatch"
    case replyComposerPossibleDraftRemains = "reply-composer-possible-draft-remains"
    case targetDrift = "target-drift"
    case traversalLimit = "traversal-limit"
    case unknownAXValue = "unknown-ax-value"

    var description: String { rawValue }
}

protocol MessagesReplyComposerAXDriving: MessagesAXProcessDriving {
    func replyActionTitles(deadline: WorkerDeadline) throws -> [String]
    func normalComposePlaceholders(deadline: WorkerDeadline) throws -> [String]
    func replyTranscriptDescription(deadline: WorkerDeadline) throws -> String?
    func focusedElement(in process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
}

struct MessagesAXActionMatcher {
    static func matches(_ action: String, title: String) -> Bool {
        let prefix = Array("Name:\(title)".utf8)
        let bytes = Array(action.utf8)
        guard bytes.starts(with: prefix) else { return false }
        let suffix = Array(bytes.dropFirst(prefix.count))
        if suffix.isEmpty || suffix.first == 10 { return true }
        let ellipsis = Array("…".utf8)
        guard suffix.starts(with: ellipsis) else { return false }
        let afterEllipsis = suffix.dropFirst(ellipsis.count)
        return afterEllipsis.isEmpty || afterEllipsis.first == 10
    }
}

struct MessagesChatKitLocalizedStrings {
    var replyTitle: (WorkerDeadline) throws -> String?
    var replyTranscriptDescription: (WorkerDeadline) throws -> String?
    var normalComposePlaceholders: (WorkerDeadline) throws -> [String]

    init(replyTitle: @escaping (WorkerDeadline) throws -> String?,
                 replyTranscriptDescription: @escaping (WorkerDeadline) throws -> String?,
                 normalComposePlaceholders: @escaping (WorkerDeadline) throws -> [String]) {
        self.replyTitle = replyTitle
        self.replyTranscriptDescription = replyTranscriptDescription
        self.normalComposePlaceholders = normalComposePlaceholders
    }

    static func live() -> Self {
        Self(
            replyTitle: { deadline in
                try checkMessagesAXDeadline(deadline)
                return localizedString(bundlePath: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle",
                                       key: "balloon.message.reply", table: "Accessibility")
            },
            replyTranscriptDescription: { deadline in
                try checkMessagesAXDeadline(deadline)
                return localizedString(bundlePath: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle",
                                       key: "group.reply.collection", table: "Accessibility")
            },
            normalComposePlaceholders: { deadline in
                try checkMessagesAXDeadline(deadline)
                return [
                    localizedString(bundlePath: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework",
                                    key: "MADRID", table: "ChatKit"),
                    localizedString(bundlePath: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework",
                                    key: "TEXT_MESSAGE", table: "ChatKit")
                ].compactMap { $0 }
            })
    }

    func resolveReplyTitles(deadline: WorkerDeadline) throws -> [String] {
        try canonicalize([try replyTitle(deadline)].compactMap { $0 })
    }

    func resolveNormalPlaceholders(deadline: WorkerDeadline) throws -> [String] {
        try canonicalize(try normalComposePlaceholders(deadline))
    }

    func resolveReplyTranscriptDescription(deadline: WorkerDeadline) throws -> String? {
        guard let value = try replyTranscriptDescription(deadline) else { return nil }
        guard Self.valid(value) else { throw MessagesReplyComposerAXError.unknownAXValue }
        return value
    }

    private func canonicalize(_ raw: [String]) throws -> [String] {
        var values: [String] = []
        for value in raw {
            guard Self.valid(value) else { throw MessagesReplyComposerAXError.unknownAXValue }
            if !values.contains(where: { $0.utf8.elementsEqual(value.utf8) }) { values.append(value) }
        }
        guard !values.isEmpty, values.count <= 2 else { throw MessagesReplyComposerAXError.unknownAXValue }
        return values
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func localizedString(bundlePath: String, key: String, table: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: table)
        guard value != key, !value.isEmpty else { return nil }
        return value
    }
}

final class LiveMessagesReplyComposerAXDriver: MessagesReplyComposerAXDriving {
    private let localized: MessagesChatKitLocalizedStrings
    private let base = LiveMessagesReactionAXDriver()

    init(localized: MessagesChatKitLocalizedStrings = .live()) {
        self.localized = localized
    }

    func replyActionTitles(deadline: WorkerDeadline) throws -> [String] {
        try localized.resolveReplyTitles(deadline: deadline)
    }

    func normalComposePlaceholders(deadline: WorkerDeadline) throws -> [String] {
        try localized.resolveNormalPlaceholders(deadline: deadline)
    }

    func replyTranscriptDescription(deadline: WorkerDeadline) throws -> String? {
        try localized.resolveReplyTranscriptDescription(deadline: deadline)
    }

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { base.checkAccessibilityTrusted(prompt: prompt) }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { try base.openMessages(url: url, deadline: deadline) }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { try base.canonicalMessagesProcess(deadline: deadline) }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { try base.messagesProcessIsFrontmost(process, deadline: deadline) }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { try base.focusedElement(deadline: deadline) }
    func focusedElement(in process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        guard let root = process.root as? LiveAXElement else { throw MessagesAXNavigationError.axFailure }
        return try root.focusedElement(deadline: deadline)
    }
}

private enum MessagesReplyComposerAXStage: String {
    case preflight
    case open
    case postOpenSafety = "post-open-safety"
    case initialRoute = "initial-route"
    case routeRevalidation = "route-revalidation"
    case replyOpen = "reply-open"
    case composerReadiness = "composer-readiness"
    case cleanup
    case verification

    var axFailureDetail: String { "ax-failure-\(rawValue)" }
    var targetDriftDetail: String { "target-drift-\(rawValue)" }
}

private struct MessagesReplyComposerStagedAXFailure: Error {
    let stage: MessagesReplyComposerAXStage
    var detail: String { stage.axFailureDetail }
}

private struct MessagesReplyComposerStagedTargetDrift: Error {
    let stage: MessagesReplyComposerAXStage
    var detail: String { stage.targetDriftDetail }
}

struct MessagesReplyComposerAXAutomation {
    let driver: any MessagesReplyComposerAXDriving
    let maxTraversalNodes: Int
    let maxTraversalDepth: Int
    let maxChildren: Int
    private let readinessNow: () -> UInt64
    private let readinessPause: (UInt64) -> Void
    private let sendReturnKey: (pid_t, WorkerDeadline) throws -> Void

    init(driver: any MessagesReplyComposerAXDriving = LiveMessagesReplyComposerAXDriver(),
                 maxTraversalNodes: Int = 2_048, maxTraversalDepth: Int = 32, maxChildren: Int = 256,
                 readinessNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 readinessPause: @escaping (UInt64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) },
                 sendReturnKey: @escaping (pid_t, WorkerDeadline) throws -> Void = { pid, deadline in
                     let presser = LiveMessagesPairedKeyPresser(pid: pid)
                     do { try presser.pressReturn(flags: .cleared, deadline: deadline) }
                     catch MessagesPairedKeyPressError.deadlineExpired { throw MessagesReplyComposerAXError.deadlineExpired }
                     catch { throw MessagesReplyComposerAXError.axFailure }
                 }) {
        self.driver = driver
        self.maxTraversalNodes = maxTraversalNodes
        self.maxTraversalDepth = maxTraversalDepth
        self.maxChildren = maxChildren
        self.readinessNow = readinessNow
        self.readinessPause = readinessPause
        self.sendReturnKey = sendReturnKey
    }

    private var navigator: MessagesAXNavigator {
        MessagesAXNavigator(driver: driver, maxTraversalNodes: maxTraversalNodes,
                            maxTraversalDepth: maxTraversalDepth, maxChildren: maxChildren,
                            readinessNow: readinessNow, readinessPause: readinessPause)
    }

    private static func throwReplyCommonReactionError(_ error: MessagesReactionAXError, stage: MessagesReplyComposerAXStage) throws -> Never {
        switch error {
        case .deadlineExpired:
            throw MessagesReplyComposerAXError.deadlineExpired
        case .axFailure:
            throw MessagesReplyComposerStagedAXFailure(stage: stage)
        case .targetDrift, .ambiguousSelectedMessage:
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        case .unknownAXValue:
            throw MessagesReplyComposerAXError.unknownAXValue
        case .traversalLimit:
            throw MessagesReplyComposerAXError.traversalLimit
        default:
            throw error
        }
    }

    func inspect(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        do { return try execute(request, deadline: deadline) }
        catch let error as MessagesReplyComposerStagedAXFailure { return .failed(error.detail) }
        catch let error as MessagesReplyComposerStagedTargetDrift { return .refused(error.detail) }
        catch let error as MessagesReplyComposerAXError {
            switch error {
            case .axFailure, .deadlineExpired: return .failed(error.description)
            default: return .refused(error.description)
            }
        } catch let error as MessagesAXNavigationError {
            let mapped = Self.replyError(from: error)
            switch mapped {
            case .axFailure, .deadlineExpired: return .failed(mapped.description)
            default: return .refused(mapped.description)
            }
        } catch let error as MessagesAXRouteDrift {
            let mapped = Self.replyError(from: error)
            return .refused(mapped.description)
        } catch {
            return .failed(MessagesReplyComposerAXError.axFailure.description)
        }
    }

    func send(_ request: MessagesReplySendRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        do { return try executeSend(request, deadline: deadline) }
        catch let error as MessagesReplyComposerStagedAXFailure { return .failed(error.detail) }
        catch let error as MessagesReplyComposerStagedTargetDrift { return .refused(error.detail) }
        catch let error as MessagesReplyComposerAXError {
            switch error {
            case .axFailure, .deadlineExpired: return .failed(error.description)
            default: return .refused(error.description)
            }
        } catch let error as MessagesAXNavigationError {
            let mapped = Self.replyError(from: error)
            switch mapped {
            case .axFailure, .deadlineExpired: return .failed(mapped.description)
            default: return .refused(mapped.description)
            }
        } catch _ as MessagesAXRouteDrift {
            return .refused(MessagesReplyComposerAXError.targetDrift.description)
        } catch {
            return .failed(MessagesReplyComposerAXError.axFailure.description)
        }
    }

    package func preflightNoUnsafeReplyState(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> String? {
        _ = try captureStartingDraftSafetyState(request, deadline: deadline)
        return nil
    }

    package func captureStartingDraftSafetyState(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerStartingState {
        try checkMessagesAXDeadline(deadline)
        guard driver.checkAccessibilityTrusted(prompt: false) else { throw MessagesReplyComposerAXError.accessibilityDenied }
        let normalPlaceholders = try driver.normalComposePlaceholders(deadline: deadline)
        let replyDescription = try driver.replyTranscriptDescription(deadline: deadline)
        let process = try driver.canonicalMessagesProcess(deadline: deadline)
        let snapshot = try navigator.captureWindowTranscript(process: process, deadline: deadline)
        guard try replyComposer(in: snapshot.window, replyDescription: replyDescription, deadline: deadline) == nil else {
            throw MessagesReplyComposerAXError.replyComposerExisting
        }
        let draft = try cleanNormalComposerProof(in: snapshot.window, normalPlaceholders: normalPlaceholders, deadline: deadline)
        try checkMessagesAXDeadline(deadline)
        return MessagesReplyComposerStartingState(process: process, window: snapshot.window, transcript: snapshot.transcript,
                                                  normalBody: draft.body, normalDraft: draft.evidence)
    }

    package func captureCleanReplyState(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerCleanState {
        try checkMessagesAXDeadline(deadline)
        guard driver.checkAccessibilityTrusted(prompt: false) else { throw MessagesReplyComposerAXError.accessibilityDenied }
        let normalPlaceholders = try driver.normalComposePlaceholders(deadline: deadline)
        let replyDescription = try driver.replyTranscriptDescription(deadline: deadline)
        let process = try driver.canonicalMessagesProcess(deadline: deadline)
        let snapshot = try navigator.captureWindowTranscript(process: process, deadline: deadline)
        guard try replyComposer(in: snapshot.window, replyDescription: replyDescription, deadline: deadline) == nil else {
            throw MessagesReplyComposerAXError.replyComposerExisting
        }
        let draft = try cleanNormalComposerProof(in: snapshot.window, normalPlaceholders: normalPlaceholders, deadline: deadline)
        try checkMessagesAXDeadline(deadline)
        return MessagesReplyComposerCleanState(process: process, window: snapshot.window, transcript: snapshot.transcript,
                                               normalBody: draft.body, normalDraft: draft.evidence)
    }

    package func verifyCleanReplyState(_ request: MessagesReplyComposerProbeRequest, original: MessagesReplyComposerStartingState, deadline: WorkerDeadline) throws -> String {
        let current = try captureCleanReplyState(request, deadline: deadline)
        guard current.process.identity == original.process.identity,
              current.window.sameIdentity(as: original.window),
              current.transcript.sameIdentity(as: original.transcript),
              current.normalBody.sameIdentity(as: original.normalBody) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard current.normalDraft == original.normalDraft else {
            throw MessagesReplyComposerAXError.replyComposerOriginalDraftDrift
        }
        return MessagesReplyComposerProbeDetail.verified
    }

    package func verifyNoUnsafeReplyState(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> String? {
        _ = try captureStartingDraftSafetyState(request, deadline: deadline)
        return nil
    }

    private static func replyError(from error: MessagesAXNavigationError) -> MessagesReplyComposerAXError {
        switch error {
        case .deadlineExpired: return .deadlineExpired
        case .targetDrift, .ambiguousSelectedMessage: return .targetDrift
        case .unknownAXValue: return .unknownAXValue
        case .traversalLimit: return .traversalLimit
        case .axFailure: return .axFailure
        }
    }

    private static func replyError(from error: MessagesAXRouteDrift) -> MessagesReplyComposerAXError {
        switch error.reason {
        case .relationshipCountChanged, .windowMismatch, .missingTranscript, .missingRetainedTarget,
             .replacedTranscript, .retainedTargetActionMissing, nil:
            return .targetDrift
        }
    }

    private func execute(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        var stage = MessagesReplyComposerAXStage.preflight
        do {
            try checkMessagesAXDeadline(deadline)
            guard driver.checkAccessibilityTrusted(prompt: false) else { return .refused(MessagesReplyComposerAXError.accessibilityDenied.description) }
            let titles = try driver.replyActionTitles(deadline: deadline)
            guard !titles.isEmpty else { throw MessagesReplyComposerAXError.unknownAXValue }
            let normalPlaceholders = try driver.normalComposePlaceholders(deadline: deadline)
            let replyDescription = try driver.replyTranscriptDescription(deadline: deadline)
            try refuseUnsafeExistingStateBeforeOpen(normalPlaceholders: normalPlaceholders,
                                                    replyDescription: replyDescription,
                                                    deadline: deadline)
            let targetURL = try NativeMessagesURL.message(messageGUID: request.messageGUID,
                                                          nativePartIndex: request.nativePartIndex,
                                                          nativePartGUID: request.nativePartGUID)
            stage = .open
            let process = try driver.openMessages(url: targetURL, deadline: deadline)
            stage = .postOpenSafety
            try refuseUnsafeExistingState(process: process, normalPlaceholders: normalPlaceholders,
                                          replyDescription: replyDescription, deadline: deadline)
            stage = .initialRoute
            let route = try navigator.captureInitialRoute(process: process, isTargetEligible: { element, deadline in
                try replyAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
            stage = .routeRevalidation
            try navigator.revalidate(route, isTargetEligible: { element, deadline in
                try replyAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
            guard try replyComposer(in: route.window, replyDescription: replyDescription, deadline: deadline) == nil else {
                throw MessagesReplyComposerAXError.replyComposerExisting
            }
            let originalDraft = try cleanNormalComposerProof(in: route.window, normalPlaceholders: normalPlaceholders, deadline: deadline)
            stage = .replyOpen
            guard let action = try replyAction(on: route.selected, titles: titles, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyActionUnavailable
            }
            try checkMessagesAXDeadline(deadline)
            try route.selected.performAction(named: action, deadline: deadline)
            try checkMessagesAXDeadline(deadline)
            stage = .composerReadiness
            let composer = try waitForOwnedComposer(route: route, titles: titles,
                                                    replyDescription: replyDescription, deadline: deadline)
            try validateOwnedComposer(composer, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: composer.body, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            stage = .cleanup
            let currentComposer = try revalidateOwnedComposer(route: route, original: composer, titles: titles,
                                                              replyDescription: replyDescription, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: currentComposer.body, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            guard try currentComposer.transcript.actions(deadline: deadline).contains("AXCancel") else {
                throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
            }
            let finalComposer = try revalidateOwnedComposer(route: route, original: composer, titles: titles,
                                                            replyDescription: replyDescription, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: finalComposer.body, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            let finalEvidence = try finalComposer.body.bodyValueEvidence(deadline: deadline)
            guard finalEvidence.provenEmpty else {
                throw finalEvidence.characterCount == nil ? MessagesReplyComposerAXError.replyComposerEvidenceUnavailable : MessagesReplyComposerAXError.replyComposerNotEmpty
            }
            guard finalEvidence == composer.evidence else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            try checkMessagesAXDeadline(deadline)
            try finalComposer.transcript.performAction(named: "AXCancel", deadline: deadline)
            stage = .verification
            try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription,
                              originalDraft: originalDraft, normalPlaceholders: normalPlaceholders,
                              deadline: deadline)
            return .ack(MessagesReplyComposerProbeDetail.verified)
        } catch let error as MessagesAXNavigationError {
            switch error {
            case .deadlineExpired:
                throw MessagesReplyComposerAXError.deadlineExpired
            case .axFailure:
                throw MessagesReplyComposerStagedAXFailure(stage: stage)
            case .targetDrift, .ambiguousSelectedMessage:
                throw MessagesReplyComposerStagedTargetDrift(stage: stage)
            case .unknownAXValue, .traversalLimit:
                throw Self.replyError(from: error)
            }
        } catch let error as MessagesReactionAXError {
            try Self.throwReplyCommonReactionError(error, stage: stage)
        } catch MessagesReplyComposerAXError.axFailure {
            throw MessagesReplyComposerStagedAXFailure(stage: stage)
        } catch MessagesReplyComposerAXError.targetDrift {
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        } catch _ as MessagesAXRouteDrift {
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        }
    }

    private func executeSend(_ request: MessagesReplySendRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        var stage = MessagesReplyComposerAXStage.preflight
        do {
            try checkMessagesAXDeadline(deadline)
            guard driver.checkAccessibilityTrusted(prompt: false) else { return .refused(MessagesReplyComposerAXError.accessibilityDenied.description) }
            let titles = try driver.replyActionTitles(deadline: deadline)
            guard !titles.isEmpty else { throw MessagesReplyComposerAXError.unknownAXValue }
            let normalPlaceholders = try driver.normalComposePlaceholders(deadline: deadline)
            let replyDescription = try driver.replyTranscriptDescription(deadline: deadline)
            try refuseUnsafeExistingStateBeforeOpen(normalPlaceholders: normalPlaceholders, replyDescription: replyDescription, deadline: deadline)
            let targetURL = try NativeMessagesURL.message(messageGUID: request.messageGUID,
                                                          nativePartIndex: request.nativePartIndex,
                                                          nativePartGUID: request.nativePartGUID)
            stage = .open
            let process = try driver.openMessages(url: targetURL, deadline: deadline)
            stage = .postOpenSafety
            try refuseUnsafeExistingState(process: process, normalPlaceholders: normalPlaceholders,
                                          replyDescription: replyDescription, deadline: deadline)
            stage = .initialRoute
            let route = try navigator.captureInitialRoute(process: process, isTargetEligible: { element, deadline in
                try replyAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
            stage = .routeRevalidation
            try navigator.revalidate(route, isTargetEligible: { element, deadline in
                try replyAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
            guard try replyComposer(in: route.window, replyDescription: replyDescription, deadline: deadline) == nil else {
                throw MessagesReplyComposerAXError.replyComposerExisting
            }
            let originalDraft = try cleanNormalComposerProof(in: route.window, normalPlaceholders: normalPlaceholders, deadline: deadline)
            stage = .replyOpen
            guard let action = try replyAction(on: route.selected, titles: titles, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyActionUnavailable
            }
            try route.selected.performAction(named: action, deadline: deadline)
            stage = .composerReadiness
            let composer = try waitForOwnedComposer(route: route, titles: titles, replyDescription: replyDescription, deadline: deadline)
            try validateOwnedComposer(composer, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: composer.body, window: route.window, deadline: deadline),
                  try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            stage = .cleanup
            var sendStarted = false
            do {
                try composer.body.setValue(request.text, deadline: deadline)
                let inserted = try revalidateComposerWithExpectedText(route: route, original: composer, expectedText: request.text,
                                                                      titles: titles, replyDescription: replyDescription, deadline: deadline)
                guard try inserted.transcript.actions(deadline: deadline).contains("AXCancel") else {
                    throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
                }
                let finalComposer = try revalidateComposerWithExpectedText(route: route, original: composer, expectedText: request.text,
                                                                           titles: titles, replyDescription: replyDescription, deadline: deadline)
                guard try bodyHasNoLocalAttachmentEvidence(in: finalComposer.body, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
                }
                guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
                }
                try validateAppRootFocus(route: route, composer: finalComposer, deadline: deadline)
                let finalSnapshot = try finalComposer.body.bodyTextSnapshot(deadline: deadline)
                guard finalSnapshot.text.utf8.elementsEqual(request.text.utf8) else {
                    throw MessagesReplyComposerAXError.replyComposerTextMismatch
                }
                stage = .verification
                sendStarted = true
                try sendReturnKey(pid_t(route.process.identity.pid), deadline)
                return try verifyAfterSend(route: route, originalComposer: composer, titles: titles,
                                           replyDescription: replyDescription, originalDraft: originalDraft,
                                           normalPlaceholders: normalPlaceholders, deadline: deadline)
            } catch {
                if !sendStarted {
                    var cleanupCancelStarted = false
                    try? clearAndCancelOwnedTextComposer(route: route, original: composer, expectedText: request.text,
                                                         titles: titles, replyDescription: replyDescription,
                                                         originalDraft: originalDraft, normalPlaceholders: normalPlaceholders,
                                                         deadline: deadline, cancelStarted: &cleanupCancelStarted)
                    if !cleanupCancelStarted {
                        try? cancelOwnedEmptyComposer(route: route, original: composer, titles: titles,
                                                      replyDescription: replyDescription, originalDraft: originalDraft,
                                                      normalPlaceholders: normalPlaceholders, deadline: deadline,
                                                      cancelStarted: &cleanupCancelStarted)
                    }
                }
                throw error
            }
        } catch let error as MessagesAXNavigationError {
            switch error {
            case .deadlineExpired: throw MessagesReplyComposerAXError.deadlineExpired
            case .axFailure: throw MessagesReplyComposerStagedAXFailure(stage: stage)
            case .targetDrift, .ambiguousSelectedMessage: throw MessagesReplyComposerStagedTargetDrift(stage: stage)
            case .unknownAXValue, .traversalLimit: throw Self.replyError(from: error)
            }
        } catch let error as MessagesReactionAXError {
            try Self.throwReplyCommonReactionError(error, stage: stage)
        } catch MessagesReplyComposerAXError.axFailure {
            throw MessagesReplyComposerStagedAXFailure(stage: stage)
        } catch MessagesReplyComposerAXError.targetDrift {
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        } catch _ as MessagesAXRouteDrift {
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        }
    }

    private struct ComposerSurface {
        let transcript: any MessagesAXElement
        let body: any MessagesAXElement
        let evidence: MessagesAXBodyValueEvidence
    }

    private struct NormalComposerProof {
        let body: any MessagesAXElement
        let evidence: MessagesAXBodyValueEvidence
    }

    private func refuseUnsafeExistingStateBeforeOpen(normalPlaceholders: [String], replyDescription: String?, deadline: WorkerDeadline) throws {
        guard let process = try? driver.canonicalMessagesProcess(deadline: deadline) else { return }
        try refuseUnsafeExistingState(process: process, normalPlaceholders: normalPlaceholders,
                                      replyDescription: replyDescription, deadline: deadline)
    }

    private func refuseUnsafeExistingState(process: MessagesAXProcess, normalPlaceholders: [String], replyDescription: String?, deadline: WorkerDeadline) throws {
        let windows = try process.root.directWindows(limit: maxChildren, deadline: deadline)
        guard windows.count <= 1 else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
        for window in windows {
            guard try window.role(deadline: deadline) == "AXWindow" else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
            if try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline) != nil {
                throw MessagesReplyComposerAXError.replyComposerExisting
            }
            try refuseUnsafeNormalComposerState(in: window, normalPlaceholders: normalPlaceholders, deadline: deadline)
            guard try hasNoLocalModalEvidence(in: window, window: window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
        }
    }

    private func refuseUnsafeNormalComposerState(in window: any MessagesAXElement, normalPlaceholders: [String], deadline: WorkerDeadline) throws {
        let fields = try bodyFields(in: window, window: window, deadline: deadline)
        guard fields.count <= 1 else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
        guard let body = fields.first else { return }
        _ = try cleanNormalComposerProof(body: body, in: window, normalPlaceholders: normalPlaceholders, deadline: deadline)
    }

    private func replyAction(on element: any MessagesAXElement, titles: [String], deadline: WorkerDeadline) throws -> String? {
        let matches = try element.actions(deadline: deadline).filter { action in
            titles.contains { MessagesAXActionMatcher.matches(action, title: $0) }
        }
        guard matches.count <= 1 else { throw MessagesReplyComposerAXError.unknownAXValue }
        return matches.first
    }

    private func cleanNormalComposerProof(in window: any MessagesAXElement, normalPlaceholders: [String], deadline: WorkerDeadline) throws -> NormalComposerProof {
        let fields = try bodyFields(in: window, window: window, deadline: deadline)
        guard fields.count == 1, let body = fields.first else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
        return try cleanNormalComposerProof(body: body, in: window, normalPlaceholders: normalPlaceholders, deadline: deadline)
    }

    private func cleanNormalComposerProof(body: any MessagesAXElement, in window: any MessagesAXElement,
                                          normalPlaceholders: [String], deadline: WorkerDeadline) throws -> NormalComposerProof {
        guard try body.enabled(deadline: deadline) == true,
              try body.valueSettable(deadline: deadline) == true,
              try body.focused(deadline: deadline) == true else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        let evidence = try body.bodyValueEvidence(deadline: deadline)
        guard let placeholder = evidence.placeholder,
              normalPlaceholders.contains(where: { $0.utf8.elementsEqual(placeholder.utf8) }) else {
            throw MessagesReplyComposerAXError.replyComposerOriginalDraftDrift
        }
        guard evidence.provenEmpty else {
            throw evidence.characterCount == nil ? MessagesReplyComposerAXError.replyComposerEvidenceUnavailable : MessagesReplyComposerAXError.replyComposerNotEmpty
        }
        guard try bodyHasNoLocalAttachmentEvidence(in: body, window: window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
        }
        guard try hasNoLocalModalEvidence(in: window, window: window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        let fresh = try body.bodyValueEvidence(deadline: deadline)
        guard let freshPlaceholder = fresh.placeholder,
              normalPlaceholders.contains(where: { $0.utf8.elementsEqual(freshPlaceholder.utf8) }) else {
            throw MessagesReplyComposerAXError.replyComposerOriginalDraftDrift
        }
        guard fresh.provenEmpty else {
            throw fresh.characterCount == nil ? MessagesReplyComposerAXError.replyComposerEvidenceUnavailable : MessagesReplyComposerAXError.replyComposerNotEmpty
        }
        return NormalComposerProof(body: body, evidence: fresh)
    }

    private func waitForOwnedComposer(route: MessagesAXRoute, titles: [String], replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        for attempt in 0...30 {
            try checkMessagesAXDeadline(deadline)
            if let composer = try currentOwnedComposer(route: route, titles: titles, replyDescription: replyDescription, deadline: deadline) {
                return composer
            }
            guard attempt < 30 else { throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable }
            readinessPause(min(50_000_000, cap - (now - started), deadline.remainingNanoseconds))
        }
        throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable
    }

    private func currentOwnedComposer(route: MessagesAXRoute, titles: [String], replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface? {
        let window = try retainedWindow(route: route, deadline: deadline)
        return try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline)
    }

    private func revalidateOwnedComposer(route: MessagesAXRoute, original: ComposerSurface, titles: [String], replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface {
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        let current = try currentOwnedComposer(route: route, titles: titles, replyDescription: replyDescription, deadline: deadline)
        guard let current,
              current.transcript.sameIdentity(as: original.transcript),
              current.body.sameIdentity(as: original.body) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        try validateOwnedComposer(current, deadline: deadline)
        guard current.evidence == original.evidence else {
            throw current.evidence.provenEmpty ? MessagesReplyComposerAXError.replyComposerOwnershipDrift : MessagesReplyComposerAXError.replyComposerNotEmpty
        }
        guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        return current
    }

    private func retainedWindow(route: MessagesAXRoute, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        try navigator.checkProcess(route.process, deadline: deadline)
        return try navigator.uniqueCurrentWindow(route, deadline: deadline)
    }

    private func restoredMainTranscriptIsPresent(in window: any MessagesAXElement, route: MessagesAXRoute, deadline: WorkerDeadline) throws -> Bool {
        let transcripts = try navigator.collect(from: window, window: window, deadline: deadline) { _, role, identifier in
            (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
        }
        let retained = transcripts.filter { $0.sameIdentity(as: route.transcript) }
        guard retained.count <= 1 else { throw MessagesReplyComposerAXError.replyComposerOwnershipDrift }
        guard retained.count == 1 else {
            guard transcripts.count <= 1 else { throw MessagesReplyComposerAXError.replyComposerOwnershipDrift }
            return false
        }
        guard transcripts.count == 1 else { throw MessagesReplyComposerAXError.replyComposerOwnershipDrift }
        return true
    }

    private func replyComposer(in window: any MessagesAXElement, replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface? {
        guard let replyDescription else { throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable }
        let transcripts = try navigator.collect(from: window, window: window, deadline: deadline) { element, role, identifier in
            guard (role == "AXGroup" || role == "AXCollection"), identifier == "TranscriptCollectionView" else { return false }
            return try element.axDescription(deadline: deadline)?.utf8.elementsEqual(replyDescription.utf8) ?? false
        }
        guard transcripts.count <= 1 else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
        guard let transcript = transcripts.first else { return nil }
        let fields = try bodyFields(in: window, window: window, deadline: deadline)
        guard fields.count == 1, let body = fields.first else { throw MessagesReplyComposerAXError.replyComposerAmbiguous }
        let evidence = try body.bodyValueEvidence(deadline: deadline)
        return ComposerSurface(transcript: transcript, body: body, evidence: evidence)
    }

    private func validateOwnedComposerControls(_ composer: ComposerSurface, deadline: WorkerDeadline) throws {
        guard try composer.body.enabled(deadline: deadline) == true,
              try composer.body.valueSettable(deadline: deadline) == true,
              try composer.body.focused(deadline: deadline) == true else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
    }

    private func revalidateComposerWithExpectedText(route: MessagesAXRoute, original: ComposerSurface, expectedText: String,
                                                    titles: [String], replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface {
        let current = try currentOwnedComposerAllowingText(route: route, titles: titles, replyDescription: replyDescription, deadline: deadline)
        guard let current, current.transcript.sameIdentity(as: original.transcript), current.body.sameIdentity(as: original.body) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        try validateOwnedComposerControls(current, deadline: deadline)
        guard try bodyHasNoLocalAttachmentEvidence(in: current.body, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
        }
        guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        let snapshot = try current.body.bodyTextSnapshot(deadline: deadline)
        guard snapshot.text.utf8.elementsEqual(expectedText.utf8) else {
            throw MessagesReplyComposerAXError.replyComposerTextMismatch
        }
        return current
    }

    private func currentOwnedComposerAllowingText(route: MessagesAXRoute, titles: [String], replyDescription: String?,
                                                  deadline: WorkerDeadline) throws -> ComposerSurface? {
        let window = try retainedWindow(route: route, deadline: deadline)
        guard let composer = try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline) else { return nil }
        guard !composer.transcript.sameIdentity(as: route.transcript),
              try restoredMainTranscriptIsPresent(in: window, route: route, deadline: deadline) == false else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        return composer
    }

    private func retainedOwnedComposer(route: MessagesAXRoute, original: ComposerSurface, titles: [String],
                                       replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface {
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard let current = try currentOwnedComposerAllowingText(route: route, titles: titles,
                                                                replyDescription: replyDescription, deadline: deadline),
              current.transcript.sameIdentity(as: original.transcript),
              current.body.sameIdentity(as: original.body) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        return current
    }

    private func validateAppRootFocus(route: MessagesAXRoute, composer: ComposerSurface, deadline: WorkerDeadline) throws {
        let window = try retainedWindow(route: route, deadline: deadline)
        guard window.sameIdentity(as: route.window) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard let bodyWindow = try composer.body.window(deadline: deadline), bodyWindow.sameIdentity(as: route.window) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard let focused = try driver.focusedElement(in: route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard try focused.processIdentifier(deadline: deadline) == route.process.identity.pid else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard let focusedWindow = try focused.window(deadline: deadline), focusedWindow.sameIdentity(as: route.window) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard focused.sameIdentity(as: composer.body) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        _ = try retainedWindow(route: route, deadline: deadline)
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        try validateOwnedComposerControls(composer, deadline: deadline)
    }

    private func finalOwnedEmptyComposerForCancel(route: MessagesAXRoute, original: ComposerSurface, titles: [String],
                                                  replyDescription: String?, deadline: WorkerDeadline) throws -> ComposerSurface {
        let current = try retainedOwnedComposer(route: route, original: original, titles: titles,
                                                replyDescription: replyDescription, deadline: deadline)
        try validateOwnedComposerControls(current, deadline: deadline)
        guard try bodyHasNoLocalAttachmentEvidence(in: current.body, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
        }
        guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        let snapshot = try current.body.bodyTextSnapshot(deadline: deadline)
        guard snapshot.provenEmpty else {
            throw MessagesReplyComposerAXError.replyComposerPossibleDraftRemains
        }
        return current
    }

    private func clearAndCancelOwnedTextComposer(route: MessagesAXRoute, original: ComposerSurface, expectedText: String,
                                                 titles: [String], replyDescription: String?, originalDraft: NormalComposerProof,
                                                 normalPlaceholders: [String], deadline: WorkerDeadline,
                                                 cancelStarted: inout Bool) throws {
        let transcript = try retainedOwnedComposer(route: route, original: original, titles: titles,
                                                   replyDescription: replyDescription, deadline: deadline).transcript
        guard try transcript.actions(deadline: deadline).contains("AXCancel") else {
            throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
        }
        let composer = try revalidateComposerWithExpectedText(route: route, original: original, expectedText: expectedText,
                                                              titles: titles, replyDescription: replyDescription, deadline: deadline)
        try composer.body.setValue("", deadline: deadline)
        let emptyTranscript = try retainedOwnedComposer(route: route, original: original, titles: titles,
                                                        replyDescription: replyDescription, deadline: deadline).transcript
        guard try emptyTranscript.actions(deadline: deadline).contains("AXCancel") else {
            throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
        }
        let empty = try finalOwnedEmptyComposerForCancel(route: route, original: original, titles: titles,
                                                         replyDescription: replyDescription, deadline: deadline)
        cancelStarted = true
        try empty.transcript.performAction(named: "AXCancel", deadline: deadline)
        try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription, originalDraft: originalDraft,
                          normalPlaceholders: normalPlaceholders, deadline: deadline)
    }

    private func cancelOwnedEmptyComposer(route: MessagesAXRoute, original: ComposerSurface, titles: [String], replyDescription: String?,
                                          originalDraft: NormalComposerProof, normalPlaceholders: [String], deadline: WorkerDeadline,
                                          cancelStarted: inout Bool) throws {
        let transcript = try retainedOwnedComposer(route: route, original: original, titles: titles,
                                                   replyDescription: replyDescription, deadline: deadline).transcript
        guard try transcript.actions(deadline: deadline).contains("AXCancel") else {
            throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
        }
        let empty = try finalOwnedEmptyComposerForCancel(route: route, original: original, titles: titles,
                                                         replyDescription: replyDescription, deadline: deadline)
        cancelStarted = true
        try empty.transcript.performAction(named: "AXCancel", deadline: deadline)
        try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription, originalDraft: originalDraft,
                          normalPlaceholders: normalPlaceholders, deadline: deadline)
    }

    private func verifyAfterSend(route: MessagesAXRoute, originalComposer: ComposerSurface, titles: [String], replyDescription: String?,
                                 originalDraft: NormalComposerProof, normalPlaceholders: [String], deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        var retainedNonemptyObserved = false
        for attempt in 0...30 {
            try checkMessagesAXDeadline(deadline)
            do {
                try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription,
                                  originalDraft: originalDraft, normalPlaceholders: normalPlaceholders, deadline: deadline)
                return .ack(MessagesReplySendACKDetail.alreadyRestoredVerified)
            } catch MessagesReplyComposerAXError.replyComposerCleanupFailed {
            }
            let window = try retainedWindow(route: route, deadline: deadline)
            if let composer = try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline),
               composer.transcript.sameIdentity(as: originalComposer.transcript),
               composer.body.sameIdentity(as: originalComposer.body) {
                try validateOwnedComposerControls(composer, deadline: deadline)
                guard try bodyHasNoLocalAttachmentEvidence(in: composer.body, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
                }
                guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
                }
                let snapshot = try composer.body.bodyTextSnapshot(deadline: deadline)
                if snapshot.provenEmpty {
                    let transcript = try retainedOwnedComposer(route: route, original: originalComposer, titles: titles,
                                                               replyDescription: replyDescription, deadline: deadline).transcript
                    guard try transcript.actions(deadline: deadline).contains("AXCancel") else {
                        throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
                    }
                    let empty = try finalOwnedEmptyComposerForCancel(route: route, original: originalComposer, titles: titles,
                                                                     replyDescription: replyDescription, deadline: deadline)
                    try empty.transcript.performAction(named: "AXCancel", deadline: deadline)
                    try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription,
                                      originalDraft: originalDraft, normalPlaceholders: normalPlaceholders, deadline: deadline)
                    return .ack(MessagesReplySendACKDetail.retainedEmptyCancelledVerified)
                }
                retainedNonemptyObserved = true
            }
            guard attempt < 30 else {
                throw retainedNonemptyObserved ? MessagesReplyComposerAXError.replyComposerPossibleDraftRemains : MessagesReplyComposerAXError.replyComposerCleanupFailed
            }
            let now = readinessNow()
            guard now >= started, now - started < cap else {
                throw retainedNonemptyObserved ? MessagesReplyComposerAXError.replyComposerPossibleDraftRemains : MessagesReplyComposerAXError.replyComposerCleanupFailed
            }
            readinessPause(min(50_000_000, cap - (now - started), deadline.remainingNanoseconds))
        }
        throw retainedNonemptyObserved ? MessagesReplyComposerAXError.replyComposerPossibleDraftRemains : MessagesReplyComposerAXError.replyComposerCleanupFailed
    }

    private func bodyFields(in root: any MessagesAXElement, window: any MessagesAXElement, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try navigator.collect(from: root, window: window, deadline: deadline) { _, role, identifier in
            role == "AXTextField" && identifier == "messageBodyField"
        }
    }

    private func validateOwnedComposer(_ composer: ComposerSurface, deadline: WorkerDeadline) throws {
        guard try composer.body.enabled(deadline: deadline) == true,
              try composer.body.valueSettable(deadline: deadline) == true,
              try composer.body.focused(deadline: deadline) == true else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard composer.evidence.provenEmpty else {
            throw composer.evidence.characterCount == nil ? MessagesReplyComposerAXError.replyComposerEvidenceUnavailable : MessagesReplyComposerAXError.replyComposerNotEmpty
        }
    }

    private func bodyHasNoLocalAttachmentEvidence(in body: any MessagesAXElement, window: any MessagesAXElement, deadline: WorkerDeadline) throws -> Bool {
        func isAttachmentEvidence(_ element: any MessagesAXElement) throws -> Bool {
            let role = try element.role(deadline: deadline)
            if role == "AXImage" { return true }
            guard let identifier = try element.identifier(deadline: deadline) else { return false }
            let lower = identifier.lowercased()
            return lower.contains("attachment") || lower.contains("filetransfer")
        }
        let children = try body.children(limit: maxChildren, deadline: deadline)
        guard children.count <= maxChildren else { throw MessagesAXNavigationError.traversalLimit }
        let remaining = maxChildren - children.count
        let linked = try body.linkedElements(limit: remaining, deadline: deadline)
        guard linked.count <= remaining else { throw MessagesAXNavigationError.traversalLimit }
        for candidate in children + linked {
            guard let owner = try candidate.window(deadline: deadline), owner.sameIdentity(as: window) else {
                throw MessagesAXRouteDrift(.windowMismatch)
            }
            if try isAttachmentEvidence(candidate) { return false }
        }
        return true
    }

    private func hasNoLocalModalEvidence(in root: any MessagesAXElement, window: any MessagesAXElement, deadline: WorkerDeadline) throws -> Bool {
        let matches = try navigator.collect(from: root, window: window, deadline: deadline) { element, role, _ in
            if role == "AXSheet" || role == "AXDialog" { return true }
            return try element.subrole(deadline: deadline) == "AXDialog"
        }
        return matches.isEmpty
    }

    private func verifyCleanup(route: MessagesAXRoute, titles: [String], replyDescription: String?, originalDraft: NormalComposerProof,
                               normalPlaceholders: [String], deadline: WorkerDeadline) throws {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        for attempt in 0...30 {
            try checkMessagesAXDeadline(deadline)
            let window = try retainedWindow(route: route, deadline: deadline)
            if try restoredMainTranscriptIsPresent(in: window, route: route, deadline: deadline),
               try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline) == nil {
                let fresh = try cleanNormalComposerProof(in: window, normalPlaceholders: normalPlaceholders, deadline: deadline)
                guard fresh.body.sameIdentity(as: originalDraft.body),
                      fresh.evidence == originalDraft.evidence else {
                    throw MessagesReplyComposerAXError.replyComposerOriginalDraftDrift
                }
                return
            }
            guard attempt < 30 else { throw MessagesReplyComposerAXError.replyComposerCleanupFailed }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesReplyComposerAXError.replyComposerCleanupFailed }
            readinessPause(min(50_000_000, cap - (now - started), deadline.remainingNanoseconds))
        }
        throw MessagesReplyComposerAXError.replyComposerCleanupFailed
    }
}
