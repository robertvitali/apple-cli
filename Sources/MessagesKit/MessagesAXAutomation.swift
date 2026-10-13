import ApplicationServices
import AppKit
import Carbon.HIToolbox.Events
import Foundation
import AppleKit

enum MessagesReactionStandard: String, Codable, Equatable, Sendable {
    case heart, thumbsUp, thumbsDown, ha, exclamation, questionMark
}

enum MessagesReaction: Codable, Equatable, Sendable {
    case standard(MessagesReactionStandard)
    case custom(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.standard(let left), .standard(let right)): return left == right
        case (.custom(let left), .custom(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case standard, custom }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.standard) != container.contains(.custom) else {
            throw MessagesReactionAXError.invalidPayload
        }
        if container.contains(.standard) {
            self = .standard(try container.decode(MessagesReactionStandard.self, forKey: .standard))
        } else {
            self = .custom(try container.decode(String.self, forKey: .custom))
        }
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .standard(let value): try container.encode(value, forKey: .standard)
        case .custom(let value): try container.encode(value, forKey: .custom)
        }
    }

    func validate() throws {
        if case .custom(let value) = self {
            guard value.utf8.count <= 128, value.count == 1, Self.isEmoji(value) else {
                throw MessagesReactionAXError.invalidPayload
            }
        }
    }

    // Conservative emoji-sequence grammar over the original scalars. In
    // particular, isEmoji alone would incorrectly admit bare ASCII digits.
    private static func isEmoji(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        let codes = scalars.map(\.value)
        func regional(_ scalar: UInt32) -> Bool { (0x1F1E6...0x1F1FF).contains(scalar) }
        if codes.count == 2, codes.allSatisfy(regional) { return true }
        if let first = codes.first, first == 35 || first == 42 || (48...57).contains(first) {
            return codes == [first, 0x20E3] || codes == [first, 0xFE0F, 0x20E3]
        }
        // The three standardized subdivision flags, including the cancel tag.
        if codes.first == 0x1F3F4, codes.count > 1, codes[1] >= 0xE0000 {
            return ["gbeng", "gbsct", "gbwls"].contains { region in
                codes == [0x1F3F4] + region.unicodeScalars.map { $0.value + 0xE0000 } + [0xE007F]
            }
        }
        var index = 0
        while index < scalars.count {
            let base = scalars[index]
            guard base.properties.isEmoji, base.value > 127,
                  !base.properties.isEmojiModifier, !regional(base.value) else { return false }
            index += 1
            if index < codes.count, codes[index] == 0xFE0F || codes[index] == 0xFE0E { index += 1 }
            if index < scalars.count, scalars[index].properties.isEmojiModifier {
                guard base.properties.isEmojiModifierBase else { return false }
                index += 1
            }
            if index == scalars.count { return true }
            guard codes[index] == 0x200D, index + 1 < codes.count else { return false }
            index += 1
        }
        return false
    }

    var pickerIdentifier: String {
        switch self {
        case .standard(let value): value.rawValue
        case .custom(let value): value
        }
    }
}

struct MessagesReactionRequest: Equatable, Sendable {
    let operation: MessagesReactionWorkerPayload.Operation
    let chatGUID: String
    let messageGUID: String
    let nativePartIndex: Int
    // Optional native part address p:<index>/<messageGUID>, never an attachment GUID.
    let nativePartGUID: String?
    let reaction: MessagesReaction
    let experimentalUIHandoff: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operation == rhs.operation && lhs.chatGUID.utf8.elementsEqual(rhs.chatGUID.utf8) &&
            lhs.messageGUID.utf8.elementsEqual(rhs.messageGUID.utf8) &&
            lhs.nativePartIndex == rhs.nativePartIndex &&
            lhs.nativePartGUID.map { Array($0.utf8) } == rhs.nativePartGUID.map { Array($0.utf8) } &&
            lhs.reaction == rhs.reaction &&
            lhs.experimentalUIHandoff == rhs.experimentalUIHandoff
    }

    init(operation: MessagesReactionWorkerPayload.Operation, chatGUID: String,
         messageGUID: String, nativePartIndex: Int, nativePartGUID: String?,
         reaction: MessagesReaction, experimentalUIHandoff: Bool = false) throws {
        try NativeMessagesURL.validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex,
                                       nativePartGUID: nativePartGUID)
        guard !chatGUID.isEmpty, chatGUID.utf8.count <= 512,
              !chatGUID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MessagesReactionAXError.invalidPayload
        }
        try reaction.validate()
        self.operation = operation
        self.chatGUID = chatGUID
        self.messageGUID = messageGUID
        self.nativePartIndex = nativePartIndex
        self.nativePartGUID = nativePartGUID
        self.reaction = reaction
        self.experimentalUIHandoff = experimentalUIHandoff
    }
}

enum MessagesReactionAXOutcome: Equatable {
    case ack(String), refused(String), failed(String)
}


enum MessagesReactionACKDetail {
    static let verificationSource = "ui_selected_state_and_database_identity"

    static func verified(operation: MessagesReactionWorkerPayload.Operation, changed: Bool) -> String {
        switch (operation, changed) {
        case (.set, true): return "reaction-set-changed-verified"
        case (.set, false): return "reaction-set-unchanged-verified"
        case (.remove, true): return "reaction-remove-changed-verified"
        case (.remove, false): return "reaction-remove-unchanged-verified"
        }
    }
}

enum MessagesTargetDriftReason: String {
    case relationshipCountChanged = "relationship-count-changed"
    case windowMismatch = "window-mismatch"
    case pickerMismatch = "picker-mismatch"
    case buttonMismatch = "button-mismatch"
    case selectedStateChanged = "selected-state-changed"
    case pickerStillPresent = "picker-still-present"
    case missingTranscript = "missing-transcript"
    case missingRetainedMessage = "missing-retained-message"
    case replacedTranscript = "replaced-transcript"
    case retainedMessageActionMissing = "retained-message-action-missing"
}

struct MessagesTargetDrift: Error {
    let reason: MessagesTargetDriftReason?

    init(_ reason: MessagesTargetDriftReason? = nil) {
        self.reason = reason
    }
}

private enum MessagesVerificationPath: String {
    case exactExisting = "exact-existing"
    case customChooser = "custom-chooser"
}

private enum MessagesVerificationFailureKind: String {
    case discoveryDrift = "discovery-drift"
    case validationDrift = "validation-drift"
    case desiredStateMismatch = "desired-state-mismatch"
}

private struct MessagesVerificationFailure: Error {
    let path: MessagesVerificationPath
    let kind: MessagesVerificationFailureKind
    let reason: MessagesTargetDriftReason?

    var detail: String {
        let base = "\(path.rawValue)-verify-\(kind.rawValue)"
        guard let reason else { return base }
        return "\(base)-\(reason.rawValue)"
    }
}

enum MessagesReactionAXError: String, Error, CustomStringConvertible, CaseIterable {
    case invalidPayload = "invalid-payload"
    case deadlineExpired = "deadline-expired"
    case targetDrift = "target-drift"
    case ambiguousSelectedMessage = "ambiguous-selected-message"
    case pickerUnavailable = "picker-unavailable"
    case reactionUnavailable = "reaction-unavailable"
    case unknownAXValue = "unknown-ax-value"
    case traversalLimit = "traversal-limit"
    case axFailure = "ax-failure"
    case postPressWindowDrift = "post-press-window-drift"
    case postPressPickerIdentityDrift = "post-press-picker-identity-drift"
    case postPressButtonIdentityDrift = "post-press-button-identity-drift"
    case postPressSelectedUnknown = "post-press-selected-unknown"
    case postPressSelectionTimeout = "post-press-selection-timeout"
    case pickerCancelPickerUnavailable = "picker-cancel-picker-unavailable"
    case pickerCancelIdentityDrift = "picker-cancel-identity-drift"
    case pickerCancelUnavailable = "picker-cancel-unavailable"
    case pickerDismissalWindowDrift = "picker-dismissal-window-drift"
    case pickerDismissalPickerIdentityDrift = "picker-dismissal-picker-identity-drift"
    case pickerDismissalTimeout = "picker-dismissal-timeout"
    case postPressVerifyOpenDrift = "post-press-verify-open-drift"
    case postPressVerifyRouteDrift = "post-press-verify-route-drift"
    case postPressVerifyActionMissing = "post-press-verify-action-missing"
    case postPressVerifyPickerStateDrift = "post-press-verify-picker-state-drift"
    case customChooserPostSelectionUnselected = "custom-chooser-post-selection-unselected"
    var description: String { rawValue }
}

private func checkDeadline(_ deadline: WorkerDeadline) throws {
    guard !deadline.expired else { throw MessagesReactionAXError.deadlineExpired }
}

struct MessagesCustomEmojiSearchPlan: Equatable {
    let query: String
    let position: Int
    let supportsSkinToneVariants: Bool
}

enum MessagesCustomEmojiChooserKey: Equatable {
    case downArrow
    case rightArrow
    case returnKey
}

protocol MessagesReactionAXDriving: MessagesAXProcessDriving {
    func reactActionTitles(deadline: WorkerDeadline) throws -> [String]
    func customEmojiSearchPlan(for emoji: String, deadline: WorkerDeadline) throws -> MessagesCustomEmojiSearchPlan
    func pressCustomEmojiChooserKey(_ key: MessagesCustomEmojiChooserKey, process: MessagesAXProcess, deadline: WorkerDeadline) throws
    func detachedCustomEmojiPopover(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
}
struct MessagesReactionActionTitleResolver {
    var baseTitle: (WorkerDeadline) throws -> String?
    var fullTitle: (WorkerDeadline) throws -> String?

    init(baseTitle: @escaping (WorkerDeadline) throws -> String?,
         fullTitle: @escaping (WorkerDeadline) throws -> String?) {
        self.baseTitle = baseTitle
        self.fullTitle = fullTitle
    }

    func resolve(deadline: WorkerDeadline) throws -> [String] {
        try Self.canonicalize([try fullTitle(deadline), try baseTitle(deadline)].compactMap { $0 })
    }

    static func canonicalize(_ rawTitles: [String]) throws -> [String] {
        var titles: [String] = []
        for title in rawTitles {
            guard Self.valid(title) else { throw MessagesReactionAXError.unknownAXValue }
            if !titles.contains(where: { $0.utf8.elementsEqual(title.utf8) }) {
                titles.append(title)
            }
        }
        guard titles.count <= 2 else { throw MessagesReactionAXError.unknownAXValue }
        return titles
    }

    static func valid(_ title: String) -> Bool {
        !title.isEmpty && title.utf8.count <= 256 && title.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func live() -> Self {
        Self(
            baseTitle: { deadline in
                try checkDeadline(deadline)
                return localizedString(
                    bundlePath: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle",
                    key: "acknowledgments.action.title", table: "Accessibility")
            },
            fullTitle: { deadline in
                try checkDeadline(deadline)
                return localizedString(
                    bundlePath: "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework",
                    key: "TAPBACK_DETAILS_ELLIPSIS", table: "ChatKit")
            })
    }

    private static func localizedString(bundlePath: String, key: String, table: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let title = bundle.localizedString(forKey: key, value: nil, table: table)
        guard title != key, !title.isEmpty else { return nil }
        return title
    }
}
struct MessagesReactionAXAutomation {
    let driver: any MessagesReactionAXDriving
    let maxTraversalNodes: Int
    let maxTraversalDepth: Int
    let maxChildren: Int
    private let readinessNow: () -> UInt64
    private let readinessPause: (UInt64) -> Void

    init(driver: any MessagesReactionAXDriving = LiveMessagesReactionAXDriver(),
         maxTraversalNodes: Int = 2_048, maxTraversalDepth: Int = 32, maxChildren: Int = 256,
         readinessNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         readinessPause: @escaping (UInt64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }) {
        self.driver = driver
        self.maxTraversalNodes = maxTraversalNodes
        self.maxTraversalDepth = maxTraversalDepth
        self.maxChildren = maxChildren
        self.readinessNow = readinessNow
        self.readinessPause = readinessPause
    }

    private typealias Route = MessagesAXRoute
    private enum PostPressPickerState {
        case present
        case absent
    }
    private enum PickerResolution {
        case exact(any MessagesAXElement, any MessagesAXElement, Bool)
        case customChooserChanged((any MessagesAXElement)?)
    }
    private enum RetainedRouteDiscovery {
        case available(Route)
        case unavailable(MessagesTargetDriftReason)
    }
    private struct CustomEmojiCandidate {
        let element: any MessagesAXElement
        let actions: [String]
    }
    private enum AXFailureStage: String {
        case preflight = "ax-failure-preflight"
        case open = "ax-failure-open"
        case initialRoute = "ax-failure-initial-route"
        case menuOpen = "ax-failure-menu-open"
        case pickerReadiness = "ax-failure-picker-readiness"
        case prePress = "ax-failure-pre-press"
        case press = "ax-failure-press"
        case postPress = "ax-failure-post-press"
        case cleanup = "ax-failure-cleanup"
        case verification = "ax-failure-verification"

