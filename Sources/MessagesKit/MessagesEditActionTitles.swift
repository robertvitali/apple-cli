import AppleKit
import Foundation

struct MessagesEditActionTitles {
    let edit: String
    let confirm: String
    let cancel: String

    private init(edit: String, confirm: String, cancel: String) {
        self.edit = edit
        self.confirm = confirm
        self.cancel = cancel
    }

    static func resolve(deadline: WorkerDeadline, lookup: (String) -> String?) throws -> Self {
        let keys = ["edit.button", "editing.confirm.button", "editing.reject.button"]
        var titles: [String] = []
        for key in keys {
            try checkMessagesAXDeadline(deadline)
            guard let title = lookup(key), !title.utf8.elementsEqual(key.utf8),
                  MessagesReactionActionTitleResolver.valid(title),
                  !titles.contains(where: { $0.utf8.elementsEqual(title.utf8) }) else {
                throw MessagesAXNavigationError.unknownAXValue
            }
            titles.append(title)
        }
        try checkMessagesAXDeadline(deadline)
        return Self(edit: titles[0], confirm: titles[1], cancel: titles[2])
    }

    static func live(deadline: WorkerDeadline) throws -> Self {
        try resolve(deadline: deadline) { key in
            Bundle(path: "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle")?
                .localizedString(forKey: key, value: nil, table: "Accessibility")
        }
    }
}
