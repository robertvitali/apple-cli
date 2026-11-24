import Foundation

enum MessagesLocalizedResource {
    case accessibility, chatKit

    func string(forKey key: String) -> String? {
        let path: String
        let table: String
        switch self {
        case .accessibility:
            path = "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle"
            table = "Accessibility"
        case .chatKit:
            path = "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework"
            table = "ChatKit"
        }
        guard let bundle = Bundle(path: path) else { return nil }
        let preferences = CFPreferencesCopyAppValue(
            "AppleLanguages" as CFString, LiveMessagesReactionAXDriver.bundleIdentifier as CFString
        ) as? [String] ?? Locale.preferredLanguages
        return Self.string(forKey: key, in: bundle, table: table, preferredLanguages: preferences)
    }

    static func string(forKey key: String, in bundle: Bundle, table: String, preferredLanguages: [String]) -> String? {
        guard let language = Bundle.preferredLocalizations(from: bundle.localizations,
                                                           forPreferences: preferredLanguages).first else { return nil }
        let resource = LocalizedStringResource(String.LocalizationValue(stringLiteral: key), table: table,
                                               locale: Locale(identifier: language), bundle: .atURL(bundle.bundleURL))
        let title = String(localized: resource)
        guard !title.isEmpty, !title.utf8.elementsEqual(key.utf8) else { return nil }
        return title
    }
}
