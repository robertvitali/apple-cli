import ApplicationServices
import Foundation
import AppleKit

// Every remote property access is explicit, throwing and deadline-bound. Nil
// relationship values are handled by the concrete adapter, not by callers.
enum MessagesAXBodyValueKind: Equatable, Sendable {
    case noValue
    case string(Int)
    case attributedString(Int)
    case unsupported
    case unknown
}

struct MessagesAXBodyValueEvidence: Equatable, Sendable {
    let valueKind: MessagesAXBodyValueKind
    let characterCount: Int?
    let placeholder: String?

    var provenEmpty: Bool {
        guard characterCount == 0 else { return false }
        switch valueKind {
        case .noValue, .string(0), .attributedString(0): return true
        case .string, .attributedString, .unsupported, .unknown: return false
        }
    }
}

protocol MessagesAXElement: AnyObject {
    func sameIdentity(as other: any MessagesAXElement) -> Bool
    func role(deadline: WorkerDeadline) throws -> String
    func identifier(deadline: WorkerDeadline) throws -> String?
    func axDescription(deadline: WorkerDeadline) throws -> String?
    func axValue(deadline: WorkerDeadline) throws -> String?
    func candidateValueText(deadline: WorkerDeadline) throws -> String?
    func axTitle(deadline: WorkerDeadline) throws -> String?
    func subrole(deadline: WorkerDeadline) throws -> String?
    func enabled(deadline: WorkerDeadline) throws -> Bool?
    func selected(deadline: WorkerDeadline) throws -> Bool?
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
    func processIdentifier(deadline: WorkerDeadline) throws -> Int32?
    func valueSettable(deadline: WorkerDeadline) throws -> Bool?
    func actions(deadline: WorkerDeadline) throws -> [String]
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]
    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]?
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]
    func setValue(_ value: String, deadline: WorkerDeadline) throws
    func focused(deadline: WorkerDeadline) throws -> Bool?
    func bodyValueEvidence(deadline: WorkerDeadline) throws -> MessagesAXBodyValueEvidence
    func performAction(named name: String, deadline: WorkerDeadline) throws
}

extension MessagesAXElement {
    func focused(deadline: WorkerDeadline) throws -> Bool? { nil }

    func bodyValueEvidence(deadline: WorkerDeadline) throws -> MessagesAXBodyValueEvidence {
        MessagesAXBodyValueEvidence(valueKind: .unknown, characterCount: nil, placeholder: nil)
    }
}

struct MessagesAXProcessIdentity: Equatable {
    let pid: Int32
    let bundleURL: URL
    let launchDate: Date
    init(pid: Int32, bundleURL: URL, launchDate: Date) {
        self.pid = pid
        self.bundleURL = bundleURL
        self.launchDate = launchDate
    }
}

struct MessagesAXProcess {
    let identity: MessagesAXProcessIdentity
    let root: any MessagesAXElement
    init(identity: MessagesAXProcessIdentity, root: any MessagesAXElement) {
        self.identity = identity
        self.root = root
    }
}

protocol MessagesAXProcessDriving: AnyObject {
    func checkAccessibilityTrusted(prompt: Bool) -> Bool
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)?
}

enum MessagesAXNavigationError: String, Error, CustomStringConvertible, CaseIterable {
    case deadlineExpired = "deadline-expired"
    case targetDrift = "target-drift"
    case ambiguousSelectedMessage = "ambiguous-selected-message"
    case unknownAXValue = "unknown-ax-value"
    case traversalLimit = "traversal-limit"
    case axFailure = "ax-failure"

    var description: String { rawValue }
}

enum MessagesAXRouteDriftReason: String {
    case relationshipCountChanged = "relationship-count-changed"
    case windowMismatch = "window-mismatch"
    case missingTranscript = "missing-transcript"
    case missingRetainedTarget = "missing-retained-message"
    case replacedTranscript = "replaced-transcript"
    case retainedTargetActionMissing = "retained-message-action-missing"
}

struct MessagesAXRouteDrift: Error {
    let reason: MessagesAXRouteDriftReason?

    init(_ reason: MessagesAXRouteDriftReason? = nil) {
        self.reason = reason
    }
}