        var targetDriftComponent: String {
            String(rawValue.dropFirst("ax-failure-".count))
        }
    }
    private struct StagedAXFailure: Error {
        let stage: AXFailureStage
    }
    private struct StagedTargetDrift: Error {
        let stage: AXFailureStage
        let reason: MessagesTargetDriftReason?

        var detail: String {
            let base = "target-drift-\(stage.targetDriftComponent)"
            guard let reason else { return base }
            return "\(base)-\(reason.rawValue)"
        }
    }
    private enum CustomChooserAXFailurePhase: String {
        case pickerRead = "picker-read"
        case existingButton = "existing-button"
        case routeValidation = "route-validation"
        case launchDiscovery = "launch-discovery"
        case query
        case preexistingCheck = "preexisting-check"
        case launchRevalidation = "launch-revalidation"
        case launchPress = "launch-press"
        case detachedDiscovery = "detached-discovery"
        case popover
        case searchDiscovery = "search-discovery"
        case searchPrecondition = "search-precondition"
        case searchWrite = "search-write"
        case searchReadback = "search-readback"
        case candidateWait = "candidate-wait"
        case candidateRead = "candidate-read"
        case candidateRevalidation = "candidate-revalidation"
        case candidatePress = "candidate-press"
        case postSelection = "post-selection"
    }
    private struct CustomChooserAXFailure: Error {
        let phase: CustomChooserAXFailurePhase
        var detail: String { "ax-failure-custom-chooser-\(phase.rawValue)" }
    }
    private struct CustomChooserReactionUnavailable: Error {
        let phase: CustomChooserAXFailurePhase
        var detail: String { "reaction-unavailable-custom-chooser-\(phase.rawValue)" }
    }

    private var navigator: MessagesAXNavigator {
        MessagesAXNavigator(driver: driver, maxTraversalNodes: maxTraversalNodes,
                            maxTraversalDepth: maxTraversalDepth, maxChildren: maxChildren,
                            readinessNow: readinessNow, readinessPause: readinessPause)
    }

    func apply(_ request: MessagesReactionRequest, deadline: WorkerDeadline) throws -> MessagesReactionAXOutcome {
        do { return try execute(request, deadline: deadline) }
        catch let error as StagedAXFailure { return .failed(error.stage.rawValue) }
        catch let error as StagedTargetDrift { return .refused(error.detail) }
        catch let error as CustomChooserAXFailure { return .failed(error.detail) }
        catch let error as CustomChooserReactionUnavailable { return .refused(error.detail) }
        catch let error as MessagesVerificationFailure { return .refused(error.detail) }
        catch let error as MessagesAXNavigationError {
            let reactionError = Self.reactionError(from: error)
            if reactionError == .deadlineExpired || reactionError == .axFailure { return .failed(reactionError.description) }
            return .refused(reactionError.description)
        }
        catch let error as MessagesReactionAXError {
            if error == .deadlineExpired || error == .axFailure { return .failed(error.description) }
            return .refused(error.description)
        } catch {
            // Never echo AX values or native errors containing target data.
            return .failed("ax-failure")
        }
    }

    private func execute(_ request: MessagesReactionRequest, deadline: WorkerDeadline) throws -> MessagesReactionAXOutcome {
        var stage = AXFailureStage.preflight
        do {
            try checkDeadline(deadline)
            guard driver.checkAccessibilityTrusted(prompt: false) else { return .refused("accessibility-denied") }
            let titles = try MessagesReactionActionTitleResolver.canonicalize(driver.reactActionTitles(deadline: deadline))
            guard !titles.isEmpty else { throw MessagesReactionAXError.unknownAXValue }
            try checkDeadline(deadline)
            let targetURL = try NativeMessagesURL.message(messageGUID: request.messageGUID,
                                                          nativePartIndex: request.nativePartIndex,
                                                          nativePartGUID: request.nativePartGUID)
            stage = .open
            let process = try driver.openMessages(url: targetURL, deadline: deadline)
            stage = .initialRoute
            let route = try captureInitialRoute(process: process, titles: titles, deadline: deadline)
            try revalidate(route, titles: titles, deadline: deadline)
            guard let action = try reactAction(on: route.selected, titles: titles, deadline: deadline) else {
                throw MessagesReactionAXError.targetDrift
            }
            try checkDeadline(deadline)
            stage = .menuOpen
            try route.selected.performAction(named: action, deadline: deadline)
            try checkDeadline(deadline)

            stage = .pickerReadiness
            let resolution = try waitForPickerButtonOrCustomChooser(route: route, titles: titles,
                                                                    request: request, deadline: deadline)
            if case .customChooserChanged(let picker) = resolution {
                if let picker {
                    stage = .cleanup
                    try cancelOwnedPicker(route: route, titles: titles, picker: picker,
                                          experimentalUIHandoff: request.experimentalUIHandoff, deadline: deadline)
                }
                stage = .verification
                try verifyRetainedStateAfterPickerDismissal(request: request, titles: titles,
                                                            originalRoute: route, desiredSelected: true,
                                                            path: .customChooser, deadline: deadline)
                return .ack(MessagesReactionACKDetail.verified(operation: request.operation, changed: true))
            }
            guard case .exact(let picker, let button, let initialSelected) = resolution else {
                throw MessagesReactionAXError.reactionUnavailable
            }
            stage = .prePress
            let selected = try validatePostMenuPicker(route: route, titles: titles, picker: picker, button: button,
                                                      initialSelected: initialSelected,
                                                      identifier: request.reaction.pickerIdentifier,
                                                      experimentalUIHandoff: request.experimentalUIHandoff,
                                                      deadline: deadline)
            let desiredSelected = request.operation == .set
            if selected == desiredSelected {
                stage = .cleanup
                try cancelOwnedPicker(route: route, titles: titles, picker: picker,
                                      experimentalUIHandoff: request.experimentalUIHandoff, deadline: deadline)
                return .ack(MessagesReactionACKDetail.verified(operation: request.operation, changed: false))
            }
            guard try button.actions(deadline: deadline).contains("AXPress") else {
                throw MessagesReactionAXError.reactionUnavailable
            }
            try settleExactPickerBeforePress(request: request, route: route, titles: titles,
                                             picker: picker, button: button,
                                             initialSelected: initialSelected,
                                             deadline: deadline)
            // Last route validation is after picker traversal as well. Public AX is
            // not atomic: external UI interference remains an experimental limitation.
            _ = try validatePostMenuPicker(route: route, titles: titles, picker: picker, button: button,
                                           initialSelected: initialSelected,
                                           identifier: request.reaction.pickerIdentifier,
                                           experimentalUIHandoff: request.experimentalUIHandoff,
                                           deadline: deadline)
            guard try button.actions(deadline: deadline).contains("AXPress") else {
                throw MessagesReactionAXError.targetDrift
            }
            try checkDeadline(deadline)
            stage = .press
            try button.performAction(named: "AXPress", deadline: deadline)
            try checkDeadline(deadline)
            stage = .postPress
            let postPressPickerState = try waitForRetainedButtonSelectionAfterPress(route: route, picker: picker, button: button,
                                                                                    identifier: request.reaction.pickerIdentifier,
                                                                                    desiredSelected: desiredSelected, deadline: deadline)
            if postPressPickerState == .present {
                stage = .cleanup
                try cancelOwnedPicker(route: route, titles: titles, picker: picker,
                                      experimentalUIHandoff: request.experimentalUIHandoff, deadline: deadline)
                return .ack(MessagesReactionACKDetail.verified(operation: request.operation, changed: true))
            }
            stage = .verification
            try verifyRetainedStateAfterPickerDismissal(request: request, titles: titles,
                                                        originalRoute: route, desiredSelected: desiredSelected,
                                                        path: .exactExisting, deadline: deadline)
            return .ack(MessagesReactionACKDetail.verified(operation: request.operation, changed: true))
        } catch let error as CustomChooserAXFailure {
            throw error
        } catch let error as CustomChooserReactionUnavailable {
            throw error
        } catch let error as MessagesAXNavigationError {
            switch error {
            case .axFailure:
                throw StagedAXFailure(stage: stage)
            case .targetDrift:
                throw StagedTargetDrift(stage: stage, reason: nil)
            default:
                throw Self.reactionError(from: error)
            }
        } catch MessagesReactionAXError.axFailure {
            throw StagedAXFailure(stage: stage)
        } catch MessagesReactionAXError.targetDrift {
            throw StagedTargetDrift(stage: stage, reason: nil)
        } catch let error as MessagesTargetDrift {
            throw StagedTargetDrift(stage: stage, reason: error.reason)
        } catch let error as MessagesAXRouteDrift {
            throw StagedTargetDrift(stage: stage, reason: Self.targetDriftReason(from: error.reason))
        } catch let error as MessagesVerificationFailure {
            throw error
        } catch let error as MessagesReactionAXError {
            throw error
        } catch {
            // Never expose native AX transport errors or values.
            throw StagedAXFailure(stage: stage)
        }
    }

    private static func reactionError(from error: MessagesAXNavigationError) -> MessagesReactionAXError {
        switch error {
        case .deadlineExpired: return .deadlineExpired
        case .targetDrift: return .targetDrift
        case .ambiguousSelectedMessage: return .ambiguousSelectedMessage
        case .unknownAXValue: return .unknownAXValue
        case .traversalLimit: return .traversalLimit
        case .axFailure: return .axFailure
        }
    }

    private static func targetDriftReason(from reason: MessagesAXRouteDriftReason?) -> MessagesTargetDriftReason? {
        guard let reason else { return nil }
        switch reason {
        case .relationshipCountChanged: return .relationshipCountChanged
        case .windowMismatch: return .windowMismatch
        case .missingTranscript: return .missingTranscript
        case .missingRetainedTarget: return .missingRetainedMessage
        case .replacedTranscript: return .replacedTranscript
        case .retainedTargetActionMissing: return .retainedMessageActionMissing
        }
    }

    private static func targetDrift(from error: MessagesAXRouteDrift) -> MessagesTargetDrift {
        MessagesTargetDrift(targetDriftReason(from: error.reason))
    }

    static func matchesAction(_ action: String, title: String) -> Bool {
        let prefix = Array("Name:\(title)".utf8)
        let bytes = Array(action.utf8)
        return bytes == prefix || (bytes.starts(with: prefix) && bytes.dropFirst(prefix.count).first == 10)
    }

    private func reactAction(on element: any MessagesAXElement, titles: [String],
                             deadline: WorkerDeadline) throws -> String? {
        try checkDeadline(deadline)
        let matches = try element.actions(deadline: deadline).filter { action in
            titles.contains { Self.matchesAction(action, title: $0) }
        }
        guard matches.count <= 1 else { throw MessagesReactionAXError.unknownAXValue }
        return matches.first
    }

    private func captureRoute(process: MessagesAXProcess, titles: [String], deadline: WorkerDeadline) throws -> Route {
        try navigator.captureRoute(process: process, isTargetEligible: { element, deadline in
            try reactAction(on: element, titles: titles, deadline: deadline) != nil
        }, deadline: deadline)
    }

