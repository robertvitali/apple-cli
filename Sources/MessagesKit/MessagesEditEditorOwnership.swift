import AppleKit
import Foundation

enum MessagesEditObservationReadiness: Error {
    case notReady
}

/// Retains structural identity across the selected-route to editor transition.
/// Text is only a consistency check; it does not prove native message identity.
struct MessagesEditEditorOwnership {
    struct Anchor {
        let container: any MessagesAXElement
        let panel: any MessagesAXElement
    }
    struct Token {
        let anchor: Anchor
        let group: any MessagesAXElement
        let host: any MessagesAXElement
        let field: any MessagesAXElement
        let confirm: any MessagesAXElement
        let cancel: any MessagesAXElement
    }
    let navigator: MessagesAXNavigator
    let editTitle: String
    let confirmTitle: String
    let cancelTitle: String

    init(navigator: MessagesAXNavigator, editTitle: String, confirmTitle: String, cancelTitle: String) throws {
        guard MessagesReactionActionTitleResolver.valid(editTitle),
              MessagesReactionActionTitleResolver.valid(confirmTitle),
              MessagesReactionActionTitleResolver.valid(cancelTitle),
              !confirmTitle.utf8.elementsEqual(cancelTitle.utf8) else { throw MessagesAXNavigationError.unknownAXValue }
        self.editTitle = editTitle
        self.navigator = navigator
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }

    init(navigator: MessagesAXNavigator, titles: MessagesEditActionTitles) throws {
        try self.init(navigator: navigator, editTitle: titles.edit, confirmTitle: titles.confirm, cancelTitle: titles.cancel)
    }

    /// Refuses any visible editor or composer draft without cancelling or
    /// clearing it. An always-present cancel control alone is not edit evidence.
    func requireInactive(route: MessagesAXRoute, deadline: WorkerDeadline) throws {
        try requireInactive(process: route.process, window: route.window, deadline: deadline)
    }

    /// Pre-navigation checks do not require a selected message. The retained
    /// window must remain the canonical process's sole root window throughout.
    func requireInactive(process: MessagesAXProcess, window: any MessagesAXElement,
                         deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        try navigator.checkProcess(process, deadline: deadline)
        guard try navigator.uniqueRootWindow(process: process, deadline: deadline).sameIdentity(as: window) else {
            throw MessagesAXNavigationError.targetDrift
        }
        let unsafe = try navigator.collect(from: window, window: window,
            traversalPolicy: .childrenOnly, deadline: deadline) { node, role, identifier in
            if let title = try node.axDescription(deadline: deadline), title.utf8.elementsEqual(confirmTitle.utf8) {
                return true
            }
            guard role == "AXTextField" || role == "AXTextArea" else { return false }
            if role == "AXTextArea" && identifier == "CKBalloonTextView" { return false }
            if identifier == "messageBodyField" {
                return try !node.bodyTextSnapshot(deadline: deadline).provenEmpty
                    || composerHasAttachmentEvidence(node, window: window, deadline: deadline)
            }
            // A normal sidebar search field is not an editor. Require explicit
            // native classification and emptiness before permitting navigation.
            if role == "AXTextField", try node.subrole(deadline: deadline) == "AXSearchField" {
                return try !node.bodyTextSnapshot(deadline: deadline).provenEmpty
            }
            return true
        }
        guard unsafe.isEmpty else { throw MessagesAXNavigationError.targetDrift }
        try navigator.checkProcess(process, deadline: deadline)
        guard try navigator.uniqueRootWindow(process: process, deadline: deadline).sameIdentity(as: window) else {
            throw MessagesAXNavigationError.targetDrift
        }
        try checkMessagesAXDeadline(deadline)
    }

    private func composerHasAttachmentEvidence(_ composer: any MessagesAXElement,
                                               window: any MessagesAXElement,
                                               deadline: WorkerDeadline) throws -> Bool {
        let matches = try navigator.collect(from: composer, window: window,
            traversalPolicy: .childrenAndLinks, deadline: deadline) { _, role, identifier in
            if role == "AXImage" { return true }
            guard let identifier else { return false }
            let lower = identifier.lowercased()
            return lower.contains("attachment") || lower.contains("filetransfer")
        }
        return !matches.isEmpty
    }

