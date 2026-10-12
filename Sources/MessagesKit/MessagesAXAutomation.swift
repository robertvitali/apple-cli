import ApplicationServices
import AppKit
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
    var description: String { rawValue }
}

private func checkDeadline(_ deadline: WorkerDeadline) throws {
    guard !deadline.expired else { throw MessagesReactionAXError.deadlineExpired }
}

// Every remote property access is explicit, throwing and deadline-bound. Nil
protocol MessagesAXElement: AnyObject {
    func sameIdentity(as other: any MessagesAXElement) -> Bool
    func role(deadline: WorkerDeadline) throws -> String
    func identifier(deadline: WorkerDeadline) throws -> String?
    func selected(deadline: WorkerDeadline) throws -> Bool?
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
    func actions(deadline: WorkerDeadline) throws -> [String]
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]
    func performAction(named name: String, deadline: WorkerDeadline) throws
}

struct MessagesAXProcessIdentity: Equatable {
    let pid: Int32
    let bundleURL: URL
    let launchDate: Date
}

struct MessagesAXProcess {
    let identity: MessagesAXProcessIdentity
    let root: any MessagesAXElement
}

protocol MessagesReactionAXDriving: AnyObject {
    func checkAccessibilityTrusted(prompt: Bool) -> Bool
    func reactActionTitles(deadline: WorkerDeadline) throws -> [String]
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess
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

    private struct Route {
        let process: MessagesAXProcess
        let window: any MessagesAXElement
        let transcript: any MessagesAXElement
        let selected: any MessagesAXElement
    }
    private enum PostPressPickerState {
        case present
        case absent
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
    }
    private struct StagedAXFailure: Error {
        let stage: AXFailureStage
    }