    private func captureInitialRoute(process: MessagesAXProcess, titles: [String], deadline: WorkerDeadline) throws -> Route {
        do {
            return try navigator.captureInitialRoute(process: process, isTargetEligible: { element, deadline in
                try reactAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
        } catch MessagesReactionAXError.deadlineExpired {
            try checkDeadline(deadline)
            throw MessagesAXNavigationError.targetDrift
        }
    }

    private func checkProcess(_ expected: MessagesAXProcess, deadline: WorkerDeadline) throws {
        try navigator.checkProcess(expected, deadline: deadline)
    }

    private func revalidate(_ route: Route, titles: [String], deadline: WorkerDeadline) throws {
        try navigator.revalidate(route, isTargetEligible: { element, deadline in
            try reactAction(on: element, titles: titles, deadline: deadline) != nil
        }, deadline: deadline)
    }
    private func verificationFailure(_ path: MessagesVerificationPath, _ kind: MessagesVerificationFailureKind, _ reason: MessagesTargetDriftReason? = nil) -> MessagesVerificationFailure {
        MessagesVerificationFailure(path: path, kind: kind, reason: reason)
    }

    private func waitForRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                          originalRoute: Route, deadline: WorkerDeadline) throws -> Route {
        let started = readinessNow()
        let cap: UInt64 = 8_000_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(8_000)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        var lastUnavailableReason: MessagesTargetDriftReason?
        for attempt in 0...160 {
            try checkDeadline(deadline)
            if readDeadline.expired {
                if let lastUnavailableReason { throw MessagesTargetDrift(lastUnavailableReason) }
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            switch try availableRetainedRouteAfterPickerDismissal(process: process, titles: titles,
                                                                  originalRoute: originalRoute,
                                                                  requirePickerAbsent: false,
                                                                  deadline: readDeadline) {
            case .available(let route):
                return route
            case .unavailable(let reason):
                lastUnavailableReason = reason
            }
            guard attempt < 160 else {
                if let lastUnavailableReason { throw MessagesTargetDrift(lastUnavailableReason) }
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            let now = readinessNow()
            guard now >= started, now - started < cap else {
                if let lastUnavailableReason { throw MessagesTargetDrift(lastUnavailableReason) }
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            let pause = min(50_000_000, cap - (now - started), readDeadline.remainingNanoseconds)
            readinessPause(pause)
        }
        if let lastUnavailableReason { throw MessagesTargetDrift(lastUnavailableReason) }
        throw MessagesReactionAXError.postPressVerifyRouteDrift
    }

    private func requireRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                          originalRoute: Route, deadline: WorkerDeadline) throws -> Route {
        switch try availableRetainedRouteAfterPickerDismissal(process: process, titles: titles,
                                                              originalRoute: originalRoute,
                                                              requirePickerAbsent: true,
                                                              deadline: deadline) {
        case .available(let route):
            return route
        case .unavailable(let reason):
            throw MessagesTargetDrift(reason)
        }
    }

    private func availableRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                            originalRoute: Route, requirePickerAbsent: Bool,
                                                            deadline: WorkerDeadline) throws -> RetainedRouteDiscovery {
        let currentWindow = try uniqueCurrentWindow(originalRoute, deadline: deadline)
        let picker = try availablePicker(in: currentWindow, deadline: deadline)
        if requirePickerAbsent, picker != nil { throw MessagesTargetDrift(.pickerStillPresent) }
        do {
            let discovery = try navigator.retainedRouteDiscovery(process: process, originalRoute: originalRoute,
                                                                 isTargetEligible: { element, deadline in
                try reactAction(on: element, titles: titles, deadline: deadline) != nil
            }, deadline: deadline)
            switch discovery {
            case .available(let route):
                return .available(route)
            case .unavailable(let reason):
                let reactionReason = Self.targetDriftReason(from: reason) ?? .relationshipCountChanged
                if picker != nil, reason == .missingTranscript { return .unavailable(.pickerStillPresent) }
                return .unavailable(reactionReason)
            }
        } catch let error as MessagesAXRouteDrift {
            throw Self.targetDrift(from: error)
        } catch MessagesAXNavigationError.targetDrift {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        } catch MessagesAXNavigationError.ambiguousSelectedMessage {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        }
    }

    private func waitForRetainedButtonSelectionAfterPress(route: Route, picker: any MessagesAXElement,
                                                          button: any MessagesAXElement, identifier: String,
                                                          desiredSelected: Bool, deadline: WorkerDeadline) throws -> PostPressPickerState {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(1_500)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        for attempt in 0..<31 {
            try checkDeadline(deadline)
            if readDeadline.expired { throw MessagesReactionAXError.postPressSelectionTimeout }
            let window: any MessagesAXElement
            do {
                window = try uniqueCurrentWindow(route, deadline: readDeadline)
            } catch MessagesReactionAXError.targetDrift {
                throw MessagesReactionAXError.postPressWindowDrift
            } catch _ as MessagesTargetDrift {
                throw MessagesReactionAXError.postPressWindowDrift
            }
            if let currentPicker = try availablePicker(in: window, deadline: readDeadline) {
                guard picker.sameIdentity(as: currentPicker) else {
                    throw MessagesReactionAXError.postPressPickerIdentityDrift
                }
                let currentButton = try uniqueButton(in: currentPicker, window: window, identifier: identifier,
                                                     deadline: readDeadline)
                guard button.sameIdentity(as: currentButton) else {
                    throw MessagesReactionAXError.postPressButtonIdentityDrift
                }
                guard let selected = try button.selected(deadline: readDeadline) else {
                    throw MessagesReactionAXError.postPressSelectedUnknown
                }
                if selected == desiredSelected { return .present }
            } else {
                do {
                    _ = try uniqueCurrentWindow(route, deadline: readDeadline)
                } catch MessagesReactionAXError.targetDrift {
                    throw MessagesReactionAXError.postPressWindowDrift
                } catch _ as MessagesTargetDrift {
                    throw MessagesReactionAXError.postPressWindowDrift
                }
                return .absent
            }
            guard attempt < 30 else { throw MessagesReactionAXError.postPressSelectionTimeout }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesReactionAXError.postPressSelectionTimeout }
            let pause = min(50_000_000, cap - (now - started), readDeadline.remainingNanoseconds)
            readinessPause(pause)
        }
        throw MessagesReactionAXError.postPressSelectionTimeout
    }

    private func verifyRetainedStateAfterPickerDismissal(request: MessagesReactionRequest, titles: [String],
                                                         originalRoute: Route, desiredSelected: Bool,
                                                         path: MessagesVerificationPath,
                                                         deadline: WorkerDeadline) throws {
        let route: Route
        do {
            _ = try waitForRetainedRouteAfterPickerDismissal(process: originalRoute.process, titles: titles,
                                                             originalRoute: originalRoute, deadline: deadline)
            route = try requireRetainedRouteAfterPickerDismissal(process: originalRoute.process, titles: titles,
                                                                 originalRoute: originalRoute, deadline: deadline)
        } catch let error as MessagesTargetDrift {
            throw verificationFailure(path, .discoveryDrift, error.reason)
        } catch let error as MessagesAXRouteDrift {
            throw verificationFailure(path, .discoveryDrift, Self.targetDriftReason(from: error.reason))
        } catch MessagesAXNavigationError.targetDrift {
            throw verificationFailure(path, .discoveryDrift)
        } catch MessagesAXNavigationError.ambiguousSelectedMessage {
            throw verificationFailure(path, .discoveryDrift)
        } catch MessagesReactionAXError.postPressVerifyRouteDrift {
            throw verificationFailure(path, .discoveryDrift)
        } catch MessagesReactionAXError.targetDrift {
            throw verificationFailure(path, .discoveryDrift)
        } catch MessagesReactionAXError.pickerUnavailable {
            throw verificationFailure(path, .discoveryDrift)
        } catch MessagesReactionAXError.ambiguousSelectedMessage {
            throw verificationFailure(path, .discoveryDrift)
        }
        guard let action = try reactAction(on: route.selected, titles: titles, deadline: deadline) else {
            throw MessagesReactionAXError.postPressVerifyActionMissing
        }
        try route.selected.performAction(named: action, deadline: deadline)
        let (picker, button, initialSelected): (any MessagesAXElement, any MessagesAXElement, Bool)
        do {
            (picker, button, initialSelected) = try waitForPickerButton(route: route, titles: titles,
                                                                       identifier: request.reaction.pickerIdentifier,
                                                                       experimentalUIHandoff: request.experimentalUIHandoff,
                                                                       deadline: deadline)
        } catch let error as MessagesTargetDrift {
            throw verificationFailure(path, .validationDrift, error.reason)
        } catch MessagesReactionAXError.targetDrift {
            throw verificationFailure(path, .validationDrift)
        }
        let selected: Bool
        do {
            selected = try validatePostMenuPicker(route: route, titles: titles, picker: picker, button: button,
                                                  initialSelected: initialSelected,
                                                  identifier: request.reaction.pickerIdentifier,
                                                  experimentalUIHandoff: request.experimentalUIHandoff,
                                                  deadline: deadline)
        } catch let error as MessagesTargetDrift {
            throw verificationFailure(path, .validationDrift, error.reason)
        } catch MessagesReactionAXError.targetDrift {
            throw verificationFailure(path, .validationDrift)
        }
        guard selected == desiredSelected else { throw verificationFailure(path, .desiredStateMismatch) }
        try cancelOwnedPicker(route: route, titles: titles, picker: picker,
                              experimentalUIHandoff: request.experimentalUIHandoff, deadline: deadline)
    }

    private func cancelOwnedPicker(route: Route, titles: [String], picker: any MessagesAXElement,
                                   experimentalUIHandoff: Bool, deadline: WorkerDeadline) throws {
        let window: any MessagesAXElement
        if experimentalUIHandoff {
            do {
                window = try uniqueCurrentWindow(route, deadline: deadline)
            } catch MessagesReactionAXError.targetDrift {
                throw MessagesReactionAXError.pickerCancelIdentityDrift
            } catch _ as MessagesTargetDrift {
                throw MessagesReactionAXError.pickerCancelIdentityDrift
            }
        } else {
            try revalidate(route, titles: titles, deadline: deadline)
            window = route.window
        }
        let currentPicker: any MessagesAXElement
        do {
            currentPicker = try uniquePicker(in: window, deadline: deadline)
        } catch MessagesReactionAXError.pickerUnavailable {
            throw MessagesReactionAXError.pickerCancelPickerUnavailable
        }
        guard picker.sameIdentity(as: currentPicker) else {
            throw MessagesReactionAXError.pickerCancelIdentityDrift
        }
        guard try currentPicker.actions(deadline: deadline).contains("AXCancel") else {
            throw MessagesReactionAXError.pickerCancelUnavailable
        }
        try currentPicker.performAction(named: "AXCancel", deadline: deadline)
        try waitForPickerDismissal(route: route, retainedPicker: currentPicker, deadline: deadline)
    }

    private func waitForPickerDismissal(route: Route, retainedPicker: any MessagesAXElement,
                                        deadline: WorkerDeadline) throws {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(1_500)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        for attempt in 0..<31 {
            try checkDeadline(deadline)
            if readDeadline.expired { throw MessagesReactionAXError.pickerDismissalTimeout }
            let window: any MessagesAXElement
            do {
                window = try uniqueCurrentWindow(route, deadline: readDeadline)
            } catch MessagesReactionAXError.targetDrift {
                throw MessagesReactionAXError.pickerDismissalWindowDrift
            } catch _ as MessagesTargetDrift {
                throw MessagesReactionAXError.pickerDismissalWindowDrift
            }
            if let picker = try availablePicker(in: window, deadline: readDeadline) {
                guard picker.sameIdentity(as: retainedPicker) else {
                    throw MessagesReactionAXError.pickerDismissalPickerIdentityDrift
                }
            } else {
                do {
                    _ = try uniqueCurrentWindow(route, deadline: readDeadline)
                } catch MessagesReactionAXError.targetDrift {
                    throw MessagesReactionAXError.pickerDismissalWindowDrift
                } catch _ as MessagesTargetDrift {
                    throw MessagesReactionAXError.pickerDismissalWindowDrift
                }
                return
            }
            guard attempt < 30 else { throw MessagesReactionAXError.pickerDismissalTimeout }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesReactionAXError.pickerDismissalTimeout }
            let pause = min(50_000_000, cap - (now - started), readDeadline.remainingNanoseconds)
            readinessPause(pause)
        }
        throw MessagesReactionAXError.pickerDismissalTimeout
    }


    private func uniqueCurrentWindow(_ route: Route, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        do {
            return try navigator.uniqueCurrentWindow(route, deadline: deadline)
        } catch let error as MessagesAXRouteDrift {
            throw Self.targetDrift(from: error)
        } catch let error as MessagesAXNavigationError {
            throw Self.reactionError(from: error)
        }
    }

    private func uniqueRootWindow(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        do {
            return try navigator.uniqueRootWindow(process: process, deadline: deadline)
        } catch let error as MessagesAXRouteDrift {
            throw Self.targetDrift(from: error)
        } catch let error as MessagesAXNavigationError {
            throw Self.reactionError(from: error)
        }
    }

    private func validatePostMenuPicker(route: Route, titles: [String], picker: any MessagesAXElement,
                                        button: any MessagesAXElement, initialSelected: Bool,
                                        identifier: String, experimentalUIHandoff: Bool,
                                        deadline: WorkerDeadline) throws -> Bool {
        let window: any MessagesAXElement
        if experimentalUIHandoff {
            window = try uniqueCurrentWindow(route, deadline: deadline)
        } else {
            try revalidate(route, titles: titles, deadline: deadline)
            window = route.window
        }
        let currentPicker = try uniquePicker(in: window, deadline: deadline)
        guard picker.sameIdentity(as: currentPicker) else { throw MessagesTargetDrift(.pickerMismatch) }
        let currentButton = try uniqueButton(in: currentPicker, window: window, identifier: identifier, deadline: deadline)
        guard button.sameIdentity(as: currentButton) else { throw MessagesTargetDrift(.buttonMismatch) }
        guard let selected = try button.selected(deadline: deadline), selected == initialSelected else {
            throw MessagesTargetDrift(.selectedStateChanged)
        }
        return selected
    }