    /// Capture before opening Edit, while the unique selected route is valid.
    func retainAnchor(route: MessagesAXRoute, deadline: WorkerDeadline) throws -> Anchor {
        var current = route.selected
        var seen: [any MessagesAXElement] = []
        for _ in 0...32 {
            try checkMessagesAXDeadline(deadline)
            guard !seen.contains(where: { $0.sameIdentity(as: current) }),
                  let parent = try current.parent(deadline: deadline) else {
                throw MessagesAXNavigationError.targetDrift
            }
            seen.append(current)
            if parent.sameIdentity(as: route.transcript) {
                guard try current.role(deadline: deadline) == "AXGroup",
                      let panel = try route.transcript.parent(deadline: deadline),
                      try panel.role(deadline: deadline) == "AXGroup" else {
                    throw MessagesAXNavigationError.targetDrift
                }
                try proveDescendant(route.selected, of: current, route: route, deadline: deadline)
                let anchor = Anchor(container: current, panel: panel)
                try validateAnchor(anchor, route: route, deadline: deadline)
                return anchor
            }
            try proveDescendant(current, of: parent, route: route, deadline: deadline)
            current = parent
        }
        throw MessagesAXNavigationError.traversalLimit
    }

    func validateAnchor(_ anchor: Anchor, route: MessagesAXRoute, deadline: WorkerDeadline) throws {
        try navigator.checkProcess(route.process, deadline: deadline)
        let current = try navigator.captureWindowTranscript(process: route.process, deadline: deadline)
        guard current.window.sameIdentity(as: route.window), current.transcript.sameIdentity(as: route.transcript),
              try navigator.driver.messagesProcessIsFrontmost(route.process, deadline: deadline),
              let parent = try anchor.container.parent(deadline: deadline), parent.sameIdentity(as: route.transcript),
              let panel = try route.transcript.parent(deadline: deadline), panel.sameIdentity(as: anchor.panel) else {
            throw MessagesAXNavigationError.targetDrift
        }
        try proveDescendant(anchor.container, of: route.transcript, route: route, deadline: deadline)
        try proveDescendant(route.transcript, of: anchor.panel, route: route, deadline: deadline)
        try proveDescendant(anchor.panel, of: route.window, route: route, deadline: deadline)
        // Selection may clear or its leaf disappear. Inspect every subtree,
        // exempting only the retained container and original selected identity.
        let containers = try route.transcript.children(limit: 256, deadline: deadline)
        guard containers.count <= 256 else { throw MessagesAXNavigationError.traversalLimit }
        for container in containers {
            if !container.sameIdentity(as: anchor.container),
               try container.role(deadline: deadline) == "AXGroup",
               try container.selected(deadline: deadline) == nil {
                throw MessagesAXNavigationError.unknownAXValue
            }
            let selected = try navigator.collect(from: container, window: route.window,
                traversalPolicy: .childrenOnly, deadline: deadline) { node, _, _ in
                guard !node.sameIdentity(as: anchor.container),
                      !node.sameIdentity(as: route.selected) else { return false }
                let selection = try node.selected(deadline: deadline)
                let editActions = try node.actions(deadline: deadline).filter {
                    MessagesReactionAXAutomation.matchesAction($0, title: editTitle)
                }
                guard editActions.count <= 1 else { throw MessagesAXNavigationError.unknownAXValue }
                if !editActions.isEmpty && selection == nil {
                    throw MessagesAXNavigationError.unknownAXValue
                }
                return selection == true
            }
            guard selected.isEmpty else { throw MessagesAXNavigationError.ambiguousSelectedMessage }
        }
        try checkMessagesAXDeadline(deadline)
    }