struct MessagesAXRoute {
    let process: MessagesAXProcess
    let window: any MessagesAXElement
    let transcript: any MessagesAXElement
    let selected: any MessagesAXElement
    init(process: MessagesAXProcess, window: any MessagesAXElement, transcript: any MessagesAXElement, selected: any MessagesAXElement) {
        self.process = process
        self.window = window
        self.transcript = transcript
        self.selected = selected
    }
}

enum MessagesAXRetainedRouteDiscovery {
    case available(MessagesAXRoute)
    case unavailable(MessagesAXRouteDriftReason)
}

func checkMessagesAXDeadline(_ deadline: WorkerDeadline) throws {
    guard !deadline.expired else { throw MessagesAXNavigationError.deadlineExpired }
}

final class LiveAXElement: MessagesAXElement {
    let element: AXUIElement
    init(element: AXUIElement) { self.element = element }

    func sameIdentity(as other: any MessagesAXElement) -> Bool {
        guard let other = other as? LiveAXElement else { return false }
        return CFEqual(element, other.element)
    }

    private func prepare(_ deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        // 0.30 leaves room below the required 0.35 maximum, including Float rounding.
        let timeout = Float(min(0.30, Double(deadline.remainingNanoseconds) / 1_000_000_000 / 2))
        guard timeout > 0, AXUIElementSetMessagingTimeout(element, timeout) == .success else {
            throw MessagesAXNavigationError.axFailure
        }
        try checkMessagesAXDeadline(deadline)
    }

    private func rawAttribute(_ name: String, deadline: WorkerDeadline) throws -> (AXError, CFTypeRef?) {
        try prepare(deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try checkMessagesAXDeadline(deadline)
        return (status, value)
    }

    private func attribute(_ name: String, deadline: WorkerDeadline) throws -> CFTypeRef? {
        let (status, value) = try rawAttribute(name, deadline: deadline)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value else { throw MessagesAXNavigationError.axFailure }
        return value
    }

    func role(deadline: WorkerDeadline) throws -> String {
        guard let value = try attribute(kAXRoleAttribute, deadline: deadline) else {
            throw MessagesAXNavigationError.unknownAXValue
        }
        return try Self.checkedString(value, limit: 128)
    }

    func identifier(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXIdentifierAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 2048)
    }