    func apply(_ request: MessagesReactionRequest, deadline: WorkerDeadline) throws -> MessagesReactionAXOutcome {
        do { return try execute(request, deadline: deadline) }
        catch let error as StagedAXFailure { return .failed(error.stage.rawValue) }
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
            let route = try captureRoute(process: process, titles: titles, deadline: deadline)
            try revalidate(route, titles: titles, deadline: deadline)
            guard let action = try reactAction(on: route.selected, titles: titles, deadline: deadline) else {
                throw MessagesReactionAXError.targetDrift
            }
            try checkDeadline(deadline)
            stage = .menuOpen
            try route.selected.performAction(named: action, deadline: deadline)
            try checkDeadline(deadline)

            // Exact picker identity is the sole custom route. No chooser, search,
            // skin-tone folding, character picker, or positional fallback exists.
            stage = .pickerReadiness
            let (picker, button, initialSelected) = try waitForPickerButton(route: route, titles: titles,
                                                                            identifier: request.reaction.pickerIdentifier,
                                                                            experimentalUIHandoff: request.experimentalUIHandoff,
                                                                            deadline: deadline)
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
                                                        originalRoute: route, desiredSelected: desiredSelected, deadline: deadline)
            return .ack(MessagesReactionACKDetail.verified(operation: request.operation, changed: true))
        } catch MessagesReactionAXError.axFailure {
            throw StagedAXFailure(stage: stage)
        } catch let error as MessagesReactionAXError {
            throw error
        } catch {
            // Never expose native AX transport errors or values.
            throw StagedAXFailure(stage: stage)
        }
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
        try checkProcess(process, deadline: deadline)
        let windows = try collect(from: process.root, deadline: deadline) { _, role, _ in
            role == "AXWindow"
        }
        var candidates: [(any MessagesAXElement, any MessagesAXElement)] = []
        for window in windows {
            let transcripts = try collect(from: window, window: window, deadline: deadline) { _, role, identifier in
                // macOS 27 exposes AXGroup. Retain the previous AXCollection
                // shape only with the same exact native transcript identifier.
                (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
            }
            candidates.append(contentsOf: transcripts.map { (window, $0) })
        }
        guard candidates.count == 1 else { throw MessagesReactionAXError.targetDrift }
        let (window, transcript) = candidates[0]
        let messages = try collect(from: transcript, window: window, deadline: deadline) { element, _, _ in
            guard try reactAction(on: element, titles: titles, deadline: deadline) != nil else { return false }
            guard let selected = try element.selected(deadline: deadline) else {
                throw MessagesReactionAXError.unknownAXValue
            }
            return selected
        }
        guard messages.count == 1 else {
            throw messages.isEmpty ? MessagesReactionAXError.targetDrift : .ambiguousSelectedMessage
        }
        return Route(process: process, window: window, transcript: transcript, selected: messages[0])
    }

    private func checkProcess(_ expected: MessagesAXProcess, deadline: WorkerDeadline) throws {
        try checkDeadline(deadline)
        let current = try driver.canonicalMessagesProcess(deadline: deadline)
        guard current.identity == expected.identity, expected.root.sameIdentity(as: current.root) else {
            throw MessagesReactionAXError.targetDrift
        }
        try checkDeadline(deadline)
    }

    private func revalidate(_ route: Route, titles: [String], deadline: WorkerDeadline) throws {
        let current = try captureRoute(process: route.process, titles: titles, deadline: deadline)
        guard route.window.sameIdentity(as: current.window),
              route.transcript.sameIdentity(as: current.transcript),
              route.selected.sameIdentity(as: current.selected) else { throw MessagesReactionAXError.targetDrift }
        try checkDeadline(deadline)
    }
    private func waitForRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                          originalRoute: Route, deadline: WorkerDeadline) throws -> Route {
        let started = readinessNow()
        let cap: UInt64 = 8_000_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(8_000)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        for attempt in 0...160 {
            try checkDeadline(deadline)
            if readDeadline.expired { throw MessagesReactionAXError.postPressVerifyRouteDrift }
            if let route = try availableRetainedRouteAfterPickerDismissal(process: process, titles: titles,
                                                                          originalRoute: originalRoute,
                                                                          requirePickerAbsent: false,
                                                                          deadline: readDeadline) {
                return route
            }
            guard attempt < 160 else { throw MessagesReactionAXError.postPressVerifyRouteDrift }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesReactionAXError.postPressVerifyRouteDrift }
            let pause = min(50_000_000, cap - (now - started), readDeadline.remainingNanoseconds)
            readinessPause(pause)
        }
        throw MessagesReactionAXError.postPressVerifyRouteDrift
    }

    private func requireRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                          originalRoute: Route, deadline: WorkerDeadline) throws -> Route {
        guard let route = try availableRetainedRouteAfterPickerDismissal(process: process, titles: titles,
                                                                         originalRoute: originalRoute,
                                                                         requirePickerAbsent: true,
                                                                         deadline: deadline) else {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        }
        return route
    }

    private func availableRetainedRouteAfterPickerDismissal(process: MessagesAXProcess, titles: [String],
                                                            originalRoute: Route, requirePickerAbsent: Bool,
                                                            deadline: WorkerDeadline) throws -> Route? {
        do {
            try checkProcess(process, deadline: deadline)
            let windows = try collect(from: process.root, deadline: deadline) { _, role, _ in
                role == "AXWindow"
            }
            guard windows.count == 1, let window = windows.first, window.sameIdentity(as: originalRoute.window) else {
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            if requirePickerAbsent, try availablePicker(in: window, deadline: deadline) != nil {
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            let transcripts = try collect(from: window, window: window, deadline: deadline) { _, role, identifier in
                (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
            }
            guard !transcripts.isEmpty else { return nil }
            guard transcripts.count == 1, let transcript = transcripts.first,
                  transcript.sameIdentity(as: originalRoute.transcript) else {
                throw MessagesReactionAXError.postPressVerifyRouteDrift
            }
            let messages = try collect(from: transcript, window: window, deadline: deadline) { element, _, _ in
                guard element.sameIdentity(as: originalRoute.selected) else { return false }
                guard try reactAction(on: element, titles: titles, deadline: deadline) != nil else {
                    throw MessagesReactionAXError.postPressVerifyActionMissing
                }
                return true
            }
            guard !messages.isEmpty else { return nil }
            guard messages.count == 1 else { throw MessagesReactionAXError.postPressVerifyRouteDrift }
            return Route(process: process, window: window, transcript: transcript, selected: messages[0])
        } catch MessagesReactionAXError.postPressVerifyActionMissing {
            throw MessagesReactionAXError.postPressVerifyActionMissing
        } catch MessagesReactionAXError.postPressVerifyRouteDrift {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        } catch MessagesReactionAXError.targetDrift {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        } catch MessagesReactionAXError.pickerUnavailable {
            throw MessagesReactionAXError.postPressVerifyRouteDrift
        } catch MessagesReactionAXError.ambiguousSelectedMessage {
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
                                                         deadline: WorkerDeadline) throws {
        _ = try waitForRetainedRouteAfterPickerDismissal(process: originalRoute.process, titles: titles,
                                                         originalRoute: originalRoute, deadline: deadline)
        let route = try requireRetainedRouteAfterPickerDismissal(process: originalRoute.process, titles: titles,
                                                                 originalRoute: originalRoute, deadline: deadline)
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
        } catch MessagesReactionAXError.targetDrift {
            throw MessagesReactionAXError.postPressVerifyPickerStateDrift
        }
        let selected: Bool
        do {
            selected = try validatePostMenuPicker(route: route, titles: titles, picker: picker, button: button,
                                                  initialSelected: initialSelected,
                                                  identifier: request.reaction.pickerIdentifier,
                                                  experimentalUIHandoff: request.experimentalUIHandoff,
                                                  deadline: deadline)
        } catch MessagesReactionAXError.targetDrift {
            throw MessagesReactionAXError.postPressVerifyPickerStateDrift
        }
        guard selected == desiredSelected else { throw MessagesReactionAXError.postPressVerifyPickerStateDrift }
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
        try checkProcess(route.process, deadline: deadline)
        let windows = try collect(from: route.process.root, deadline: deadline) { _, role, _ in
            role == "AXWindow"
        }
        guard windows.count == 1, let window = windows.first, window.sameIdentity(as: route.window) else {
            throw MessagesReactionAXError.targetDrift
        }
        return window
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
        guard picker.sameIdentity(as: currentPicker) else { throw MessagesReactionAXError.targetDrift }
        let currentButton = try uniqueButton(in: currentPicker, window: window, identifier: identifier, deadline: deadline)
        guard button.sameIdentity(as: currentButton),
              let selected = try button.selected(deadline: deadline), selected == initialSelected else {
            throw MessagesReactionAXError.targetDrift
        }
        return selected
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
        }
        throw unavailable
    }

    private func availablePicker(in root: any MessagesAXElement, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        let matches = try collect(from: root, window: root, deadline: deadline) { _, _, identifier in
            identifier == "TapbackPickerCollectionView"
        }
        guard matches.count <= 1 else { throw MessagesReactionAXError.pickerUnavailable }
        return matches.first
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
        guard maxTraversalNodes > 0, maxTraversalDepth >= 0, maxChildren >= 0 else {
            throw MessagesReactionAXError.traversalLimit
        }
        // Breadth-first discovery bounds shortest-path depth, not an accidental
        // longer route through a cycle. Retain actual AX identities (CFEqual in
        // LiveAXElement), including queued nodes, rather than wrapper identities.
        var discovered: [(element: any MessagesAXElement, depth: Int)] = [(root, 0)]
        var cursor = 0
        var matches: [any MessagesAXElement] = []
        while cursor < discovered.count {
            try checkDeadline(deadline)
            let (next, depth) = discovered[cursor]
            cursor += 1
            let role = try next.role(deadline: deadline)
            let identifier = try next.identifier(deadline: deadline)
            guard role.utf8.count <= 128, identifier.map({ $0.utf8.count <= 2048 }) ?? true else {
                throw MessagesReactionAXError.unknownAXValue
            }
            if try predicate(next, role, identifier) {
                // Linked UI elements establish reachability, not containment.
                // Require the actual match's AXWindow, including for direct
                // links that never pass through a foreign AXWindow node.
                if let window {
                    guard let owner = try next.window(deadline: deadline) else {
                        throw MessagesReactionAXError.unknownAXValue
                    }
                    try checkDeadline(deadline)
                    guard owner.sameIdentity(as: window) else { throw MessagesReactionAXError.targetDrift }
                }
                matches.append(next)
            }
            try checkDeadline(deadline)
            let children = try next.children(limit: maxChildren, deadline: deadline)
            try checkDeadline(deadline)
            guard children.count <= maxChildren else { throw MessagesReactionAXError.traversalLimit }
            let remaining = maxChildren - children.count
            let linked = try next.linkedElements(limit: remaining, deadline: deadline)
            try checkDeadline(deadline)
            guard linked.count <= remaining else { throw MessagesReactionAXError.traversalLimit }
            // The edge cap counts both relationships, even duplicate edges;
            // node/depth limits count only distinct discovered identities.
            for candidate in children + linked {
                let known = try discovered.contains { entry in
                    try checkDeadline(deadline)
                    return entry.element.sameIdentity(as: candidate)
                }
                if known { continue }
                guard discovered.count < maxTraversalNodes, depth < maxTraversalDepth else {
                    throw MessagesReactionAXError.traversalLimit
                }
                discovered.append((candidate, depth + 1))
            }
        }
        try checkDeadline(deadline)
        return matches
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

final class LiveAXElement: MessagesAXElement {
    private let element: AXUIElement
    init(element: AXUIElement) { self.element = element }

    func sameIdentity(as other: any MessagesAXElement) -> Bool {
        guard let other = other as? LiveAXElement else { return false }
        return CFEqual(element, other.element)
    }

    private func prepare(_ deadline: WorkerDeadline) throws {
        try checkDeadline(deadline)
        // 0.30 leaves room below the required 0.35 maximum, including Float rounding.
        let timeout = Float(min(0.30, Double(deadline.remainingNanoseconds) / 1_000_000_000 / 2))
        guard timeout > 0, AXUIElementSetMessagingTimeout(element, timeout) == .success else {
            throw MessagesReactionAXError.axFailure
        }
        try checkDeadline(deadline)
    }

    private func attribute(_ name: String, deadline: WorkerDeadline) throws -> CFTypeRef? {
        try prepare(deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try checkDeadline(deadline)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw MessagesReactionAXError.axFailure }
        return value
    }

    func role(deadline: WorkerDeadline) throws -> String {
        guard let value = try attribute(kAXRoleAttribute, deadline: deadline) else {
            throw MessagesReactionAXError.unknownAXValue
        }
        return try Self.checkedString(value, limit: 128)
    }

    func identifier(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXIdentifierAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 2048)
    }

    func selected(deadline: WorkerDeadline) throws -> Bool? {
        try Self.checkedBoolean(attribute(kAXSelectedAttribute, deadline: deadline))
    }

    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try prepare(deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value)
        try checkDeadline(deadline)
        return try Self.checkedWindow(status: status, value: value)
    }

    static func checkedWindow(status: AXError, value: CFTypeRef?) throws -> LiveAXElement? {
        if status == .attributeUnsupported || status == .noValue { return nil }
        if status == .notImplemented { throw MessagesReactionAXError.unknownAXValue }
        guard status == .success else { throw MessagesReactionAXError.axFailure }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw MessagesReactionAXError.unknownAXValue
        }
        return LiveAXElement(element: value as! AXUIElement)
    }

    static func checkedBoolean(_ value: CFTypeRef?) throws -> Bool? {
        guard let value else { return nil }
        // NSNumber's bridging can turn arbitrary numbers into Bool. AXSelected
        // must actually be a CFBoolean; neither a string nor 0/1 is evidence.
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw MessagesReactionAXError.unknownAXValue }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func checkedString(_ value: CFTypeRef, limit: Int) throws -> String {
        guard CFGetTypeID(value) == CFStringGetTypeID(),
              CFStringGetLength(value as! CFString) <= limit,
              let string = value as? String, string.utf8.count <= limit else {
            throw MessagesReactionAXError.unknownAXValue
        }
        return string
    }

    func actions(deadline: WorkerDeadline) throws -> [String] {
        try prepare(deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        try checkDeadline(deadline)
        return try Self.checkedActions(status: status, names: names)
    }

    static func checkedActions(status: AXError, names: CFArray?) throws -> [String] {
        // Explicit absence on a noninteractive node is not a transport failure.
        // NotImplemented is broader (incomplete process AX support per the SDK):
        // refuse unknown evidence instead of treating it as an empty action list.
        if status == .actionUnsupported || status == .attributeUnsupported || status == .noValue { return [] }
        if status == .notImplemented { throw MessagesReactionAXError.unknownAXValue }
        guard status == .success else { throw MessagesReactionAXError.axFailure }
        guard let names, CFArrayGetCount(names) <= 128 else { throw MessagesReactionAXError.unknownAXValue }
        return try (names as [AnyObject]).map { try checkedString($0, limit: 2048) }
    }

    static func validateChildCount(status: AXError, count: CFIndex, limit: Int) throws {
        _ = try relationshipCount(status: status, count: count, limit: limit)
    }

    private static func relationshipCount(status: AXError, count: CFIndex, limit: Int) throws -> Int {
        guard limit >= 0 else { throw MessagesReactionAXError.traversalLimit }
        if status == .attributeUnsupported || status == .noValue { return 0 }
        guard status == .success, count >= 0 else { throw MessagesReactionAXError.axFailure }
        guard count <= limit else { throw MessagesReactionAXError.traversalLimit }
        return count
    }

    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try relationship(kAXChildrenAttribute, limit: limit, deadline: deadline)
    }

    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try relationship(kAXLinkedUIElementsAttribute, limit: limit, deadline: deadline)
    }

    private func relationship(_ name: String, limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        func count() throws -> Int {
            try prepare(deadline)
            var value: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(element, name as CFString, &value)
            try checkDeadline(deadline)
            return try Self.relationshipCount(status: status, count: value, limit: limit)
        }
        let initialCount = try count()
        var values: [AnyObject] = []
        if initialCount > 0 {
            try prepare(deadline)
            var array: CFArray?
            let status = AXUIElementCopyAttributeValues(element, name as CFString, 0, initialCount, &array)
            try checkDeadline(deadline)
            // A relation that vanished after a positive count changed under us.
            if status == .attributeUnsupported || status == .noValue { throw MessagesReactionAXError.targetDrift }
            guard status == .success else { throw MessagesReactionAXError.axFailure }
            guard let array, CFArrayGetCount(array) == initialCount else { throw MessagesReactionAXError.targetDrift }
            values = array as [AnyObject]
        }
        // Recheck even empty/unsupported relations so a newly appearing edge
        // cannot turn an incomplete scan into uniqueness evidence.
        guard try count() == initialCount else { throw MessagesReactionAXError.targetDrift }
        return try values.map { value in
            try checkDeadline(deadline)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MessagesReactionAXError.unknownAXValue }
            return LiveAXElement(element: value as! AXUIElement)
        }
    }

    func performAction(named name: String, deadline: WorkerDeadline) throws {
        try prepare(deadline)
        let status = AXUIElementPerformAction(element, name as CFString)
        try checkDeadline(deadline)
        guard status == .success else { throw MessagesReactionAXError.axFailure }
    }
}