    private func settleExactPickerBeforePress(request: MessagesReactionRequest, route: Route,
                                             titles: [String], picker: any MessagesAXElement,
                                             button: any MessagesAXElement, initialSelected: Bool,
                                             deadline: WorkerDeadline) throws {
        try boundedReadinessPause(750_000_000, deadline: deadline)
        _ = try validatePostMenuPicker(route: route, titles: titles, picker: picker, button: button,
                                       initialSelected: initialSelected,
                                       identifier: request.reaction.pickerIdentifier,
                                       experimentalUIHandoff: request.experimentalUIHandoff,
                                       deadline: deadline)
        guard try button.actions(deadline: deadline).contains("AXPress") else {
            throw MessagesReactionAXError.targetDrift
        }
    }

    // Only absence is transient. Never repeat navigation or Tapback, and never
    // replace a captured picker. These are experimental selected-route checks,
    // not independent GUID-bearing AX identity proof.
    private func waitForPickerButton(route: Route, titles: [String], identifier: String,
                                     experimentalUIHandoff: Bool,
                                     deadline: WorkerDeadline) throws -> (any MessagesAXElement, any MessagesAXElement, Bool) {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        // WorkerDeadline uses real monotonic time even when the polling clock
        // is injected. Pass the shorter budget into every readiness read so
        // traversal checkpoints and AX messaging timeouts share the local cap.
        let localDeadline = WorkerDeadline.millisecondsFromNow(1_500)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        var retainedPicker: (any MessagesAXElement)?
        var unavailable = MessagesReactionAXError.pickerUnavailable
        func remaining() throws -> UInt64 {
            try checkDeadline(deadline)
            guard !readDeadline.expired else { throw unavailable }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw unavailable }
            return cap - (now - started)
        }
        do {
            // The attempt bound also prevents a non-advancing injected clock from
            // spinning. The production clock and pause are monotonic and bounded.
            for attempt in 0..<31 {
                _ = try remaining()
                let window: any MessagesAXElement
                if attempt > 0 {
                    if experimentalUIHandoff {
                        window = try uniqueCurrentWindow(route, deadline: readDeadline)
                    } else {
                        try revalidate(route, titles: titles, deadline: readDeadline)
                        window = route.window
                    }
                    _ = try remaining()
                } else {
                    window = route.window
                }
                let picker = try availablePicker(in: window, deadline: readDeadline)
                _ = try remaining()
                if let picker {
                    if let retainedPicker, !retainedPicker.sameIdentity(as: picker) {
                        throw MessagesReactionAXError.targetDrift
                    }
                    retainedPicker = picker
                    unavailable = .reactionUnavailable
                    let button = try availableButton(in: picker, window: window, identifier: identifier, deadline: readDeadline)
                    _ = try remaining()
                    if let button {
                        guard let selected = try button.selected(deadline: readDeadline) else {
                            throw MessagesReactionAXError.unknownAXValue
                        }
                        _ = try remaining()
                        return (picker, button, selected)
                    }
                } else if retainedPicker != nil {
                    throw MessagesReactionAXError.targetDrift
                }
                guard attempt < 30 else { throw unavailable }
                let pause = min(50_000_000, try remaining(), readDeadline.remainingNanoseconds)
                try checkDeadline(readDeadline)
                readinessPause(pause)
                _ = try remaining()
            }
        } catch MessagesReactionAXError.deadlineExpired {
            // Preserve global timeout failures and local readiness refusals.
            try checkDeadline(deadline)
            throw unavailable
        } catch MessagesAXNavigationError.deadlineExpired {
            // Live AX adapters throw the neutral deadline error; preserve the
            // reaction readiness contract at this boundary.
            try checkDeadline(deadline)
            throw unavailable
        }
        throw unavailable
    }

    private func waitForPickerButtonOrCustomChooser(route: Route, titles: [String], request: MessagesReactionRequest,
                                                    deadline: WorkerDeadline) throws -> PickerResolution {
        if request.operation == .set, case .custom(let emoji) = request.reaction {
            let picker = try withCustomChooserAXFailure(.pickerRead) {
                try waitForPicker(route: route, titles: titles,
                                  experimentalUIHandoff: request.experimentalUIHandoff,
                                  deadline: deadline)
            }
            if let button = try withCustomChooserAXFailure(.existingButton, {
                try availableButton(in: picker, window: route.window, identifier: emoji, deadline: deadline)
            }) {
                let selected = try withCustomChooserAXFailure(.existingButton) {
                    try button.selected(deadline: deadline)
                }
                guard let selected else { throw MessagesReactionAXError.unknownAXValue }
                if selected { return .exact(picker, button, selected) }
            }
            let remainingPicker = try setCustomReactionWithChooser(route: route, titles: titles, emoji: emoji,
                picker: picker, experimentalUIHandoff: request.experimentalUIHandoff, deadline: deadline)
            return .customChooserChanged(remainingPicker)
        }
        let exact = try waitForPickerButton(route: route, titles: titles,
                                           identifier: request.reaction.pickerIdentifier,
                                           experimentalUIHandoff: request.experimentalUIHandoff,
                                           deadline: deadline)
        return .exact(exact.0, exact.1, exact.2)
    }

    private func waitForPicker(route: Route, titles: [String], experimentalUIHandoff: Bool,
                               deadline: WorkerDeadline) throws -> any MessagesAXElement {
        let started = readinessNow()
        let cap: UInt64 = 1_500_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(1_500)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        var lastAvailabilityRelationshipDrift: MessagesTargetDrift?
        for attempt in 0..<31 {
            try checkDeadline(deadline)
            guard !readDeadline.expired else {
                if let lastAvailabilityRelationshipDrift { throw lastAvailabilityRelationshipDrift }
                throw MessagesReactionAXError.pickerUnavailable
            }
            let window: any MessagesAXElement
            if attempt > 0 {
                if experimentalUIHandoff {
                    window = try uniqueCurrentWindow(route, deadline: readDeadline)
                } else {
                    try revalidate(route, titles: titles, deadline: readDeadline)
                    window = route.window
                }
            } else {
                window = route.window
            }
            do {
                if let picker = try availablePicker(in: window, deadline: readDeadline) {
                    return picker
                }
                lastAvailabilityRelationshipDrift = nil
            } catch let drift as MessagesTargetDrift where drift.reason == .relationshipCountChanged {
                lastAvailabilityRelationshipDrift = drift
                guard attempt < 30 else { throw drift }
            }
            guard attempt < 30 else {
                if let lastAvailabilityRelationshipDrift { throw lastAvailabilityRelationshipDrift }
                throw MessagesReactionAXError.pickerUnavailable
            }
            let now = readinessNow()
            guard now >= started, now - started < cap else {
                if let lastAvailabilityRelationshipDrift { throw lastAvailabilityRelationshipDrift }
                throw MessagesReactionAXError.pickerUnavailable
            }
            let pause = min(50_000_000, cap - (now - started), readDeadline.remainingNanoseconds)
            try checkDeadline(readDeadline)
            readinessPause(pause)
        }
        throw MessagesReactionAXError.pickerUnavailable
    }

    private func validateChooserRoute(_ route: Route, titles: [String], experimentalUIHandoff: Bool,
                                      deadline: WorkerDeadline) throws {
        if experimentalUIHandoff {
            _ = try uniqueCurrentWindow(route, deadline: deadline)
        } else {
            try revalidate(route, titles: titles, deadline: deadline)
        }
    }

    // Only read-only readiness is retried. Unknown types, ownership drift and
    // incomplete traversals are never converted to absence or retried as writes.
    private func withCustomChooserAXFailure<T>(_ phase: CustomChooserAXFailurePhase,
                                               _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch MessagesReactionAXError.axFailure { throw CustomChooserAXFailure(phase: phase) }
        catch MessagesAXNavigationError.axFailure { throw CustomChooserAXFailure(phase: phase) }
    }

    private func withCustomChooserReactionUnavailable<T>(_ phase: CustomChooserAXFailurePhase,
                                                         _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch MessagesReactionAXError.reactionUnavailable { throw CustomChooserReactionUnavailable(phase: phase) }
    }

    private func waitForChooserRead<T>(deadline: WorkerDeadline, globalDeadline: WorkerDeadline? = nil,
                                       read: (WorkerDeadline) throws -> T) throws -> T {
        let global = globalDeadline ?? deadline
        let local = WorkerDeadline.millisecondsFromNow(1_500)
        let bound = deadline.remainingNanoseconds <= local.remainingNanoseconds ? deadline : local
        let start = readinessNow()
        var lastError = MessagesReactionAXError.reactionUnavailable
        var lastAXFailurePhase: CustomChooserAXFailurePhase?
        var lastUnavailablePhase: CustomChooserAXFailurePhase?
        for attempt in 0..<31 {
            try checkDeadline(global)
            guard !bound.expired else {
                if let lastAXFailurePhase { throw CustomChooserAXFailure(phase: lastAXFailurePhase) }
                if let lastUnavailablePhase { throw CustomChooserReactionUnavailable(phase: lastUnavailablePhase) }
                throw lastError
            }
            do { return try read(bound) }
            catch let error as CustomChooserAXFailure {
                lastError = .axFailure
                lastAXFailurePhase = error.phase
                lastUnavailablePhase = nil
                let now = readinessNow()
                guard attempt < 30, now >= start, now - start < 1_500_000_000 else { throw error }
                try checkDeadline(global)
                guard !bound.expired else { throw error }
                readinessPause(min(50_000_000, bound.remainingNanoseconds))
            } catch let error as CustomChooserReactionUnavailable {
                lastError = .reactionUnavailable
                lastAXFailurePhase = nil
                lastUnavailablePhase = error.phase
                let now = readinessNow()
                guard attempt < 30, now >= start, now - start < 1_500_000_000 else { throw error }
                try checkDeadline(global)
                guard !bound.expired else { throw error }
                readinessPause(min(50_000_000, bound.remainingNanoseconds))
            } catch let error as MessagesReactionAXError {
                if error == .deadlineExpired {
                    try checkDeadline(global)
                    if let lastAXFailurePhase { throw CustomChooserAXFailure(phase: lastAXFailurePhase) }
                    if let lastUnavailablePhase { throw CustomChooserReactionUnavailable(phase: lastUnavailablePhase) }
                    throw lastError
                }
                guard error == .reactionUnavailable || error == .pickerUnavailable || error == .axFailure else { throw error }
                lastError = error
                lastAXFailurePhase = nil
                lastUnavailablePhase = nil
                let now = readinessNow()
                guard attempt < 30, now >= start, now - start < 1_500_000_000 else { throw error }
                try checkDeadline(global)
                guard !bound.expired else { throw error }
                readinessPause(min(50_000_000, bound.remainingNanoseconds))
            } catch let error as MessagesAXNavigationError {
                let reactionError = Self.reactionError(from: error)
                if reactionError == .deadlineExpired {
                    try checkDeadline(global)
                    if let lastAXFailurePhase { throw CustomChooserAXFailure(phase: lastAXFailurePhase) }
                    if let lastUnavailablePhase { throw CustomChooserReactionUnavailable(phase: lastUnavailablePhase) }
                    throw lastError
                }
                guard reactionError == .axFailure else { throw reactionError }
                lastError = reactionError
                lastAXFailurePhase = nil
                lastUnavailablePhase = nil
                let now = readinessNow()
                guard attempt < 30, now >= start, now - start < 1_500_000_000 else { throw reactionError }
                try checkDeadline(global)
                guard !bound.expired else { throw reactionError }
                readinessPause(min(50_000_000, bound.remainingNanoseconds))
            }
        }
        if let lastUnavailablePhase { throw CustomChooserReactionUnavailable(phase: lastUnavailablePhase) }
        throw MessagesReactionAXError.reactionUnavailable
    }