    func capture(route: MessagesAXRoute, anchor: Anchor, expectedText: String, deadline: WorkerDeadline,
                 allowPendingAppearance: Bool = false) throws -> Token {
        try checkMessagesAXDeadline(deadline)
        try validateAnchor(anchor, route: route, deadline: deadline)
        let confirmations = try navigator.collect(from: route.window, window: route.window,
            traversalPolicy: .childrenOnly, deadline: deadline) { node, role, _ in
            guard role == "AXButton", let title = try node.axDescription(deadline: deadline) else { return false }
            return title.utf8.elementsEqual(confirmTitle.utf8)
        }
        if confirmations.isEmpty && allowPendingAppearance {
            try requireInactive(route: route, deadline: deadline)
            throw MessagesEditObservationReadiness.notReady
        }
        guard confirmations.count == 1, let confirm = confirmations.first,
              let group = try confirm.parent(deadline: deadline) else { throw MessagesAXNavigationError.targetDrift }
        guard group.sameIdentity(as: anchor.panel) else { throw MessagesAXNavigationError.targetDrift }
        let fields = try navigator.collect(from: group, window: route.window,
            traversalPolicy: .childrenOnly, deadline: deadline) { _, role, identifier in
            role == "AXTextField" && identifier != "messageBodyField" && identifier != "CKBalloonTextView"
        }
        let cancellations = try navigator.collect(from: group, window: route.window,
            traversalPolicy: .childrenOnly, deadline: deadline) { node, role, _ in
            guard role == "AXButton", let title = try node.axDescription(deadline: deadline) else { return false }
            return title.utf8.elementsEqual(cancelTitle.utf8)
        }
        guard fields.count == 1, cancellations.count == 1, let field = fields.first, let cancel = cancellations.first,
              try field.enabled(deadline: deadline) == true, try field.valueSettable(deadline: deadline) == true,
              try confirm.enabled(deadline: deadline) != nil, try cancel.enabled(deadline: deadline) == true,
              try confirm.actions(deadline: deadline).filter({ $0 == "AXPress" }).count == 1 else {
            throw MessagesAXNavigationError.targetDrift
        }
        guard let host = try field.parent(deadline: deadline),
              try host.role(deadline: deadline) == "AXGroup",
              !host.sameIdentity(as: route.transcript),
              let hostParent = try host.parent(deadline: deadline), hostParent.sameIdentity(as: anchor.panel),
              let cancelParent = try cancel.parent(deadline: deadline), cancelParent.sameIdentity(as: anchor.panel) else {
            throw MessagesAXNavigationError.targetDrift
        }
        for node in [field, confirm, cancel] {
            try proveDescendant(node, of: group, route: route, deadline: deadline)
        }
        let drafts = try navigator.collect(from: route.window, window: route.window,
            traversalPolicy: .childrenOnly, deadline: deadline) { node, role, identifier in
            guard identifier == "messageBodyField", role == "AXTextField" || role == "AXTextArea" else { return false }
            return try !node.bodyTextSnapshot(deadline: deadline).provenEmpty
                || composerHasAttachmentEvidence(node, window: route.window, deadline: deadline)
        }
        guard drafts.isEmpty else { throw MessagesAXNavigationError.targetDrift }
        let observed = try field.bodyTextSnapshot(deadline: deadline)
        guard observed.text.utf8.elementsEqual(expectedText.utf8) else { throw MessagesAXNavigationError.targetDrift }
        try checkMessagesAXDeadline(deadline)
        return Token(anchor: anchor, group: group, host: host, field: field, confirm: confirm, cancel: cancel)
    }

    func revalidate(_ token: Token, route: MessagesAXRoute, expectedText: String, deadline: WorkerDeadline) throws {
        let current = try capture(route: route, anchor: token.anchor, expectedText: expectedText, deadline: deadline)
        guard current.group.sameIdentity(as: token.group), current.host.sameIdentity(as: token.host), current.field.sameIdentity(as: token.field),
              current.confirm.sameIdentity(as: token.confirm), current.cancel.sameIdentity(as: token.cancel) else {
            throw MessagesAXNavigationError.targetDrift
        }
    }

    private func proveDescendant(_ node: any MessagesAXElement, of ancestor: any MessagesAXElement,
                                 route: MessagesAXRoute, deadline: WorkerDeadline) throws {
        var current = node
        var seen: [any MessagesAXElement] = []
        for _ in 0...32 {
            try checkMessagesAXDeadline(deadline)
            guard !seen.contains(where: { $0.sameIdentity(as: current) }),
                  try current.processIdentifier(deadline: deadline) == route.process.identity.pid else {
                throw MessagesAXNavigationError.targetDrift
            }
            // AXWindow describes an ancestor; a window need not expose it on itself.
            if current.sameIdentity(as: route.window) {
                guard current.sameIdentity(as: ancestor) else { throw MessagesAXNavigationError.targetDrift }
                return
            }
            guard let window = try current.window(deadline: deadline), window.sameIdentity(as: route.window) else {
                throw MessagesAXNavigationError.targetDrift
            }
            if current.sameIdentity(as: ancestor) { return }
            seen.append(current)
            guard let parent = try current.parent(deadline: deadline) else { throw MessagesAXNavigationError.targetDrift }
            let children = try parent.children(limit: 256, deadline: deadline)
            guard children.count <= 256, children.filter({ $0.sameIdentity(as: current) }).count == 1 else {
                throw MessagesAXNavigationError.targetDrift
            }
            current = parent
        }
        throw MessagesAXNavigationError.traversalLimit
    }
}
