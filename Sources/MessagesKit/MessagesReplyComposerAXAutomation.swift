import ApplicationServices
import Foundation
import AppleKit

package enum MessagesReplyComposerProbeDetail {
    package static let verified = "no-send-empty-owned-composer-closed-verified"
    package static let attachmentDraftVerified = "no-send-exact-attachment-draft-closed-verified"
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
    case replyAttachmentClipboardDrift = "reply-attachment-clipboard-drift"
    case replyAttachmentLayoutDrift = "reply-attachment-layout-drift"
    case replyAttachmentDraftUnverified = "reply-attachment-draft-unverified"
    case targetDrift = "target-drift"
    case traversalLimit = "traversal-limit"
    case unknownAXValue = "unknown-ax-value"

    var description: String { rawValue }
}

/// Fixed structural diagnostics only: no AX values, identifiers, or action names.
private enum ReplyAttachmentOwnershipReason: String, Error {
    case transcriptCount = "transcript-count"
    case replyTranscript = "reply-transcript"
    case transcriptProcess = "transcript-process"
    case mainTranscript = "main-transcript"
    case childTranscriptDrift = "child-transcript-drift"
    case bodyMainLinkMissing = "body-main-link-missing"
    case mainTargetMissing = "main-target-missing"
    case mainTargetProcess = "main-target-process"
    case mainTargetActionMissing = "main-target-action-missing"
    case other
}

private struct ReplyAttachmentOwnershipFailure: Error {
    enum Phase: String {
        case beforePaste = "before-paste"
        case afterPaste = "after-paste"
        case beforeReturn = "before-return"
        case returnStarted = "return-started"
        case afterReturn = "after-return"
    }
    let phase: Phase
    let reason: ReplyAttachmentOwnershipReason
    var detail: String { "reply-attachment-ownership-\(phase.rawValue)-\(reason.rawValue)" }
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
    private let clipboardFactory: () -> any MessagesClipboarding
    private let pasteKeyResolver: any MessagesPasteKeyResolving
    private let sendPasteKey: (pid_t, UInt16, WorkerDeadline) throws -> Void
    private let allowedAttachmentDraftMarkers: Set<String>