    private func setCustomReactionWithChooser(route: Route, titles: [String], emoji: String,
                                              picker: any MessagesAXElement, experimentalUIHandoff: Bool,
                                              deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try withCustomChooserAXFailure(.routeValidation) {
            try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: deadline)
        }
        guard try withCustomChooserAXFailure(.launchDiscovery, {
            try uniquePicker(in: route.window, deadline: deadline).sameIdentity(as: picker)
        }) else {
            throw MessagesReactionAXError.targetDrift
        }
        try withCustomChooserAXFailure(.launchDiscovery) {
            try requireProcessOwned(picker, process: route.process, deadline: deadline)
        }
        let launcher = try withCustomChooserReactionUnavailable(.launchDiscovery) {
            try withCustomChooserAXFailure(.launchDiscovery) {
                try uniqueCustomEmojiLauncher(picker: picker, process: route.process,
                                              phase: .launchDiscovery, deadline: deadline)
            }
        }
        let searchPlan = try withCustomChooserReactionUnavailable(.query) {
            try withCustomChooserAXFailure(.query) {
                try driver.customEmojiSearchPlan(for: emoji, deadline: deadline)
            }
        }
        guard MessagesReactionActionTitleResolver.valid(searchPlan.query),
              searchPlan.position >= 0, searchPlan.position < 256 else {
            throw CustomChooserReactionUnavailable(phase: .query)
        }
        guard !searchPlan.supportsSkinToneVariants else {
            throw CustomChooserReactionUnavailable(phase: .query)
        }
        let query = searchPlan.query
        // A pre-existing chooser cannot be attributed to this launcher action.
        // Only verified absence permits launch; ambiguity and read errors throw.
        guard try withCustomChooserReactionUnavailable(.preexistingCheck, {
            try withCustomChooserAXFailure(.preexistingCheck) {
                try driver.detachedCustomEmojiPopover(process: route.process, deadline: deadline) == nil
            }
        }) else {
            throw CustomChooserReactionUnavailable(phase: .preexistingCheck)
        }
        try withCustomChooserAXFailure(.launchRevalidation) {
            try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: deadline)
            guard try uniquePicker(in: route.window, deadline: deadline).sameIdentity(as: picker),
                  try withCustomChooserReactionUnavailable(.launchRevalidation, {
                      try uniqueCustomEmojiLauncher(picker: picker, process: route.process,
                                                    phase: .launchRevalidation, deadline: deadline).sameIdentity(as: launcher)
                  }),
                  try launcher.actions(deadline: deadline).contains("AXPress") else {
                throw MessagesReactionAXError.targetDrift
            }
        }
        try withCustomChooserAXFailure(.launchPress) {
            try launcher.performAction(named: "AXPress", deadline: deadline)
        }
        let (popover, search) = try waitForChooserRead(deadline: deadline) { bound in
            try withCustomChooserAXFailure(.routeValidation) {
                try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: bound)
            }
            let popover = try uniqueCustomEmojiPopover(route: route, picker: picker,
                                                       detachedPhase: .detachedDiscovery,
                                                       popoverPhase: .popover, deadline: bound)
            let search = try uniqueCustomEmojiSearchField(in: popover, process: route.process,
                                                          phase: .searchDiscovery, deadline: bound)
            guard try withCustomChooserAXFailure(.searchPrecondition, {
                try search.enabled(deadline: bound) == true && search.valueSettable(deadline: bound) == true &&
                    search.axValue(deadline: bound) == ""
            }) else { throw CustomChooserReactionUnavailable(phase: .searchPrecondition) }
            return (popover, search)
        }
        // Leave time to restore only our own search on preselection failure.
        let reserve: UInt64 = 1_000_000_000
        guard deadline.remainingNanoseconds > reserve + 100_000_000 else { throw MessagesReactionAXError.deadlineExpired }
        let workDeadline = WorkerDeadline.millisecondsFromNow((deadline.remainingNanoseconds - reserve) / 1_000_000)
        var selectionStarted = false
        do {
            try withCustomChooserAXFailure(.candidateWait) {
                try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: workDeadline)
                try validateChooserOwnership(route: route, picker: picker, popover: popover, search: search,
                                             expectedQuery: "", phase: .candidateWait, deadline: workDeadline)
            }
            // AXSet may take effect even when it reports failure. Cleanup covers
            // both the write and its readback, but never clears a user's value.
            try withCustomChooserAXFailure(.searchWrite) {
                try search.setValue(query, deadline: workDeadline)
            }
            let didReadBack = try withCustomChooserAXFailure(.searchReadback) {
                try search.axValue(deadline: workDeadline)?.utf8.elementsEqual(query.utf8) == true
            }
            guard didReadBack else { throw MessagesReactionAXError.targetDrift }
            let candidate = try waitForChooserRead(deadline: workDeadline, globalDeadline: deadline) { bound in
                try validateChooserOwnership(route: route, picker: picker, popover: popover, search: search,
                                             expectedQuery: query, phase: .candidateWait, deadline: bound)
                return try uniqueCustomEmojiCandidate(in: popover, process: route.process, emoji: emoji,
                                                      phase: .candidateRead, deadline: bound)
            }
            try withCustomChooserAXFailure(.candidateRevalidation) {
                try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: workDeadline)
                try validateChooserOwnership(route: route, picker: picker, popover: popover, search: search,
                                             expectedQuery: query, phase: .candidateRevalidation, deadline: workDeadline)
            }
            let final = try uniqueCustomEmojiCandidate(in: popover, process: route.process, emoji: emoji,
                                                       phase: .candidateRevalidation, deadline: workDeadline)
            guard final.element.sameIdentity(as: candidate.element), final.actions.contains("AXPress") else {
                throw MessagesReactionAXError.targetDrift
            }
            try withCustomChooserAXFailure(.candidateRevalidation) {
                try checkProcess(route.process, deadline: workDeadline)
            }
            let stillOwnsQuery = try withCustomChooserAXFailure(.candidateRevalidation) {
                try search.axValue(deadline: workDeadline)?.utf8.elementsEqual(query.utf8) == true
            }
            guard stillOwnsQuery else { throw MessagesReactionAXError.targetDrift }
            try requirePopoverMembership(candidate.element, popover: popover, process: route.process,
                                         phase: .candidateRevalidation, deadline: workDeadline)
            let candidateStillMatches = try withCustomChooserAXFailure(.candidateRevalidation) {
                try customEmojiCandidateMatches(candidate.element, process: route.process, emoji: emoji,
                                                phase: .candidateRevalidation, deadline: workDeadline)
            }
            guard candidateStillMatches else { throw MessagesReactionAXError.targetDrift }
            try checkDeadline(workDeadline)
            try pressCustomEmojiCandidateUsingKeyboard(searchPlan, route: route, titles: titles, picker: picker,
                                                       popover: popover, search: search, candidate: candidate,
                                                       emoji: emoji, experimentalUIHandoff: experimentalUIHandoff,
                                                       deadline: workDeadline) { selectionStarted = true }
        } catch {
            if !selectionStarted {
                // Cleanup is best effort; any failure preserves the original
                // refusal and the parent operation's uncertain state.
                do {
                    try validateChooserOwnership(route: route, picker: picker, popover: popover, search: search,
                                                 expectedQuery: query, phase: .candidateWait, deadline: deadline)
                    try search.setValue("", deadline: deadline)
                    guard try search.axValue(deadline: deadline) == "" else { throw MessagesReactionAXError.targetDrift }
                } catch { /* Leave uncertain state for reconciliation. */ }
            }
            throw error
        }
        var observedUnselected = false
        do {
            return try waitForChooserRead(deadline: deadline) { bound in
                try withCustomChooserAXFailure(.postSelection) {
                    try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: bound)
                }
                guard let currentPicker = try withCustomChooserAXFailure(.postSelection, {
                    try availablePicker(in: route.window, deadline: bound)
                }) else { return nil }
                guard let button = try withCustomChooserReactionUnavailable(.postSelection, {
                    try withCustomChooserAXFailure(.postSelection) {
                        try availableButton(in: currentPicker, window: route.window, identifier: emoji, deadline: bound)
                    }
                }) else {
                    throw CustomChooserReactionUnavailable(phase: .postSelection)
                }
                let selected = try withCustomChooserAXFailure(.postSelection) {
                    try button.selected(deadline: bound)
                }
                guard let selected else { throw MessagesReactionAXError.unknownAXValue }
                guard selected else {
                    observedUnselected = true
                    throw CustomChooserReactionUnavailable(phase: .postSelection)
                }
                return currentPicker
            }
        } catch is CustomChooserReactionUnavailable where observedUnselected {
            throw MessagesReactionAXError.customChooserPostSelectionUnselected
        }
    }

    private func pressCustomEmojiCandidateUsingKeyboard(_ plan: MessagesCustomEmojiSearchPlan, route: Route,
                                                        titles: [String], picker: any MessagesAXElement,
                                                        popover: any MessagesAXElement, search: any MessagesAXElement,
                                                        candidate: CustomEmojiCandidate, emoji: String,
                                                        experimentalUIHandoff: Bool, deadline: WorkerDeadline,
                                                        markSelectionStarted: () -> Void) throws {
        try customChooserPause(750_000_000, deadline: deadline)
        let keys = try customChooserSelectionKeys(position: plan.position)
        for index in keys.indices {
            let key = keys[index]
            if key == .returnKey { try customChooserPause(100_000_000, deadline: deadline) }
            try validateCustomEmojiSelectionKeyPreconditions(route: route, titles: titles, picker: picker,
                                                             popover: popover, search: search, candidate: candidate,
                                                             emoji: emoji, expectedQuery: plan.query,
                                                             experimentalUIHandoff: experimentalUIHandoff,
                                                             deadline: deadline)
            try withCustomChooserAXFailure(.candidatePress) {
                markSelectionStarted()
                try driver.pressCustomEmojiChooserKey(key, process: route.process, deadline: deadline)
            }
            if key != .returnKey, index + 1 < keys.count { try customChooserPause(50_000_000, deadline: deadline) }
        }
    }

    private func customChooserSelectionKeys(position: Int) throws -> [MessagesCustomEmojiChooserKey] {
        guard position >= 0, position < 256 else { throw CustomChooserReactionUnavailable(phase: .query) }
        let (downArrows, rightArrows) = position.quotientAndRemainder(dividingBy: 6)
        return [.downArrow] + Array(repeating: .downArrow, count: downArrows)
            + Array(repeating: .rightArrow, count: rightArrows) + [.returnKey]
    }

    private func customChooserPause(_ nanoseconds: UInt64, deadline: WorkerDeadline) throws {
        try boundedReadinessPause(nanoseconds, deadline: deadline)
    }

    private func boundedReadinessPause(_ nanoseconds: UInt64, deadline: WorkerDeadline) throws {
        try checkDeadline(deadline)
        guard deadline.remainingNanoseconds > nanoseconds else { throw MessagesReactionAXError.deadlineExpired }
        readinessPause(nanoseconds)
        try checkDeadline(deadline)
    }

    private func validateCustomEmojiSelectionKeyPreconditions(route: Route, titles: [String],
                                                             picker: any MessagesAXElement,
                                                             popover: any MessagesAXElement,
                                                             search: any MessagesAXElement,
                                                             candidate: CustomEmojiCandidate, emoji: String,
                                                             expectedQuery: String, experimentalUIHandoff: Bool,
                                                             deadline: WorkerDeadline) throws {
        try withCustomChooserAXFailure(.candidateRevalidation) {
            try validateChooserRoute(route, titles: titles, experimentalUIHandoff: experimentalUIHandoff, deadline: deadline)
            try validateCustomChooserKeyboardFocus(route: route, popover: popover, deadline: deadline)
            try validateChooserOwnership(route: route, picker: picker, popover: popover, search: search,
                                         expectedQuery: expectedQuery, phase: .candidateRevalidation, deadline: deadline)
        }
        let current = try uniqueCustomEmojiCandidate(in: popover, process: route.process, emoji: emoji,
                                                     phase: .candidateRevalidation, deadline: deadline)
        guard current.element.sameIdentity(as: candidate.element), current.actions.contains("AXPress") else {
            throw MessagesReactionAXError.targetDrift
        }
    }

    private func validateCustomChooserKeyboardFocus(route: Route, popover: any MessagesAXElement,
                                                    deadline: WorkerDeadline) throws {
        guard try driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
            throw MessagesReactionAXError.targetDrift
        }
        guard let focused = try driver.focusedElement(deadline: deadline) else { return }
        try requireProcessOwned(focused, process: route.process, deadline: deadline)
        try requirePopoverMembership(focused, popover: popover, process: route.process,
                                     phase: .candidateRevalidation, deadline: deadline)
    }

    private func validateChooserOwnership(route: Route, picker: any MessagesAXElement,
                                         popover: any MessagesAXElement, search: any MessagesAXElement,
                                         expectedQuery: String, phase: CustomChooserAXFailurePhase,
                                         deadline: WorkerDeadline) throws {
        let current = try uniqueCustomEmojiPopover(route: route, picker: picker,
                                                   detachedPhase: phase, popoverPhase: phase, deadline: deadline)
        guard current.sameIdentity(as: popover) else { throw MessagesReactionAXError.targetDrift }
        let currentSearch = try uniqueCustomEmojiSearchField(in: current, process: route.process, phase: phase, deadline: deadline)
        guard currentSearch.sameIdentity(as: search),
              try withCustomChooserAXFailure(phase, { try search.enabled(deadline: deadline) == true }),
              try withCustomChooserAXFailure(phase, { try search.valueSettable(deadline: deadline) == true }),
              try withCustomChooserAXFailure(phase, {
                  try search.axValue(deadline: deadline)?.utf8.elementsEqual(expectedQuery.utf8) == true
              }) else {
            throw MessagesReactionAXError.targetDrift
        }
        try withCustomChooserAXFailure(phase) { try checkProcess(route.process, deadline: deadline) }
    }

    private func requirePopoverMembership(_ element: any MessagesAXElement, popover: any MessagesAXElement,
                                          process: MessagesAXProcess, phase: CustomChooserAXFailurePhase? = nil,
                                          deadline: WorkerDeadline) throws {
        var current = element
        var seen: [any MessagesAXElement] = []
        for _ in 0..<17 {
            if let phase {
                try withCustomChooserAXFailure(phase) { try requireProcessOwned(current, process: process, deadline: deadline) }
            } else {
                try requireProcessOwned(current, process: process, deadline: deadline)
            }
            if current.sameIdentity(as: popover) { return }
            guard !seen.contains(where: { $0.sameIdentity(as: current) }),
                  let parent = try (phase.map { phase in try withCustomChooserAXFailure(phase) { try current.parent(deadline: deadline) } } ?? current.parent(deadline: deadline)) else { throw MessagesReactionAXError.targetDrift }
            seen.append(current)
            current = parent
        }
        throw MessagesReactionAXError.traversalLimit
    }

    private func uniqueCustomEmojiLauncher(picker: any MessagesAXElement, process: MessagesAXProcess,
                                           phase: CustomChooserAXFailurePhase,
                                           deadline: WorkerDeadline) throws -> any MessagesAXElement {
        guard let parent = try picker.parent(deadline: deadline) else {
            throw CustomChooserReactionUnavailable(phase: phase)
        }
        let siblings = try parent.children(limit: maxChildren, deadline: deadline)
        let matches = try siblings.filter { element in
            try checkDeadline(deadline)
            guard !element.sameIdentity(as: picker), try element.role(deadline: deadline) == "AXButton",
                  try element.identifier(deadline: deadline) == nil,
                  try element.axDescription(deadline: deadline) == "Add custom emoji reaction",
                  try element.enabled(deadline: deadline) == true else { return false }
            try requireProcessOwned(element, process: process, deadline: deadline)
            guard let elementParent = try element.parent(deadline: deadline), elementParent.sameIdentity(as: parent) else {
                throw MessagesReactionAXError.targetDrift
            }
            return true
        }
        guard matches.count == 1, let match = matches.first else {
            throw CustomChooserReactionUnavailable(phase: phase)
        }
        return match
    }

    private func uniqueCustomEmojiPopover(route: Route, picker: any MessagesAXElement,
                                          detachedPhase: CustomChooserAXFailurePhase,
                                          popoverPhase: CustomChooserAXFailurePhase,
                                          deadline: WorkerDeadline) throws -> any MessagesAXElement {
        try withCustomChooserAXFailure(detachedPhase) {
            try checkProcess(route.process, deadline: deadline)
        }
        let popover = try withCustomChooserReactionUnavailable(detachedPhase) {
            try withCustomChooserAXFailure(detachedPhase) {
                try driver.detachedCustomEmojiPopover(process: route.process, deadline: deadline)
            }
        }
        guard let popover else { throw CustomChooserReactionUnavailable(phase: detachedPhase) }
        try withCustomChooserReactionUnavailable(popoverPhase) {
            try withCustomChooserAXFailure(popoverPhase) {
                guard try popover.role(deadline: deadline) == "AXPopover" else {
                    throw MessagesReactionAXError.reactionUnavailable
                }
            }
        }
        try withCustomChooserAXFailure(popoverPhase) {
            try requireProcessOwned(popover, process: route.process, deadline: deadline)
        }
        return popover
    }

    private func uniqueCustomEmojiSearchField(in popover: any MessagesAXElement, process: MessagesAXProcess,
                                              phase: CustomChooserAXFailurePhase,
                                              deadline: WorkerDeadline) throws -> any MessagesAXElement {
        let matches = try withCustomChooserAXFailure(phase) {
            // The search field is a direct chooser control. Walking result
            // descendants here can exhaust the budget before a query is set.
            let children: [any MessagesAXElement]
            if let navigation = try popover.childrenInNavigationOrder(limit: maxChildren, deadline: deadline) {
                children = navigation
            } else {
                children = try popover.children(limit: maxChildren, deadline: deadline)
            }
            guard children.count <= maxChildren else { throw MessagesReactionAXError.traversalLimit }
            return try children.filter { element in
                try checkDeadline(deadline)
                try requireProcessOwned(element, process: process, deadline: deadline)
                let role = try element.role(deadline: deadline)
                guard role.utf8.count <= 128 else { throw MessagesReactionAXError.unknownAXValue }
                guard role == "AXTextField" else { return false }
                return try element.subrole(deadline: deadline) == "AXSearchField"
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw CustomChooserReactionUnavailable(phase: phase)
        }
        try withCustomChooserAXFailure(phase) {
            guard let parent = try match.parent(deadline: deadline), parent.sameIdentity(as: popover) else {
                throw MessagesReactionAXError.targetDrift
            }
        }
        return match
    }

    private func uniqueCustomEmojiCandidate(in popover: any MessagesAXElement, process: MessagesAXProcess,
                                            emoji: String, phase: CustomChooserAXFailurePhase,
                                            deadline: WorkerDeadline) throws -> CustomEmojiCandidate {
        let matches = try withCustomChooserAXFailure(phase) {
            try collectPopoverNavigation(from: popover, process: process, deadline: deadline) { element, _ in
                try customEmojiCandidateMatches(element, process: process, emoji: emoji, phase: phase, deadline: deadline)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw CustomChooserReactionUnavailable(phase: phase)
        }
        try requirePopoverMembership(match, popover: popover, process: process, phase: phase, deadline: deadline)
        let actions = try withCustomChooserAXFailure(phase) { try match.actions(deadline: deadline) }
        return CustomEmojiCandidate(element: match, actions: actions)
    }

    private func customEmojiCandidateMatches(_ element: any MessagesAXElement, process: MessagesAXProcess,
                                             emoji: String, phase: CustomChooserAXFailurePhase,
                                             deadline: WorkerDeadline) throws -> Bool {
        let fields = try [element.axDescription(deadline: deadline), element.candidateValueText(deadline: deadline),
                          element.axTitle(deadline: deadline)].compactMap { $0 }
        guard fields.contains(where: { $0.utf8.elementsEqual(emoji.utf8) }) else { return false }
        let actions = try element.actions(deadline: deadline)
        guard actions.contains("AXPress") else { return false }
        let enabled = try element.enabled(deadline: deadline)
        if enabled == true {
            try requireProcessOwned(element, process: process, deadline: deadline)
            return true
        }
        guard enabled == nil else { throw CustomChooserReactionUnavailable(phase: phase) }
        guard actions == ["AXPress"],
              try element.role(deadline: deadline) == "AXUnknown",
              try element.subrole(deadline: deadline) == nil,
              try element.axDescription(deadline: deadline)?.utf8.elementsEqual(emoji.utf8) == true else {
            return false
        }
        try requireProcessOwned(element, process: process, deadline: deadline)
        return try hasExactOwnedGlyphProof(in: element, process: process, emoji: emoji, deadline: deadline)
    }

    private func hasExactOwnedGlyphProof(in candidate: any MessagesAXElement, process: MessagesAXProcess,
                                         emoji: String, deadline: WorkerDeadline) throws -> Bool {
        let children: [any MessagesAXElement]
        if let navigationChildren = try candidate.childrenInNavigationOrder(limit: maxChildren, deadline: deadline) {
            children = navigationChildren
        } else {
            children = try candidate.children(limit: maxChildren, deadline: deadline)
        }
        guard children.count <= maxChildren else { throw MessagesReactionAXError.traversalLimit }
        var matches: [any MessagesAXElement] = []
        for child in children {
            try checkDeadline(deadline)
            try requireProcessOwned(child, process: process, deadline: deadline)
            guard let parent = try child.parent(deadline: deadline), parent.sameIdentity(as: candidate) else {
                throw MessagesReactionAXError.targetDrift
            }
            guard try child.role(deadline: deadline) == "AXStaticText",
                  try child.subrole(deadline: deadline) == nil,
                  try child.axValue(deadline: deadline)?.utf8.elementsEqual(emoji.utf8) == true else { continue }
            matches.append(child)
        }
        guard matches.count == 1, let match = matches.first else { return false }
        return try match.enabled(deadline: deadline) == true && match.actions(deadline: deadline).isEmpty
    }

    private func collectPopoverNavigation(from root: any MessagesAXElement, process: MessagesAXProcess, deadline: WorkerDeadline,
                                          matching predicate: (any MessagesAXElement, String) throws -> Bool) throws -> [any MessagesAXElement] {
        var discovered: [(element: any MessagesAXElement, depth: Int)] = [(root, 0)]
        var cursor = 0
        var matches: [any MessagesAXElement] = []
        while cursor < discovered.count {
            try checkDeadline(deadline)
            let (next, depth) = discovered[cursor]
            cursor += 1
            try requireProcessOwned(next, process: process, deadline: deadline)
            let role = try next.role(deadline: deadline)
            guard role.utf8.count <= 128 else { throw MessagesReactionAXError.unknownAXValue }
            if try predicate(next, role) { matches.append(next) }
            let related: [any MessagesAXElement]
            if let navigationChildren = try next.childrenInNavigationOrder(limit: maxChildren, deadline: deadline) {
                related = navigationChildren
            } else {
                related = try next.children(limit: maxChildren, deadline: deadline)
            }
            guard related.count <= maxChildren else { throw MessagesReactionAXError.traversalLimit }
            for candidate in related {
                let known = try discovered.contains { entry in
                    try checkDeadline(deadline)
                    return entry.element.sameIdentity(as: candidate)
                }
                if known { continue }
                guard discovered.count < 512, depth < 16 else { throw MessagesReactionAXError.traversalLimit }
                discovered.append((candidate, depth + 1))
            }
        }
        return matches
    }

    private func requireProcessOwned(_ element: any MessagesAXElement, process: MessagesAXProcess,
                                     deadline: WorkerDeadline) throws {
        guard let pid = try element.processIdentifier(deadline: deadline), pid == process.identity.pid else {
            throw MessagesReactionAXError.targetDrift
        }
    }

    private func availablePicker(in root: any MessagesAXElement, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        do {
            let matches = try navigator.collect(from: root, window: root, deadline: deadline) { _, _, identifier in
                identifier == "TapbackPickerCollectionView"
            }
            guard matches.count <= 1 else { throw MessagesReactionAXError.pickerUnavailable }
            return matches.first
        } catch let error as MessagesAXRouteDrift {
            throw Self.targetDrift(from: error)
        } catch let error as MessagesAXNavigationError {
            throw Self.reactionError(from: error)
        }
    }

    private func uniquePicker(in root: any MessagesAXElement, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        guard let picker = try availablePicker(in: root, deadline: deadline) else {
            throw MessagesReactionAXError.pickerUnavailable
        }
        return picker
    }

    private func availableButton(in picker: any MessagesAXElement, window: any MessagesAXElement, identifier: String,
                                 deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        let matches = try collect(from: picker, window: window, deadline: deadline) { _, role, value in
            guard role == "AXButton", let value else { return false }
            return value.utf8.elementsEqual(identifier.utf8)
        }
        guard matches.count <= 1 else { throw MessagesReactionAXError.reactionUnavailable }
        return matches.first
    }

    private func uniqueButton(in picker: any MessagesAXElement, window: any MessagesAXElement, identifier: String,
                              deadline: WorkerDeadline) throws -> any MessagesAXElement {
        guard let button = try availableButton(in: picker, window: window, identifier: identifier, deadline: deadline) else {
            throw MessagesReactionAXError.reactionUnavailable
        }
        return button
    }

    private func collect(from root: any MessagesAXElement, window: (any MessagesAXElement)? = nil,
                         deadline: WorkerDeadline,
                         matching predicate: (any MessagesAXElement, String, String?) throws -> Bool) throws -> [any MessagesAXElement] {
        do {
            return try navigator.collect(from: root, window: window, deadline: deadline, matching: predicate)
        } catch let error as MessagesAXRouteDrift {
            throw Self.targetDrift(from: error)
        } catch let error as MessagesAXNavigationError {
            throw Self.reactionError(from: error)
        }
    }

}

enum NativeMessagesURL {
    static func validate(messageGUID: String, nativePartIndex: Int, nativePartGUID: String?) throws {
        guard !messageGUID.isEmpty, messageGUID.utf8.count <= 512,
              messageGUID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 }),
              (0...Int(Int32.max)).contains(nativePartIndex) else { throw MessagesReactionAXError.invalidPayload }
        if let nativePartGUID {
            guard nativePartGUID.utf8.elementsEqual("p:\(nativePartIndex)/\(messageGUID)".utf8) else {
                throw MessagesReactionAXError.invalidPayload
            }
        }
    }

    static func message(messageGUID: String, nativePartIndex: Int, nativePartGUID: String?) throws -> URL {
        try validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"
        components.queryItems = [URLQueryItem(name: "message-guid", value: "p:\(nativePartIndex)/\(messageGUID)")]
        guard let url = components.url else { throw MessagesReactionAXError.invalidPayload }
        return url
    }
}