    func axDescription(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXDescriptionAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 2048)
    }

    func axValue(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXValueAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 2048)
    }

    func axTitle(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXTitleAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 2048)
    }

    func candidateValueText(deadline: WorkerDeadline) throws -> String? {
        try Self.checkedCandidateValue(attribute(kAXValueAttribute, deadline: deadline))
    }

    static func checkedCandidateValue(_ value: CFTypeRef?) throws -> String? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() { return nil }
        return try checkedString(value, limit: 2048)
    }

    func subrole(deadline: WorkerDeadline) throws -> String? {
        guard let value = try attribute(kAXSubroleAttribute, deadline: deadline) else { return nil }
        return try Self.checkedString(value, limit: 128)
    }

    func enabled(deadline: WorkerDeadline) throws -> Bool? {
        try Self.checkedBoolean(attribute(kAXEnabledAttribute, deadline: deadline))
    }

    func selected(deadline: WorkerDeadline) throws -> Bool? {
        try Self.checkedBoolean(attribute(kAXSelectedAttribute, deadline: deadline))
    }

    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try elementAttribute(kAXWindowAttribute, deadline: deadline)
    }

    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try relationship(kAXWindowsAttribute, limit: limit, requireAvailable: true, deadline: deadline)
    }

    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try elementAttribute(kAXParentAttribute, deadline: deadline)
    }

    func processIdentifier(deadline: WorkerDeadline) throws -> Int32? {
        try prepare(deadline)
        var pid: pid_t = 0
        let status = AXUIElementGetPid(element, &pid)
        try checkMessagesAXDeadline(deadline)
        guard status == .success, pid > 0 else { throw MessagesAXNavigationError.axFailure }
        return pid
    }

    func valueSettable(deadline: WorkerDeadline) throws -> Bool? {
        try prepare(deadline)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        try checkMessagesAXDeadline(deadline)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw MessagesAXNavigationError.axFailure }
        return settable.boolValue
    }

    func focused(deadline: WorkerDeadline) throws -> Bool? {
        try Self.checkedBoolean(attribute(kAXFocusedAttribute, deadline: deadline))
    }

    func bodyValueEvidence(deadline: WorkerDeadline) throws -> MessagesAXBodyValueEvidence {
        let valueKind: MessagesAXBodyValueKind
        let (valueStatus, rawValue) = try rawAttribute(kAXValueAttribute, deadline: deadline)
        switch valueStatus {
        case .noValue:
            valueKind = .noValue
        case .attributeUnsupported:
            valueKind = .unsupported
        case .success:
            guard let rawValue else { throw MessagesAXNavigationError.unknownAXValue }
            if CFGetTypeID(rawValue) == CFStringGetTypeID(), let string = rawValue as? String, string.utf8.count <= 4096 {
                valueKind = .string(string.count)
            } else if let attributed = rawValue as? NSAttributedString, attributed.string.utf8.count <= 4096 {
                valueKind = .attributedString(attributed.string.count)
            } else {
                valueKind = .unknown
            }
        default:
            throw MessagesAXNavigationError.axFailure
        }
        let characterCount = try optionalIntegerAttribute("AXNumberOfCharacters", limit: 4096, deadline: deadline)
        let placeholder: String?
        if let rawPlaceholder = try attribute("AXPlaceholderValue", deadline: deadline) {
            placeholder = try Self.checkedString(rawPlaceholder, limit: 512)
        } else {
            placeholder = nil
        }
        return MessagesAXBodyValueEvidence(valueKind: valueKind, characterCount: characterCount, placeholder: placeholder)
    }

    private func optionalIntegerAttribute(_ name: String, limit: Int, deadline: WorkerDeadline) throws -> Int? {
        let (status, raw) = try rawAttribute(name, deadline: deadline)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let raw else { throw MessagesAXNavigationError.axFailure }
        return try Self.checkedInteger(raw, limit: limit)
    }

    static func checkedInteger(_ raw: CFTypeRef, limit: Int) throws -> Int {
        guard CFGetTypeID(raw) == CFNumberGetTypeID(), CFNumberIsFloatType((raw as! CFNumber)) == false else {
            throw MessagesAXNavigationError.unknownAXValue
        }
        var int64: Int64 = 0
        guard CFNumberGetValue((raw as! CFNumber), .sInt64Type, &int64), int64 >= 0, int64 <= Int64(limit) else {
            throw MessagesAXNavigationError.unknownAXValue
        }
        return Int(int64)
    }

    private func elementAttribute(_ name: String, deadline: WorkerDeadline) throws -> LiveAXElement? {
        try prepare(deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try checkMessagesAXDeadline(deadline)
        return try Self.checkedWindow(status: status, value: value)
    }

    static func checkedWindow(status: AXError, value: CFTypeRef?) throws -> LiveAXElement? {
        if status == .attributeUnsupported || status == .noValue { return nil }
        if status == .notImplemented { throw MessagesAXNavigationError.unknownAXValue }
        guard status == .success else { throw MessagesAXNavigationError.axFailure }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw MessagesAXNavigationError.unknownAXValue
        }
        return LiveAXElement(element: value as! AXUIElement)
    }

    static func checkedBoolean(_ value: CFTypeRef?) throws -> Bool? {
        guard let value else { return nil }
        // NSNumber's bridging can turn arbitrary numbers into Bool. AXSelected
        // must actually be a CFBoolean; neither a string nor 0/1 is evidence.
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw MessagesAXNavigationError.unknownAXValue }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func checkedString(_ value: CFTypeRef, limit: Int) throws -> String {
        guard CFGetTypeID(value) == CFStringGetTypeID(),
              CFStringGetLength((value as! CFString)) <= limit,
              let string = value as? String, string.utf8.count <= limit else {
            throw MessagesAXNavigationError.unknownAXValue
        }
        return string
    }

    func actions(deadline: WorkerDeadline) throws -> [String] {
        try prepare(deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        try checkMessagesAXDeadline(deadline)
        return try Self.checkedActions(status: status, names: names)
    }

    static func checkedActions(status: AXError, names: CFArray?) throws -> [String] {
        // Explicit absence on a noninteractive node is not a transport failure.
        // NotImplemented is broader (incomplete process AX support per the SDK):
        // refuse unknown evidence instead of treating it as an empty action list.
        if status == .actionUnsupported || status == .attributeUnsupported || status == .noValue { return [] }
        if status == .notImplemented { throw MessagesAXNavigationError.unknownAXValue }
        guard status == .success else { throw MessagesAXNavigationError.axFailure }
        guard let names, CFArrayGetCount(names) <= 128 else { throw MessagesAXNavigationError.unknownAXValue }
        return try (names as [AnyObject]).map { try checkedString($0, limit: 2048) }
    }

    static func validateChildCount(status: AXError, count: CFIndex, limit: Int,
                                   requireAvailable: Bool = false) throws {
        _ = try relationshipCount(status: status, count: count, limit: limit, requireAvailable: requireAvailable)
    }

    private static func relationshipCount(status: AXError, count: CFIndex, limit: Int,
                                           requireAvailable: Bool = false) throws -> Int {
        guard limit >= 0 else { throw MessagesAXNavigationError.traversalLimit }
        if status == .attributeUnsupported || status == .noValue {
            if requireAvailable { throw MessagesAXRouteDrift(.relationshipCountChanged) }
            return 0
        }
        guard status == .success, count >= 0 else { throw MessagesAXNavigationError.axFailure }
        guard count <= limit else { throw MessagesAXNavigationError.traversalLimit }
        return count
    }

    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try fullRelationship(kAXChildrenAttribute, limit: limit, deadline: deadline)
    }

    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? {
        try optionalRelationship("AXChildrenInNavigationOrder", limit: limit, deadline: deadline)
    }

    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try relationship(kAXLinkedUIElementsAttribute, limit: limit, deadline: deadline)
    }

    static func checkedFullRelationship(initialStatus: AXError, initialCount: CFIndex, copiedValue: CFTypeRef?,
                                        copyStatus: AXError, finalStatus: AXError, finalCount: CFIndex,
                                        limit: Int, requireAvailable: Bool = false) throws -> [LiveAXElement] {
        let expectedCount = try relationshipCount(status: initialStatus, count: initialCount, limit: limit,
                                                  requireAvailable: requireAvailable)
        var values: [AnyObject] = []
        if expectedCount > 0 {
            if copyStatus == .attributeUnsupported || copyStatus == .noValue {
                throw MessagesAXRouteDrift(.relationshipCountChanged)
            }
            guard copyStatus == .success else { throw MessagesAXNavigationError.axFailure }
            guard let copiedValue, CFGetTypeID(copiedValue) == CFArrayGetTypeID() else {
                throw MessagesAXNavigationError.unknownAXValue
            }
            let array = copiedValue as! CFArray
            guard CFArrayGetCount(array) == expectedCount else {
                throw MessagesAXRouteDrift(.relationshipCountChanged)
            }
            values = array as [AnyObject]
        }
        let observedCount = try relationshipCount(status: finalStatus, count: finalCount, limit: limit,
                                                  requireAvailable: requireAvailable)
        guard observedCount == expectedCount else { throw MessagesAXRouteDrift(.relationshipCountChanged) }
        return try values.map { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MessagesAXNavigationError.unknownAXValue }
            return LiveAXElement(element: value as! AXUIElement)
        }
    }

    private func fullRelationship(_ name: String, limit: Int, requireAvailable: Bool = false,
                                  deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try prepare(deadline)
        var initialCount: CFIndex = 0
        let initialStatus = AXUIElementGetAttributeValueCount(element, name as CFString, &initialCount)
        try checkMessagesAXDeadline(deadline)
        var copiedValue: CFTypeRef?
        var copyStatus: AXError = .success
        if try Self.relationshipCount(status: initialStatus, count: initialCount, limit: limit,
                                      requireAvailable: requireAvailable) > 0 {
            try prepare(deadline)
            copyStatus = AXUIElementCopyAttributeValue(element, name as CFString, &copiedValue)
            try checkMessagesAXDeadline(deadline)
        }
        try prepare(deadline)
        var finalCount: CFIndex = 0
        let finalStatus = AXUIElementGetAttributeValueCount(element, name as CFString, &finalCount)
        try checkMessagesAXDeadline(deadline)
        return try Self.checkedFullRelationship(initialStatus: initialStatus, initialCount: initialCount,
                                                copiedValue: copiedValue, copyStatus: copyStatus,
                                                finalStatus: finalStatus, finalCount: finalCount,
                                                limit: limit, requireAvailable: requireAvailable)
    }

    private func optionalRelationship(_ name: String, limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? {
        func count() throws -> Int? {
            try prepare(deadline)
            var value: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(element, name as CFString, &value)
            try checkMessagesAXDeadline(deadline)
            if status == .attributeUnsupported || status == .noValue { return nil }
            guard status == .success, value >= 0 else { throw MessagesAXNavigationError.axFailure }
            guard value <= limit else { throw MessagesAXNavigationError.traversalLimit }
            return value
        }
        guard let initialCount = try count() else { return nil }
        var values: [AnyObject] = []
        if initialCount > 0 {
            try prepare(deadline)
            var array: CFArray?
            let status = AXUIElementCopyAttributeValues(element, name as CFString, 0, initialCount, &array)
            try checkMessagesAXDeadline(deadline)
            if status == .attributeUnsupported || status == .noValue { throw MessagesAXRouteDrift(.relationshipCountChanged) }
            guard status == .success else { throw MessagesAXNavigationError.axFailure }
            guard let array, CFArrayGetCount(array) == initialCount else { throw MessagesAXRouteDrift(.relationshipCountChanged) }
            values = array as [AnyObject]
        }
        guard let finalCount = try count(), finalCount == initialCount else {
            throw MessagesAXRouteDrift(.relationshipCountChanged)
        }
        return try values.map { value in
            try checkMessagesAXDeadline(deadline)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MessagesAXNavigationError.unknownAXValue }
            return LiveAXElement(element: value as! AXUIElement)
        }
    }

    private func relationship(_ name: String, limit: Int, requireAvailable: Bool = false, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        func count() throws -> Int {
            try prepare(deadline)
            var value: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(element, name as CFString, &value)
            try checkMessagesAXDeadline(deadline)
            return try Self.relationshipCount(status: status, count: value, limit: limit, requireAvailable: requireAvailable)
        }
        let initialCount = try count()
        var values: [AnyObject] = []
        if initialCount > 0 {
            try prepare(deadline)
            var array: CFArray?
            let status = AXUIElementCopyAttributeValues(element, name as CFString, 0, initialCount, &array)
            try checkMessagesAXDeadline(deadline)
            // A relation that vanished after a positive count changed under us.
            if status == .attributeUnsupported || status == .noValue { throw MessagesAXRouteDrift(.relationshipCountChanged) }
            guard status == .success else { throw MessagesAXNavigationError.axFailure }
            guard let array, CFArrayGetCount(array) == initialCount else { throw MessagesAXRouteDrift(.relationshipCountChanged) }
            values = array as [AnyObject]
        }
        // Recheck even empty/unsupported relations so a newly appearing edge
        // cannot turn an incomplete scan into uniqueness evidence.
        guard try count() == initialCount else { throw MessagesAXRouteDrift(.relationshipCountChanged) }
        return try values.map { value in
            try checkMessagesAXDeadline(deadline)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MessagesAXNavigationError.unknownAXValue }
            return LiveAXElement(element: value as! AXUIElement)
        }
    }

    func performAction(named name: String, deadline: WorkerDeadline) throws {
        try prepare(deadline)
        let status = AXUIElementPerformAction(element, name as CFString)
        try checkMessagesAXDeadline(deadline)
        guard status == .success else { throw MessagesAXNavigationError.axFailure }
    }

    func setValue(_ value: String, deadline: WorkerDeadline) throws {
        try prepare(deadline)
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        try checkMessagesAXDeadline(deadline)
        guard status == .success else { throw MessagesAXNavigationError.axFailure }
    }
}
