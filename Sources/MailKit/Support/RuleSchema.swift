import Foundation
import AppleKit

/// Mail rule condition/action schema (MCP A `create_rule`/`update_rule`). Parsing +
/// validation are pure so they're unit-testable without Mail.app. The AppleScript that
/// actually creates/updates rules is gated behind `--execute` and not run in tests.
public enum RuleSchema {

    public static let conditionFields = ["from", "to", "subject", "body", "any_recipient", "header_name"]
    public static let conditionOperators = ["contains", "does_not_contain", "begins_with", "ends_with", "equals"]
    /// Action verbs MCP A's update_rule REFUSES to touch (outside the supported schema).
    public static let unsupportedActionVerbs = ["run_applescript", "redirect", "reply", "play_sound", "highlight_color", "set_color"]

    public struct Condition: Encodable, Equatable {
        public let field: String
        public let `operator`: String
        public let value: String
        public let header_name: String?
    }

    public struct Action: Encodable, Equatable {
        public var move_to: String?           // "Account/Mailbox/Path"
        public var copy_to: String?
        public var mark_read: Bool?
        public var mark_flagged: Bool?
        public var flag_color: String?
        public var delete: Bool?
        public var forward_to: [String]?
    }

    /// Parse `field:operator:value` — the value is verbatim (colons preserved, so `Re: Q3`,
    /// `https://…`, `9:00` survive). For `header_name`, the grammar is
    /// `header_name:operator:value:HEADER` where the header name is the FINAL colon-segment.
    public static func parseCondition(_ raw: String) throws -> Condition {
        // Split ONLY field + operator off the front; keep the rest (value) intact.
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw AppleError.validation("condition must be 'field:operator:value' (e.g. 'from:contains:boss@x.io'); got '\(raw)'.")
        }
        let field = parts[0], op = parts[1]
        guard conditionFields.contains(field) else {
            throw AppleError.validation("condition field must be one of \(conditionFields.joined(separator: ", ")); got '\(field)'.")
        }
        guard conditionOperators.contains(op) else {
            throw AppleError.validation("condition operator must be one of \(conditionOperators.joined(separator: ", ")); got '\(op)'.")
        }
        var value = parts[2]
        var header: String? = nil
        if field == "header_name" {
            guard let lastColon = value.lastIndex(of: ":") else {
                throw AppleError.validation("field 'header_name' requires a header name: 'header_name:contains:value:X-Header'.")
            }
            header = String(value[value.index(after: lastColon)...])
            value = String(value[value.startIndex..<lastColon])
            if header!.isEmpty {
                throw AppleError.validation("field 'header_name' requires a non-empty header name after the final ':'.")
            }
        }
        return Condition(field: field, operator: op, value: value, header_name: header)
    }

    /// Fold `key=value` action tokens into a single Action. Recognized keys:
    /// move_to, copy_to, mark_read, mark_flagged, flag_color, delete, forward_to.
    public static func parseActions(_ raw: [String]) throws -> Action {
        var a = Action()
        for token in raw {
            guard let eq = token.firstIndex(of: "=") else {
                throw AppleError.validation("action must be 'key=value' (e.g. 'move_to=Gmail/Archive'); got '\(token)'.")
            }
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            if unsupportedActionVerbs.contains(key) {
                throw AppleError.validation("action '\(key)' is not supported (run-AppleScript/redirect/reply/sound/color) — edit such rules in Mail.app.")
            }
            switch key {
            case "move_to": a.move_to = value
            case "copy_to": a.copy_to = value
            case "mark_read": a.mark_read = (value.lowercased() == "true")
            case "mark_flagged": a.mark_flagged = (value.lowercased() == "true")
            case "flag_color":
                guard MailFlagColor.acceptedTokens.contains(value.lowercased()) else {
                    throw AppleError.validation("flag_color must be one of \(MailFlagColor.acceptedTokens.joined(separator: "/")); got '\(value)'.")
                }
                a.flag_color = value.lowercased()
            case "delete": a.delete = (value.lowercased() == "true")
            case "forward_to": a.forward_to = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default:
                throw AppleError.validation("unknown action key '\(key)'.")
            }
        }
        if a.move_to == nil && a.copy_to == nil && a.mark_read == nil && a.mark_flagged == nil
            && a.flag_color == nil && a.delete == nil && (a.forward_to?.isEmpty ?? true) {
            throw AppleError.validation("a rule needs at least one action.")
        }
        return a
    }

    public struct Rule: Encodable {
        public let name: String
        public let conditions: [Condition]
        public let actions: Action
        public let match_logic: String    // "all" | "any"
        public let enabled: Bool
    }
}