final class LiveMessagesReactionAXDriver: MessagesReactionAXDriving {
    static let bundleIdentifier = "com.apple.MobileSMS"
    static let applicationURL = URL(fileURLWithPath: "/System/Applications/Messages.app", isDirectory: true)

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { AXIsProcessTrusted() }

    private let titleResolver: MessagesReactionActionTitleResolver

    init(titleResolver: MessagesReactionActionTitleResolver = .live()) {
        self.titleResolver = titleResolver
    }

    func reactActionTitles(deadline: WorkerDeadline) throws -> [String] {
        try checkDeadline(deadline)
        let titles = try titleResolver.resolve(deadline: deadline)
        try checkDeadline(deadline)
        return titles
    }

    func customEmojiSearchPlan(for emoji: String, deadline: WorkerDeadline) throws -> MessagesCustomEmojiSearchPlan {
        try CustomEmojiSearchResolver.searchPlan(for: emoji, deadline: deadline)
    }

    func pressCustomEmojiChooserKey(_ key: MessagesCustomEmojiChooserKey, process: MessagesAXProcess,
                                    deadline: WorkerDeadline) throws {
        try checkDeadline(deadline)
        let current = try canonicalMessagesProcess(deadline: deadline)
        guard current.identity == process.identity, current.root.sameIdentity(as: process.root) else {
            throw MessagesReactionAXError.targetDrift
        }
        try LiveCustomEmojiKeyPresser(pid: process.identity.pid).press(key, deadline: deadline)
        let after = try canonicalMessagesProcess(deadline: deadline)
        guard after.identity == process.identity, after.root.sameIdentity(as: process.root) else {
            throw MessagesReactionAXError.targetDrift
        }
    }

    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool {
        try checkDeadline(deadline)
        let identities = try NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).map(identity)
        let identity = try Self.uniqueIdentity(identities)
        guard identity == process.identity else { throw MessagesReactionAXError.targetDrift }
        let frontmost = NSWorkspace.shared.frontmostApplication
        try checkDeadline(deadline)
        return frontmost?.processIdentifier == process.identity.pid && frontmost?.isActive == true
    }

    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try checkDeadline(deadline)
        let system = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw)
        try checkDeadline(deadline)
        if status == .noValue || status == .attributeUnsupported { return nil }
        guard status == .success, let element = raw, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            throw MessagesReactionAXError.axFailure
        }
        return LiveAXElement(element: element as! AXUIElement)
    }

    // Geometry is only a way to discover the detached search field. Every
    // candidate must prove actual AX ownership and its native parent shape.
    static func customChooserWindowPoints(_ raw: CFArray?, pid: Int32) throws -> [CGPoint] {
        guard let raw, CFArrayGetCount(raw) <= 4096 else { throw MessagesReactionAXError.unknownAXValue }
        func number(_ value: Any?) throws -> Double {
            guard let value, CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID(),
                  let n = value as? NSNumber, n.doubleValue.isFinite else { throw MessagesReactionAXError.unknownAXValue }
            return n.doubleValue
        }
        var points: [CGPoint] = []
        for item in raw as [AnyObject] {
            guard CFGetTypeID(item) == CFDictionaryGetTypeID(), let info = item as? [String: Any] else {
                throw MessagesReactionAXError.unknownAXValue
            }
            let owner = try number(info[kCGWindowOwnerPID as String])
            guard owner.rounded() == owner, owner >= 0, owner <= Double(Int32.max) else {
                throw MessagesReactionAXError.unknownAXValue
            }
            guard owner == Double(pid) else { continue }
            guard let onscreen = info[kCGWindowIsOnscreen as String],
                  CFGetTypeID(onscreen as CFTypeRef) == CFBooleanGetTypeID() else {
                throw MessagesReactionAXError.unknownAXValue
            }
            guard (onscreen as? Bool) == true else { continue }
            let alpha = try number(info[kCGWindowAlpha as String])
            guard alpha >= 0, alpha <= 1 else { throw MessagesReactionAXError.unknownAXValue }
            guard alpha > 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String],
                  CFGetTypeID(bounds as CFTypeRef) == CFDictionaryGetTypeID(),
                  let dict = bounds as? [String: Any] else { throw MessagesReactionAXError.unknownAXValue }
            let x = try number(dict["X"]), y = try number(dict["Y"])
            let width = try number(dict["Width"]), height = try number(dict["Height"])
            guard width >= 0, height >= 0 else { throw MessagesReactionAXError.unknownAXValue }
            guard (300...420).contains(width), (350...560).contains(height) else { continue }
            let point = CGPoint(x: x + width / 2, y: y + 38)
            guard Float(point.x).isFinite, Float(point.y).isFinite, points.count < 8 else {
                throw MessagesReactionAXError.traversalLimit
            }
            points.append(point)
        }
        return points
    }

    func detachedCustomEmojiPopover(process: MessagesAXProcess,
                                    deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try checkDeadline(deadline)
        let current = try canonicalMessagesProcess(deadline: deadline)
        guard current.identity == process.identity, current.root.sameIdentity(as: process.root) else {
            throw MessagesReactionAXError.targetDrift
        }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        try checkDeadline(deadline)
        let points = try Self.customChooserWindowPoints(raw, pid: process.identity.pid)
        let app = AXUIElementCreateApplication(process.identity.pid)
        var matches: [(search: LiveAXElement, popover: any MessagesAXElement)] = []
        for point in points {
            try checkDeadline(deadline)
            let timeout = Float(min(0.25, Double(deadline.remainingNanoseconds) / 2_000_000_000))
            guard AXUIElementSetMessagingTimeout(app, timeout) == .success else { throw MessagesReactionAXError.axFailure }
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            try checkDeadline(deadline)
            if status == .noValue || status == .attributeUnsupported { continue }
            guard status == .success, let hit else { throw MessagesReactionAXError.axFailure }
            let search = LiveAXElement(element: hit)
            guard try search.processIdentifier(deadline: deadline) == process.identity.pid else {
                throw MessagesReactionAXError.targetDrift
            }
            guard try search.role(deadline: deadline) == "AXTextField",
                  try search.subrole(deadline: deadline) == "AXSearchField" else { continue }
            guard let parent = try search.parent(deadline: deadline),
                  try parent.processIdentifier(deadline: deadline) == process.identity.pid,
                  try parent.role(deadline: deadline) == "AXPopover" else {
                throw MessagesReactionAXError.targetDrift
            }
            if !matches.contains(where: { $0.search.sameIdentity(as: search) && $0.popover.sameIdentity(as: parent) }) {
                matches.append((search, parent))
            }
        }
        guard matches.count <= 1 else { throw MessagesReactionAXError.reactionUnavailable }
        let after = try canonicalMessagesProcess(deadline: deadline)
        guard after.identity == process.identity, after.root.sameIdentity(as: process.root) else {
            throw MessagesReactionAXError.targetDrift
        }
        return matches.first?.popover
    }

    private func identity(_ app: NSRunningApplication) throws -> MessagesAXProcessIdentity {
        guard !app.isTerminated, app.bundleIdentifier == Self.bundleIdentifier,
              app.bundleURL?.standardizedFileURL == Self.applicationURL,
              let date = app.launchDate, app.processIdentifier > 0 else { throw MessagesReactionAXError.targetDrift }
        return MessagesAXProcessIdentity(pid: app.processIdentifier, bundleURL: Self.applicationURL, launchDate: date)
    }

    // Separate pure selection seam also exercises duplicate/relaunch cases in tests.
    static func uniqueIdentity(_ identities: [MessagesAXProcessIdentity]) throws -> MessagesAXProcessIdentity {
        guard identities.count == 1, let identity = identities.first,
              identity.pid > 0, identity.bundleURL == applicationURL else { throw MessagesReactionAXError.targetDrift }
        return identity
    }

    private final class OpenResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<MessagesAXProcessIdentity, MessagesReactionAXError>?
        func set(_ value: Result<MessagesAXProcessIdentity, MessagesReactionAXError>) {
            lock.lock(); defer { lock.unlock() }; result = value
        }
        func get() -> Result<MessagesAXProcessIdentity, MessagesReactionAXError>? {
            lock.lock(); defer { lock.unlock() }; return result
        }
    }

    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess {
        try checkDeadline(deadline)
        guard Bundle(url: Self.applicationURL)?.bundleIdentifier == Self.bundleIdentifier else {
            throw MessagesReactionAXError.targetDrift
        }
        let existing = try NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).map(identity)
        guard existing.count <= 1 else { throw MessagesReactionAXError.targetDrift }
        let result = OpenResult()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        try checkDeadline(deadline)
        NSWorkspace.shared.open([url], withApplicationAt: Self.applicationURL, configuration: configuration) { app, error in
            guard error == nil, let app, !app.isTerminated, app.bundleIdentifier == Self.bundleIdentifier,
                  app.bundleURL?.standardizedFileURL == Self.applicationURL, let date = app.launchDate else {
                result.set(.failure(.targetDrift)); return
            }
            result.set(.success(MessagesAXProcessIdentity(pid: app.processIdentifier,
                                                          bundleURL: Self.applicationURL, launchDate: date)))
        }
        // Pump only LaunchServices completion, never sleep to guess UI selection.
        while result.get() == nil {
            try checkDeadline(deadline)
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        try checkDeadline(deadline)
        guard let completed = result.get() else { throw MessagesReactionAXError.targetDrift }
        let opened = try completed.get()
        let process = try canonicalMessagesProcess(deadline: deadline)
        guard process.identity == opened, existing.first == nil || existing.first == opened else {
            throw MessagesReactionAXError.targetDrift
        }
        return process
    }

    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess {
        try checkDeadline(deadline)
        let identities = try NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).map(identity)
        let identity = try Self.uniqueIdentity(identities)
        try checkDeadline(deadline)
        return MessagesAXProcess(identity: identity, root: LiveAXElement(element: AXUIElementCreateApplication(identity.pid)))
    }
}