    init(driver: any MessagesReplyComposerAXDriving = LiveMessagesReplyComposerAXDriver(),
                 maxTraversalNodes: Int = 2_048, maxTraversalDepth: Int = 32, maxChildren: Int = 256,
                 readinessNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 readinessPause: @escaping (UInt64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) },
                 sendReturnKey: @escaping (pid_t, WorkerDeadline) throws -> Void = { pid, deadline in
                     let presser = LiveMessagesPairedKeyPresser(pid: pid)
                     do { try presser.pressReturn(flags: .cleared, deadline: deadline) }
                     catch MessagesPairedKeyPressError.deadlineExpired { throw MessagesReplyComposerAXError.deadlineExpired }
                     catch { throw MessagesReplyComposerAXError.axFailure }
                 },
                 clipboardFactory: @escaping () -> any MessagesClipboarding = { LiveMessagesClipboard() },
                 pasteKeyResolver: any MessagesPasteKeyResolving = LiveMessagesPasteKeyResolver(),
                 allowedAttachmentDraftMarkers: Set<String> = ["\u{fffc}\n"],
                 sendPasteKey: @escaping (pid_t, UInt16, WorkerDeadline) throws -> Void = { pid, keyCode, deadline in
                     let presser = LiveMessagesPairedKeyPresser(pid: pid)
                     do { try presser.press(CGKeyCode(keyCode), flags: .explicit(CGEventFlags.maskCommand.rawValue), deadline: deadline) }
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
        self.clipboardFactory = clipboardFactory
        self.pasteKeyResolver = pasteKeyResolver
        self.sendPasteKey = sendPasteKey
        self.allowedAttachmentDraftMarkers = allowedAttachmentDraftMarkers
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
        catch let error as ReplyAttachmentOwnershipFailure { return .refused(error.detail) }
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
        if request.phase == "replyAttachmentDraftInspect" { return try executeAttachmentDraftInspect(request, deadline: deadline) }
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



    private func executeAttachmentDraftInspect(_ request: MessagesReplyComposerProbeRequest, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        guard let attachment = request.attachmentDraft else { throw MessagesReplyComposerAXError.invalidPayload }
        var stage = MessagesReplyComposerAXStage.preflight
        var clipboardOwnerCount: Int?
        var originalClipboard: MessagesClipboardSnapshot?
        var publishedURL: URL?
        var activeClipboard: (any MessagesClipboarding)?
        do {
            let copyURL = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
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
            let composer = try waitForOwnedComposer(route: route, titles: titles,
                                                    replyDescription: replyDescription, deadline: deadline)
            try validateOwnedComposer(composer, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: composer.body, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            let clipboard = clipboardFactory()
            activeClipboard = clipboard
            let layoutBefore = try pasteKeyResolver.resolvePasteKey(deadline: deadline)
            let originalSnapshot = try clipboard.snapshot(deadline: deadline)
            originalClipboard = originalSnapshot
            let cleared = try clipboard.clearContentsReturningCount(deadline: deadline)
            clipboardOwnerCount = cleared
            try clipboard.verifyEmpty(ownerCount: cleared, deadline: deadline)
            publishedURL = copyURL
            do {
                let published = try clipboard.publishAndVerifyFileURL(copyURL, ownerCount: cleared, deadline: deadline)
                clipboardOwnerCount = published
            } catch {
                if let current = try? clipboard.snapshot(deadline: deadline),
                   current.changeCount == cleared, current.isExactFileURLPayload(copyURL) {
                    clipboardOwnerCount = current.changeCount
                }
                throw error
            }
            let layoutAfter = try pasteKeyResolver.resolvePasteKey(deadline: deadline)
            guard layoutAfter == layoutBefore else { throw MessagesReplyComposerAXError.replyAttachmentLayoutDrift }
            _ = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
            let finalComposer = try revalidateOwnedComposer(route: route, original: composer, titles: titles,
                                                            replyDescription: replyDescription, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: finalComposer.body, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            try validateAppRootFocus(route: route, composer: finalComposer, deadline: deadline)
            let finalEvidence = try finalComposer.body.bodyValueEvidence(deadline: deadline)
            guard finalEvidence.provenEmpty, finalEvidence == composer.evidence else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            guard let ownerCount = clipboardOwnerCount else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
            try clipboard.verifyOwnedPayload(ownerCount: ownerCount, url: copyURL, deadline: deadline)
            try sendPasteKey(route.process.identity.pid, layoutBefore.keyCode, deadline)
            let afterPaste = try retainedOwnedComposer(route: route, original: composer, titles: titles,
                                                       replyDescription: replyDescription, deadline: deadline)
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            _ = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
            guard try afterPaste.transcript.actions(deadline: deadline).contains("AXCancel") else {
                throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
            }
            try validateExactAttachmentDraft(in: afterPaste.body, route: route, expectedCopyPath: copyURL.path, deadline: deadline)
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            try afterPaste.transcript.performAction(named: "AXCancel", deadline: deadline)
            stage = .verification
            try verifyCleanup(route: route, titles: titles, replyDescription: replyDescription,
                              originalDraft: originalDraft, normalPlaceholders: normalPlaceholders, deadline: deadline)
            try restoreClipboardIfOwned(clipboard: clipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline)
            return .ack(MessagesReplyComposerProbeDetail.attachmentDraftVerified)
        } catch let error as MessagesAXNavigationError {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            switch error {
            case .deadlineExpired: throw MessagesReplyComposerAXError.deadlineExpired
            case .axFailure: throw MessagesReplyComposerStagedAXFailure(stage: stage)
            case .targetDrift, .ambiguousSelectedMessage: throw MessagesReplyComposerStagedTargetDrift(stage: stage)
            case .unknownAXValue, .traversalLimit: throw Self.replyError(from: error)
            }
        } catch let error as MessagesReactionAXError {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            try Self.throwReplyCommonReactionError(error, stage: stage)
        } catch MessagesReplyComposerAXError.axFailure {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            throw MessagesReplyComposerStagedAXFailure(stage: stage)
        } catch MessagesReplyComposerAXError.targetDrift {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        } catch _ as MessagesAXRouteDrift {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            throw MessagesReplyComposerStagedTargetDrift(stage: stage)
        } catch {
            if let activeClipboard { try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard, ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline) }
            throw error
        }
    }

    private func restoreClipboardIfOwned(clipboard: any MessagesClipboarding, original: MessagesClipboardSnapshot?, ownerCount: Int?, url: URL?, deadline: WorkerDeadline) throws {
        guard let original, let ownerCount else { return }
        let current = try clipboard.snapshot(deadline: deadline)
        let ownedState = current.changeCount == ownerCount && (current.isEmptyAtCount || url.map { current.isExactFileURLPayload($0) } == true)
        guard ownedState else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
        try clipboard.restore(original, deadline: deadline)
    }

    private func validateExactAttachmentDraft(in body: any MessagesAXElement, route: MessagesAXRoute,
                                              expectedCopyPath: String, deadline: WorkerDeadline) throws {
        let children = try body.children(limit: 16, deadline: deadline)
        let linked = try body.linkedElements(limit: max(0, 16 - children.count), deadline: deadline)
        let candidates = try (children + linked).filter { element in
            guard let owner = try element.window(deadline: deadline), owner.sameIdentity(as: route.window) else {
                throw MessagesAXRouteDrift(.windowMismatch)
            }
            guard try element.processIdentifier(deadline: deadline) == route.process.identity.pid else {
                throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
            }
            let role = try element.role(deadline: deadline)
            let identifier = try element.identifier(deadline: deadline)?.lowercased()
            return role == "AXImage" || identifier?.contains("attachment") == true || identifier?.contains("filetransfer") == true
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
        }
        let snapshot = try body.bodyTextSnapshot(deadline: deadline)
        if !snapshot.text.isEmpty {
            guard snapshot.text.unicodeScalars.allSatisfy({ $0.value == 0xfffc }) else {
                throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
            }
        }
        var exact = false
        for name in ["AXURL", "AXDocument"] {
            do {
                if let url = try candidate.fileURLAttribute(named: name, deadline: deadline) {
                    if url.standardizedFileURL.path == expectedCopyPath { exact = true }
                }
            } catch {
                throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
            }
        }
        for name in ["AXPath", "AXFilePath"] {
            if let value = try candidate.stringAttribute(named: name, deadline: deadline), !value.isEmpty {
                guard value.hasPrefix("/") else { throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified }
                if URL(fileURLWithPath: value).standardizedFileURL.path == expectedCopyPath { exact = true }
            }
        }
        guard exact else { throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified }
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
            if let attachmentDraft = request.attachmentDraft {
                return try executeAttachmentSendAfterComposerOpen(attachmentDraft, route: route, composer: composer,
                                                                  titles: titles, replyDescription: replyDescription,
                                                                  originalDraft: originalDraft, normalPlaceholders: normalPlaceholders,
                                                                  stage: &stage, deadline: deadline)
            }
            guard let text = request.text else { throw MessagesReplyComposerAXError.invalidPayload }
            var sendStarted = false
            do {
                try composer.body.setValue(text, deadline: deadline)
                let inserted = try revalidateComposerWithExpectedText(route: route, original: composer, expectedText: text,
                                                                      titles: titles, replyDescription: replyDescription, deadline: deadline)
                guard try inserted.transcript.actions(deadline: deadline).contains("AXCancel") else {
                    throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
                }
                let finalComposer = try revalidateComposerWithExpectedText(route: route, original: composer, expectedText: text,
                                                                           titles: titles, replyDescription: replyDescription, deadline: deadline)
                guard try bodyHasNoLocalAttachmentEvidence(in: finalComposer.body, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
                }
                guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                    throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
                }
                try validateAppRootFocus(route: route, composer: finalComposer, deadline: deadline)
                let finalSnapshot = try finalComposer.body.bodyTextSnapshot(deadline: deadline)
                guard finalSnapshot.text.utf8.elementsEqual(text.utf8) else {
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
                    try? clearAndCancelOwnedTextComposer(route: route, original: composer, expectedText: text,
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


    private func executeAttachmentSendAfterComposerOpen(_ attachment: MessagesReplyAttachmentDraftEvidence,
                                                        route: MessagesAXRoute, composer: ComposerSurface,
                                                        titles: [String], replyDescription: String?,
                                                        originalDraft: NormalComposerProof, normalPlaceholders: [String],
                                                        stage: inout MessagesReplyComposerAXStage,
                                                        deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
        var activeClipboard: (any MessagesClipboarding)?
        var originalClipboard: MessagesClipboardSnapshot?
        var clipboardOwnerCount: Int?
        var publishedURL: URL?
        var sendStarted = false
        var ownershipPhase = ReplyAttachmentOwnershipFailure.Phase.beforePaste
        do {
            let emptyComposer = try revalidateOwnedComposer(route: route, original: composer, titles: titles,
                                                            replyDescription: replyDescription, deadline: deadline)
            let ownership = try captureAttachmentComposerOwnership(route: route, composer: emptyComposer,
                                                                    titles: titles, deadline: deadline)
            let copyURL = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
            let layoutBefore = try pasteKeyResolver.resolvePasteKey(deadline: deadline)
            let clipboard = clipboardFactory()
            activeClipboard = clipboard
            originalClipboard = try clipboard.snapshot(deadline: deadline)
            let cleared = try clipboard.clearContentsReturningCount(deadline: deadline)
            clipboardOwnerCount = cleared
            try clipboard.verifyEmpty(ownerCount: cleared, deadline: deadline)
            publishedURL = copyURL
            do {
                let published = try clipboard.publishAndVerifyFileURL(copyURL, ownerCount: cleared, deadline: deadline)
                clipboardOwnerCount = published
            } catch {
                if let current = try? clipboard.snapshot(deadline: deadline),
                   current.changeCount == cleared, current.isExactFileURLPayload(copyURL) {
                    clipboardOwnerCount = current.changeCount
                }
                throw error
            }
            let finalComposer = try revalidateOwnedComposer(route: route, original: composer, titles: titles,
                                                            replyDescription: replyDescription, deadline: deadline)
            guard try bodyHasNoLocalAttachmentEvidence(in: finalComposer.body, window: route.window, deadline: deadline),
                  try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerAttachmentEvidence
            }
            try validateAttachmentComposerOwnership(ownership, in: route.window, route: route,
                                                     composer: finalComposer, titles: titles, deadline: deadline)
            try validateAppRootFocus(route: route, composer: finalComposer, deadline: deadline)
            guard let ownerCount = clipboardOwnerCount else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
            try clipboard.verifyOwnedPayload(ownerCount: ownerCount, url: copyURL, deadline: deadline)
            guard try pasteKeyResolver.resolvePasteKey(deadline: deadline) == layoutBefore else {
                throw MessagesReplyComposerAXError.replyAttachmentLayoutDrift
            }
            try sendPasteKey(route.process.identity.pid, layoutBefore.keyCode, deadline)
            ownershipPhase = .afterPaste
            let afterPaste = try retainedOwnedComposer(route: route, original: composer, titles: titles,
                                                       replyDescription: replyDescription, attachmentOwnership: ownership,
                                                       deadline: deadline)
            guard try afterPaste.transcript.actions(deadline: deadline).contains("AXCancel") else {
                throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
            }
            _ = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
            try validateAttachmentDraftReadyForSend(in: afterPaste, route: route, deadline: deadline)
            guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            try validateAppRootFocus(route: route, composer: afterPaste, deadline: deadline)
            try restoreClipboardIfOwned(clipboard: clipboard, original: originalClipboard, ownerCount: clipboardOwnerCount,
                                        url: publishedURL, deadline: deadline)
            activeClipboard = nil
            ownershipPhase = .beforeReturn
            try validateAttachmentBeforeReturn(attachment, ownership: ownership, route: route, composer: composer,
                                               titles: titles, replyDescription: replyDescription, deadline: deadline)
            stage = .verification
            sendStarted = true
            ownershipPhase = .returnStarted
            try checkMessagesAXDeadline(deadline)
            try sendReturnKey(pid_t(route.process.identity.pid), deadline)
            ownershipPhase = .afterReturn
            return try verifyAfterSend(route: route, originalComposer: composer, titles: titles,
                                       replyDescription: replyDescription, originalDraft: originalDraft,
                                       normalPlaceholders: normalPlaceholders, attachmentOwnership: ownership, deadline: deadline)
        } catch {
            if !sendStarted {
                var cleanupCancelStarted = false
                // The native attachment marker cannot prove which file is present.
                // Preserve every nonempty draft, including possible user replacement.
                try? cancelOwnedEmptyComposer(route: route, original: composer, titles: titles,
                                               replyDescription: replyDescription, originalDraft: originalDraft,
                                               normalPlaceholders: normalPlaceholders, deadline: deadline,
                                               cancelStarted: &cleanupCancelStarted)
                if let activeClipboard {
                    try? restoreClipboardIfOwned(clipboard: activeClipboard, original: originalClipboard,
                                                 ownerCount: clipboardOwnerCount, url: publishedURL, deadline: deadline)
                }
            }
            if let reason = error as? ReplyAttachmentOwnershipReason {
                throw ReplyAttachmentOwnershipFailure(phase: ownershipPhase, reason: reason)
            }
            if let error = error as? MessagesReplyComposerAXError, error == .replyComposerOwnershipDrift {
                throw ReplyAttachmentOwnershipFailure(phase: ownershipPhase, reason: .other)
            }
            throw error
        }
    }

    private func validateAttachmentDraftReadyForSend(in composer: ComposerSurface, route: MessagesAXRoute,
                                                     deadline: WorkerDeadline) throws {
        guard !allowedAttachmentDraftMarkers.isEmpty else { throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified }
        let snapshot = try composer.body.bodyTextSnapshot(deadline: deadline)
        guard allowedAttachmentDraftMarkers.contains(where: { $0.utf8.elementsEqual(snapshot.text.utf8) }) else {
            throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
        }
        // Native Messages may expose only the marker, with no attachment child.
        // This is readiness evidence; exact file identity is verified from the sent DB row.
        let children = try composer.body.children(limit: 16, deadline: deadline)
        let linked = try composer.body.linkedElements(limit: max(0, 16 - children.count), deadline: deadline)
        var attachments = 0
        for element in children + linked {
            guard let owner = try element.window(deadline: deadline), owner.sameIdentity(as: route.window) else {
                throw MessagesAXRouteDrift(.windowMismatch)
            }
            guard try element.processIdentifier(deadline: deadline) == route.process.identity.pid else {
                throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
            }
            let role = try element.role(deadline: deadline)
            let identifier = try element.identifier(deadline: deadline)?.lowercased()
            if role == "AXImage" || identifier?.contains("attachment") == true || identifier?.contains("filetransfer") == true {
                attachments += 1
            } else {
                guard (role == "AXGroup" || role == "AXCollection"), identifier == "transcriptcollectionview",
                      element.sameIdentity(as: route.transcript) || element.sameIdentity(as: composer.transcript) else {
                    throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
                }
            }
        }
        guard attachments <= 1 else { throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified }
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
        let windows: [any MessagesAXElement]
        do {
            windows = try navigator.conversationWindows(process: process, deadline: deadline)
        } catch is MessagesAXRouteDrift {
            throw MessagesReplyComposerAXError.replyComposerAmbiguous
        }
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
                                                  attachmentOwnership: AttachmentComposerOwnership? = nil, deadline: WorkerDeadline) throws -> ComposerSurface? {
        let window = try retainedWindow(route: route, deadline: deadline)
        guard let composer = try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline) else { return nil }
        guard !composer.transcript.sameIdentity(as: route.transcript) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        if let attachmentOwnership {
            try validateAttachmentComposerOwnership(attachmentOwnership, in: window, route: route, composer: composer,
                                                     titles: titles, deadline: deadline)
        } else if try restoredMainTranscriptIsPresent(in: window, route: route, deadline: deadline) {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        return composer
    }

    private enum AttachmentMainVisibility {
        case child, graphOnly, absent
    }

    // Captured only from the exact, newly opened, empty attachment reply.
    // Parent chains are observed ownership evidence, not an atomic UI lock.
    private struct AttachmentComposerOwnership {
        let bodyChain: [any MessagesAXElement]
        let replyChain: [any MessagesAXElement]
        let mainTranscript: any MessagesAXElement
        let initialMainVisibility: AttachmentMainVisibility
    }

    private func attachmentParentChain(from element: any MessagesAXElement, route: MessagesAXRoute,
                                       deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        var chain: [any MessagesAXElement] = []
        var next = element
        for _ in 0..<16 {
            try checkMessagesAXDeadline(deadline)
            guard !chain.contains(where: { $0.sameIdentity(as: next) }),
                  try next.processIdentifier(deadline: deadline) == route.process.identity.pid else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            chain.append(next)
            if next.sameIdentity(as: route.window) { return chain }
            guard let window = try next.window(deadline: deadline), window.sameIdentity(as: route.window),
                  let parent = try next.parent(deadline: deadline) else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            let children = try parent.children(limit: maxChildren, deadline: deadline)
            guard children.count <= maxChildren,
                  children.filter({ $0.sameIdentity(as: next) }).count == 1 else {
                throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
            }
            next = parent
        }
        throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
    }

    private func sameChain(_ lhs: [any MessagesAXElement], _ rhs: [any MessagesAXElement]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.sameIdentity(as: $1) }
    }

    private func captureAttachmentComposerOwnership(route: MessagesAXRoute, composer: ComposerSurface,
                                                    titles: [String], deadline: WorkerDeadline) throws -> AttachmentComposerOwnership {
        try validateOwnedComposer(composer, deadline: deadline)
        let bodyChain = try attachmentParentChain(from: composer.body, route: route, deadline: deadline)
        let replyChain = try attachmentParentChain(from: composer.transcript, route: route, deadline: deadline)
        let visibility = try validateAttachmentReplyTranscripts(in: route.window, route: route, composer: composer,
                                                               titles: titles, deadline: deadline)
        let ownership = AttachmentComposerOwnership(bodyChain: bodyChain, replyChain: replyChain,
                                                     mainTranscript: route.transcript, initialMainVisibility: visibility)
        try validateAttachmentParentChains(ownership, route: route, composer: composer, deadline: deadline)
        // Capture may span several AX reads; require the composer still be empty.
        guard try composer.body.bodyTextSnapshot(deadline: deadline).provenEmpty else {
            throw MessagesReplyComposerAXError.replyComposerNotEmpty
        }
        return ownership
    }

    private func validateAttachmentParentChains(_ ownership: AttachmentComposerOwnership, route: MessagesAXRoute,
                                                composer: ComposerSurface, deadline: WorkerDeadline) throws {
        guard ownership.mainTranscript.sameIdentity(as: route.transcript),
              sameChain(ownership.bodyChain, try attachmentParentChain(from: composer.body, route: route, deadline: deadline)),
              sameChain(ownership.replyChain, try attachmentParentChain(from: composer.transcript, route: route, deadline: deadline)) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
    }

    private func validateAttachmentComposerOwnership(_ ownership: AttachmentComposerOwnership, in window: any MessagesAXElement,
                                                     route: MessagesAXRoute, composer: ComposerSurface, titles: [String],
                                                     deadline: WorkerDeadline) throws {
        try validateAttachmentParentChains(ownership, route: route, composer: composer, deadline: deadline)
        // Native Messages may change among all three visibility modes after paste.
        // Every mode uses the same retained ancestry and current topology guards.
        _ = try validateAttachmentReplyTranscripts(in: window, route: route, composer: composer,
                                                   titles: titles, deadline: deadline)
        try validateAttachmentParentChains(ownership, route: route, composer: composer, deadline: deadline)
    }

    private func validateAttachmentReplyTranscripts(in window: any MessagesAXElement, route: MessagesAXRoute,
                                                    composer: ComposerSurface, titles: [String],
                                                    deadline: WorkerDeadline) throws -> AttachmentMainVisibility {
        let transcripts = try navigator.collect(from: window, window: window, deadline: deadline) { _, role, identifier in
            (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
        }
        guard (1...2).contains(transcripts.count) else { throw ReplyAttachmentOwnershipReason.transcriptCount }
        guard transcripts.filter({ $0.sameIdentity(as: composer.transcript) }).count == 1 else {
            throw ReplyAttachmentOwnershipReason.replyTranscript
        }
        for transcript in transcripts {
            guard try transcript.processIdentifier(deadline: deadline) == route.process.identity.pid else {
                throw ReplyAttachmentOwnershipReason.transcriptProcess
            }
            guard transcript.sameIdentity(as: composer.transcript) || transcript.sameIdentity(as: route.transcript) else {
                throw ReplyAttachmentOwnershipReason.mainTranscript
            }
        }
        let children = try navigator.collect(from: window, window: window, traversalPolicy: .childrenOnly,
                                             deadline: deadline) { element, role, identifier in
            element.sameIdentity(as: composer.body) ||
                ((role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView")
        }
        guard children.filter({ $0.sameIdentity(as: composer.body) }).count == 1,
              children.filter({ $0.sameIdentity(as: composer.transcript) }).count == 1 else {
            throw ReplyAttachmentOwnershipReason.replyTranscript
        }
        let childTranscripts = children.filter { !$0.sameIdentity(as: composer.body) }
        guard childTranscripts.allSatisfy({ child in transcripts.contains { $0.sameIdentity(as: child) } }) else {
            throw ReplyAttachmentOwnershipReason.childTranscriptDrift
        }
        let linked = try composer.body.linkedElements(limit: maxChildren, deadline: deadline)
        guard linked.count <= 1,
              try composer.body.relationshipCount(.linkedElements, limit: maxChildren, deadline: deadline) == .available(linked.count) else {
            throw ReplyAttachmentOwnershipReason.bodyMainLinkMissing
        }
        if let main = linked.first {
            guard main.sameIdentity(as: route.transcript),
                  transcripts.contains(where: { $0.sameIdentity(as: main) }),
                  try main.processIdentifier(deadline: deadline) == route.process.identity.pid,
                  let owner = try main.window(deadline: deadline), owner.sameIdentity(as: window) else {
                throw ReplyAttachmentOwnershipReason.bodyMainLinkMissing
            }
        }
        guard childTranscripts.contains(where: { $0.sameIdentity(as: route.transcript) }) else {
            return transcripts.contains(where: { $0.sameIdentity(as: route.transcript) }) ? .graphOnly : .absent
        }
        let targets = try navigator.collect(from: route.transcript, window: window, deadline: deadline) { element, _, _ in
            element.sameIdentity(as: route.selected)
        }
        guard targets.count == 1, let target = targets.first else { throw ReplyAttachmentOwnershipReason.mainTargetMissing }
        guard try target.processIdentifier(deadline: deadline) == route.process.identity.pid else {
            throw ReplyAttachmentOwnershipReason.mainTargetProcess
        }
        guard try replyAction(on: target, titles: titles, deadline: deadline) != nil else {
            throw ReplyAttachmentOwnershipReason.mainTargetActionMissing
        }
        return .child
    }

    private func validateAttachmentBeforeReturn(_ attachment: MessagesReplyAttachmentDraftEvidence,
                                                ownership: AttachmentComposerOwnership, route: MessagesAXRoute,
                                                composer: ComposerSurface, titles: [String], replyDescription: String?,
                                                deadline: WorkerDeadline) throws {
        let current = try retainedOwnedComposer(route: route, original: composer, titles: titles,
                                                replyDescription: replyDescription, attachmentOwnership: ownership,
                                                deadline: deadline)
        _ = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline)
        guard try hasNoLocalModalEvidence(in: route.window, window: route.window, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        try validateAttachmentDraftReadyForSend(in: current, route: route, deadline: deadline)
        try validateAttachmentParentChains(ownership, route: route, composer: current, deadline: deadline)
        try validateOwnedComposerControls(current, deadline: deadline)
        // Finish process/window traversal BEFORE the last focus read. There is no
        // atomic AX/key-event transaction; persisted target verification is required.
        _ = try retainedWindow(route: route, deadline: deadline)
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline),
              let focused = try driver.focusedElement(in: route.process, deadline: deadline),
              focused.sameIdentity(as: current.body),
              try focused.processIdentifier(deadline: deadline) == route.process.identity.pid,
              let window = try focused.window(deadline: deadline), window.sameIdentity(as: route.window) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        // A local text read is still necessary: focus lookup itself may race
        // with typing. This does not walk children, links, or parent chains.
        let finalSnapshot = try current.body.bodyTextSnapshot(deadline: deadline)
        guard allowedAttachmentDraftMarkers.contains(where: { $0.utf8.elementsEqual(finalSnapshot.text.utf8) }) else {
            throw MessagesReplyComposerAXError.replyAttachmentDraftUnverified
        }
        try checkMessagesAXDeadline(deadline)
    }

    private func retainedOwnedComposer(route: MessagesAXRoute, original: ComposerSurface, titles: [String],
                                       replyDescription: String?, attachmentOwnership: AttachmentComposerOwnership? = nil,
                                       deadline: WorkerDeadline) throws -> ComposerSurface {
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReplyComposerAXError.replyComposerOwnershipDrift
        }
        guard let current = try currentOwnedComposerAllowingText(route: route, titles: titles,
                                                                replyDescription: replyDescription,
                                                                attachmentOwnership: attachmentOwnership,
                                                                deadline: deadline),
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
                                                  replyDescription: String?, attachmentOwnership: AttachmentComposerOwnership? = nil,
                                                  deadline: WorkerDeadline) throws -> ComposerSurface {
        let current = try retainedOwnedComposer(route: route, original: original, titles: titles,
                                                replyDescription: replyDescription, attachmentOwnership: attachmentOwnership, deadline: deadline)
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
                                 originalDraft: NormalComposerProof, normalPlaceholders: [String],
                                 attachmentOwnership: AttachmentComposerOwnership? = nil, deadline: WorkerDeadline) throws -> MessagesReplyComposerAXOutcome {
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
                                                               replyDescription: replyDescription, attachmentOwnership: attachmentOwnership, deadline: deadline).transcript
                    guard try transcript.actions(deadline: deadline).contains("AXCancel") else {
                        throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable
                    }
                    let empty = try finalOwnedEmptyComposerForCancel(route: route, original: originalComposer, titles: titles,
                                                                     replyDescription: replyDescription, attachmentOwnership: attachmentOwnership, deadline: deadline)
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
            if try replyComposer(in: window, replyDescription: replyDescription, deadline: deadline) == nil,
               try restoredMainTranscriptIsPresent(in: window, route: route, deadline: deadline) {
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