// CharacterPicker SPI selector shape follows the Beeper attribution recorded in NOTICE.
enum CustomEmojiSearchResolver {
    static func searchPlan(for emoji: String, deadline: WorkerDeadline) throws -> MessagesCustomEmojiSearchPlan {
        try checkDeadline(deadline)
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework"),
              bundle.load(),
              let cls = NSClassFromString("CPKDefaultDataSource") as? NSObject.Type else {
            throw MessagesReactionAXError.unknownAXValue
        }
        try checkDeadline(deadline)
        let selector = NSSelectorFromString("localizedCharacterName:")
        guard let method = class_getClassMethod(cls, selector),
              method_getNumberOfArguments(method) == 3,
              Self.copyType({ method_copyReturnType(method) }) == "@",
              Self.copyType({ method_copyArgumentType(method, 0) }) == "@",
              Self.copyType({ method_copyArgumentType(method, 1) }) == ":",
              Self.copyType({ method_copyArgumentType(method, 2) }) == "@" else {
            throw MessagesReactionAXError.unknownAXValue
        }
        try checkDeadline(deadline)
        guard cls.responds(to: selector),
              let localizedName = cls.perform(selector, with: emoji)?.takeUnretainedValue() as? String,
              !localizedName.isEmpty, localizedName.utf8.count <= 256 else {
            throw MessagesReactionAXError.unknownAXValue
        }
        let queries = [localizedName, localizedName.replacingOccurrences(of: "flag of ", with: ""),
                       localizedName.split(separator: " ").first.map(String.init), "flag"].compactMap { $0 }
        let skinTone = try supportsSkinToneVariants(emoji: emoji, deadline: deadline)
        for query in queries where MessagesReactionActionTitleResolver.valid(query) {
            let results = try pickerResults(query: query, objectClass: cls, deadline: deadline)
            if let position = try exactPosition(in: results, emoji: emoji) {
                return MessagesCustomEmojiSearchPlan(query: query, position: position, supportsSkinToneVariants: skinTone)
            }
        }
        throw MessagesReactionAXError.reactionUnavailable
    }

    static func exactPosition(in results: [String], emoji: String) throws -> Int? {
        guard results.count <= 256 else { throw MessagesReactionAXError.reactionUnavailable }
        let positions = results.indices.filter { results[$0].utf8.elementsEqual(emoji.utf8) }
        guard positions.count <= 1 else { throw MessagesReactionAXError.reactionUnavailable }
        return positions.first
    }

    private static func pickerResults(query: String, objectClass: NSObject.Type, deadline: WorkerDeadline) throws -> [String] {
        try checkDeadline(deadline)
        let languageSelector = NSSelectorFromString("preferredLanguagesForSearch")
        let searchSelector = NSSelectorFromString("emojiTokensForSearchString:inLanguages:maxResults:usingBlock:")
        guard let languageMethod = class_getClassMethod(objectClass, languageSelector),
              method_getNumberOfArguments(languageMethod) == 2,
              Self.copyType({ method_copyReturnType(languageMethod) }) == "@",
              Self.copyType({ method_copyArgumentType(languageMethod, 0) }) == "@",
              Self.copyType({ method_copyArgumentType(languageMethod, 1) }) == ":",
              let searchMethod = class_getClassMethod(objectClass, searchSelector),
              method_getNumberOfArguments(searchMethod) == 6,
              Self.copyType({ method_copyReturnType(searchMethod) }) == "v",
              Self.copyType({ method_copyArgumentType(searchMethod, 0) }) == "@",
              Self.copyType({ method_copyArgumentType(searchMethod, 1) }) == ":",
              Self.copyType({ method_copyArgumentType(searchMethod, 2) }) == "@",
              Self.copyType({ method_copyArgumentType(searchMethod, 3) }) == "@",
              Self.copyType({ method_copyArgumentType(searchMethod, 4) }) == "Q",
              Self.copyType({ method_copyArgumentType(searchMethod, 5) }) == "@?" else {
            throw MessagesReactionAXError.unknownAXValue
        }
        typealias LanguagesIMP = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let languageIMP = unsafeBitCast(method_getImplementation(languageMethod), to: LanguagesIMP.self)
        guard let languagesObject = languageIMP(objectClass, languageSelector)?.takeUnretainedValue(),
              CFGetTypeID(languagesObject) == CFArrayGetTypeID() else {
            throw MessagesReactionAXError.unknownAXValue
        }
        let lock = NSLock()
        var output: [String]?
        var completed = false
        let semaphore = DispatchSemaphore(value: 0)
        let block: @convention(block) (AnyObject?, Bool) -> Void = { results, _ in
            lock.lock()
            guard !completed else { lock.unlock(); return }
            defer { completed = true; lock.unlock(); semaphore.signal() }
            guard let values = try? checkedPickerTokenStrings(results) else { return }
            output = values
        }
        typealias SearchIMP = @convention(c) (AnyClass, Selector, NSString, AnyObject, UInt, AnyObject) -> Void
        let searchIMP = unsafeBitCast(method_getImplementation(searchMethod), to: SearchIMP.self)
        let invocation = PickerSearchInvocation(objectClass: objectClass, selector: searchSelector, query: query,
                                                languages: languagesObject, block: block as AnyObject, imp: searchIMP)
        let waitNanoseconds = min(deadline.remainingNanoseconds, 2_000_000_000)
        guard waitNanoseconds > 0 else { throw MessagesReactionAXError.unknownAXValue }
        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async { invocation.run() }
            let start = DispatchTime.now().uptimeNanoseconds
            while true {
                try checkDeadline(deadline)
                if semaphore.wait(timeout: .now()) == .success { break }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now >= start, now - start < waitNanoseconds else {
                    lock.lock(); completed = true; lock.unlock()
                    throw MessagesReactionAXError.unknownAXValue
                }
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        } else {
            invocation.run()
            guard semaphore.wait(timeout: DispatchTime.now() + .nanoseconds(Int(waitNanoseconds))) == .success else {
                lock.lock(); completed = true; lock.unlock()
                throw MessagesReactionAXError.unknownAXValue
            }
        }
        lock.lock(); let result = output; lock.unlock()
        guard let result else { throw MessagesReactionAXError.unknownAXValue }
        try checkDeadline(deadline)
        return result
    }

    static func checkedPickerTokenStrings(_ results: AnyObject?) throws -> [String] {
        let stringSelector = NSSelectorFromString("string")
        guard let results, CFGetTypeID(results) == CFArrayGetTypeID() else { throw MessagesReactionAXError.unknownAXValue }
        let raw = results as! CFArray
        guard CFArrayGetCount(raw) <= 256 else { throw MessagesReactionAXError.unknownAXValue }
        var values: [String] = []
        for item in (results as! [AnyObject]) {
            guard let method = class_getInstanceMethod(type(of: item), stringSelector),
                  method_getNumberOfArguments(method) == 2,
                  Self.copyType({ method_copyReturnType(method) }) == "@",
                  Self.copyType({ method_copyArgumentType(method, 0) }) == "@",
                  Self.copyType({ method_copyArgumentType(method, 1) }) == ":",
                  item.responds(to: stringSelector),
                  let value = item.perform(stringSelector)?.takeUnretainedValue() as? String,
                  !value.isEmpty, value.utf8.count <= 128 else { throw MessagesReactionAXError.unknownAXValue }
            values.append(value)
        }
        return values
    }

    private static func supportsSkinToneVariants(emoji: String, deadline: WorkerDeadline) throws -> Bool {
        try checkDeadline(deadline)
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework"),
              bundle.load(),
              let cls = NSClassFromString("EMFEmojiToken") as? NSObject.Type else { throw MessagesReactionAXError.unknownAXValue }
        let initSelector = NSSelectorFromString("initWithString:localeIdentifier:")
        guard let initMethod = class_getInstanceMethod(cls, initSelector),
              method_getNumberOfArguments(initMethod) == 4,
              Self.copyType({ method_copyReturnType(initMethod) }) == "@",
              Self.copyType({ method_copyArgumentType(initMethod, 0) }) == "@",
              Self.copyType({ method_copyArgumentType(initMethod, 1) }) == ":",
              Self.copyType({ method_copyArgumentType(initMethod, 2) }) == "@",
              Self.copyType({ method_copyArgumentType(initMethod, 3) }) == "@" else { throw MessagesReactionAXError.unknownAXValue }
        guard let allocated = class_createInstance(cls, 0) as AnyObject? else { throw MessagesReactionAXError.unknownAXValue }
        let initializerOwned = Unmanaged.passRetained(allocated)
        typealias InitIMP = @convention(c) (AnyObject, Selector, NSString, NSString) -> Unmanaged<AnyObject>?
        let initIMP = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)
        guard let token = initIMP(initializerOwned.takeUnretainedValue(), initSelector, emoji as NSString,
                                  Locale.current.identifier as NSString)?.takeRetainedValue() else {
            throw MessagesReactionAXError.unknownAXValue
        }
        let supportSelector = NSSelectorFromString("supportsSkinToneVariants")
        guard let supportMethod = class_getInstanceMethod(type(of: token), supportSelector),
              method_getNumberOfArguments(supportMethod) == 2,
              Self.copyType({ method_copyReturnType(supportMethod) }) == "B",
              Self.copyType({ method_copyArgumentType(supportMethod, 0) }) == "@",
              Self.copyType({ method_copyArgumentType(supportMethod, 1) }) == ":" else {
            throw MessagesReactionAXError.unknownAXValue
        }
        typealias SupportsIMP = @convention(c) (AnyObject, Selector) -> Bool
        let supportIMP = unsafeBitCast(method_getImplementation(supportMethod), to: SupportsIMP.self)
        try checkDeadline(deadline)
        return supportIMP(token, supportSelector)
    }

    private static func copyType(_ producer: () -> UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer = producer() else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

private final class PickerSearchInvocation: @unchecked Sendable {
    typealias SearchIMP = @convention(c) (AnyClass, Selector, NSString, AnyObject, UInt, AnyObject) -> Void
    let objectClass: AnyClass
    let selector: Selector
    let query: NSString
    let languages: AnyObject
    let block: AnyObject
    let imp: SearchIMP

    init(objectClass: AnyClass, selector: Selector, query: String, languages: AnyObject, block: AnyObject, imp: @escaping SearchIMP) {
        self.objectClass = objectClass
        self.selector = selector
        self.query = query as NSString
        self.languages = languages
        self.block = block
        self.imp = imp
    }

    func run() {
        imp(objectClass, selector, query, languages, 256, block)
    }
}

enum MessagesPairedKeyFlags: Equatable {
    case preserved
    case cleared
}

enum MessagesPairedKeyPressError: Error {
    case deadlineExpired
    case axFailure
}

struct PairedMessagesKeyPress {
    let postDown: () -> Void
    let postUp: () -> Void
    let postRequiredExtraKeyUp: () -> Void
}

typealias PairedCustomEmojiKeyPress = PairedMessagesKeyPress

private final class MainThreadMessagesKeyPressAction: @unchecked Sendable {
    private let action: () throws -> Void

    init(_ action: @escaping () throws -> Void) {
        self.action = action
    }

    func run() throws {
        try action()
    }
}

struct LiveMessagesPairedKeyPresser {
    let pid: pid_t
    var operatingSystemMajorVersion: () -> Int = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
    var makePairedKeyPress: (CGKeyCode, pid_t, MessagesPairedKeyFlags) throws -> PairedMessagesKeyPress = Self.makeLivePairedKeyPress

    func pressReturn(flags: MessagesPairedKeyFlags, deadline: WorkerDeadline) throws {
        try press(CGKeyCode(kVK_Return), flags: flags, deadline: deadline)
    }

    func press(_ code: CGKeyCode, flags: MessagesPairedKeyFlags, deadline: WorkerDeadline) throws {
        try checkPairedKeyDeadline(deadline)
        let pairedKeyPress = try makePairedKeyPress(code, pid, flags)
        let action = {
            try checkPairedKeyDeadline(deadline)
            pairedKeyPress.postDown()
            pairedKeyPress.postUp()
            if self.operatingSystemMajorVersion() >= 15 {
                pairedKeyPress.postRequiredExtraKeyUp()
            }
            try checkPairedKeyDeadline(deadline)
        }
        if Thread.isMainThread {
            try action()
        } else {
            let mainAction = MainThreadMessagesKeyPressAction(action)
            var result: Result<Void, MessagesPairedKeyPressError> = .success(())
            DispatchQueue.main.sync {
                result = Result { try mainAction.run() }.mapError { error in
                    error as? MessagesPairedKeyPressError ?? .axFailure
                }
            }
            try result.get()
        }
        try checkPairedKeyDeadline(deadline)
    }

    private static func makeLivePairedKeyPress(code: CGKeyCode, pid: pid_t, flags: MessagesPairedKeyFlags) throws -> PairedMessagesKeyPress {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let downEvent = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw MessagesPairedKeyPressError.axFailure
        }
        if flags == .cleared {
            downEvent.flags = []
            upEvent.flags = []
        }
        return PairedMessagesKeyPress(
            postDown: { downEvent.postToPid(pid) },
            postUp: { upEvent.postToPid(pid) },
            postRequiredExtraKeyUp: {
                upEvent.flags = []
                upEvent.postToPid(pid)
            }
        )
    }
}

private func checkPairedKeyDeadline(_ deadline: WorkerDeadline) throws {
    guard !deadline.expired else { throw MessagesPairedKeyPressError.deadlineExpired }
}

struct LiveCustomEmojiKeyPresser {
    let pid: pid_t
    var operatingSystemMajorVersion: () -> Int = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
    var makePairedKeyPress: (CGKeyCode, pid_t) throws -> PairedCustomEmojiKeyPress = { code, pid in
        try LiveMessagesPairedKeyPresser.makeLivePairedKeyPressForCompatibility(code: code, pid: pid)
    }

    func press(_ key: MessagesCustomEmojiChooserKey, deadline: WorkerDeadline) throws {
        try checkDeadline(deadline)
        let code: CGKeyCode
        switch key {
        case .downArrow: code = CGKeyCode(kVK_DownArrow)
        case .rightArrow: code = CGKeyCode(kVK_RightArrow)
        case .returnKey: code = CGKeyCode(kVK_Return)
        }
        let presser = LiveMessagesPairedKeyPresser(pid: pid, operatingSystemMajorVersion: operatingSystemMajorVersion,
                                                   makePairedKeyPress: { code, pid, _ in try makePairedKeyPress(code, pid) })
        do { try presser.press(code, flags: .preserved, deadline: deadline) }
        catch MessagesPairedKeyPressError.deadlineExpired { throw MessagesReactionAXError.deadlineExpired }
        catch { throw MessagesReactionAXError.axFailure }
    }
}

extension LiveMessagesPairedKeyPresser {
    static func makeLivePairedKeyPressForCompatibility(code: CGKeyCode, pid: pid_t) throws -> PairedMessagesKeyPress {
        try makeLivePairedKeyPress(code: code, pid: pid, flags: .preserved)
    }
}
