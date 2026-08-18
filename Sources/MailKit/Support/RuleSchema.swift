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
        // Checked AFTER the header_name split, because that split is what produces the empty
        // value: `header_name:contains::X-Foo` arrives as parts[2] == ":X-Foo" (non-empty), and
        // only after the header is peeled off is the value "". Oracle A rejects an empty value
        // ("condition.value must be a non-empty string", mail_connector.py) — an empty `contains`
        // matches EVERY message, so accepting it builds a far broader rule than intended.
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AppleError.validation("condition value must not be empty (an empty match would apply to every message).")
        }
        return Condition(field: field, operator: op, value: value, header_name: header)
    }

    /// Fold `key=value` action tokens into a single Action. Recognized keys:
    /// move_to, copy_to, mark_read, mark_flagged, flag_color, delete, forward_to.
    /// Oracle A's validate_email regex, verbatim (utils.py:142):
    /// ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$
    static func isValidForwardAddress(_ s: String) -> Bool {
        s.range(of: #"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#,
                options: .regularExpression) != nil
    }

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
            case "forward_to":
                let entries = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // Oracle A validates EVERY entry (mail_connector.py:505-511, utils.validate_email)
                // and raises ValueError → validation_error; the bare comma-split let
                // `forward_to=notanemail` parse and preview ok (gap26). Same regex as the oracle.
                for e in entries where !RuleSchema.isValidForwardAddress(e) {
                    throw AppleError.validation("forward_to entries must be valid email addresses; got '\(e)'.")
                }
                a.forward_to = entries
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

/// The safety invariant a LIVE rule create/update must satisfy so an autonomous run can only ever
/// author a rule that acts on `apple-cli-test…` mail — never real mail — even once enabled. Both
/// `rules create` and `rules update` route their patch content through these, so the invariant has
/// ONE source of truth (drift here = a real-mail-mutation surface). Exit-code contract, relied on by
/// the bats gate tests: label/self-scope/destructive-action failures throw `mailSafety` (exit 77);
/// unwired/malformed-action failures throw `validation` (exit 64).
public enum RuleLiveGuards {
    private static let ctrlChars = CharacterSet(charactersIn: "\u{1e}\u{1f}")

    /// The rule name must carry the test label (so a real rule can never be authored/renamed live).
    public static func requireLabeledName(_ name: String) throws {
        guard name.hasPrefix(TestMode.sandboxPrefix) else {
            throw AppleError.mailSafety("rule name '\(name)' is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing.")
        }
    }

    /// RS/US (0x1E/0x1F) in the name or a condition value would desync the argv blob the AppleScript
    /// splits on — reject so a stray control char can't smuggle an extra condition/action field.
    public static func requireNoControlChars(name: String?, conditions: [RuleSchema.Condition]) throws {
        if let name, name.rangeOfCharacter(from: ctrlChars) != nil {
            throw AppleError.validation("rule name must not contain RS/US (0x1E/0x1F) control characters.")
        }
        if conditions.contains(where: { $0.value.rangeOfCharacter(from: ctrlChars) != nil }) {
            throw AppleError.validation("rule condition values must not contain RS/US (0x1E/0x1F) control characters.")
        }
        // header_name is now serialized as the 4th US-delimited field of each RS-delimited
        // condition record, so it must be guarded exactly like `value`: a header name carrying
        // US/RS would desynchronize the framing and shift every following field by one — turning
        // a header condition into a differently-typed condition on attacker-chosen text.
        // `parseCondition` takes the header from the FINAL colon-segment of user input, so this
        // is reachable from the command line.
        if conditions.contains(where: { ($0.header_name ?? "").rangeOfCharacter(from: ctrlChars) != nil }) {
            throw AppleError.validation("rule condition header names must not contain RS/US (0x1E/0x1F) control characters.")
        }
    }

    /// `conditions` is the FULL condition set the rule will carry. It must be an AND-rule
    /// (`match == "all"`) bound to the test label via a subject condition, so the label always
    /// constrains it.
    /// The self-scoping predicate on its own, so a PREVIEW can report "execute would refuse this"
    /// using the exact test the execute path throws on. Keeping two copies is how the update
    /// preview came to silently omit this refusal while reporting `live_blockers: []`.
    public static func isSelfScoped(_ conditions: [RuleSchema.Condition]) -> Bool {
        conditions.contains {
            $0.field == "subject"
                && ["contains", "begins_with", "equals"].contains($0.operator)
                && $0.value.contains(TestMode.sandboxPrefix)
        }
    }

    public static func requireSelfScoped(conditions: [RuleSchema.Condition], match: String) throws {
        guard match == "all" else {
            throw AppleError.mailSafety("a live test rule must use --match all so its test-label condition always constrains it — refusing (use the preview for --match any).")
        }
        guard isSelfScoped(conditions) else {
            throw AppleError.mailSafety("a live test rule must include a subject condition bound to the test label (e.g. \"subject:contains:\(TestMode.sandboxPrefix)\") so it only ever acts on test mail — refusing.")
        }
        // header_name IS now wired for live mutation (Mail.sdef RuleType `header key` + the rule
        // condition's `header` property), so it is no longer refused. The self-scoping invariant
        // above is what keeps such a rule safe: it is an AND-rule that still carries the
        // test-label subject condition, so adding a header condition can only NARROW it further.
    }

    /// The live-safe rule action plan resolved from an Action: move_to/copy_to (resolved-mailbox
    /// move/copy), mark_read, mark_flagged, and flag_color are WIRED for live execution; forward_to
    /// and delete stay refused (see `liveActionPlan`). `tokens` is the human/JSON-facing summary.
    public struct LiveActionPlan: Encodable {
        public var markRead: Bool
        public var markFlagged: Bool
        public var moveTo: String?          // "Account/Mailbox"
        public var copyTo: String?          // "Account/Mailbox"
        public var flagColorIndex: Int?     // 0..6 (MailFlagColor rawValue)
        public var tokens: [String]
    }

    /// Reduce an Action to the live-safe plan. move_to/copy_to (a resolved-mailbox move/copy),
    /// mark_read, mark_flagged, and flag_color are now WIRED for live execution; forward_to
    /// (auto-send to others) and delete (auto-trash) remain refused — a live rule carrying either is
    /// a latent exfil/destructive surface once enabled, so those stay Mail.app-only. At least one
    /// supported action is required. move_to/copy_to must be `Account/Mailbox` so the AppleScript can
    /// resolve a concrete target mailbox.
    /// The actions the LIVE path refuses, as caller-facing reasons. Empty means `liveActionPlan`
    /// will succeed for these actions.
    ///
    /// WHY THIS EXISTS: `liveActionPlan` throws, and the create/update commands call it before the
    /// dry-run branch so a preview faithfully predicts execute. The side effect was that a rule
    /// with `delete` or `forward_to` — both real oracle capabilities — could not even be
    /// PREVIEWED. A preview that refuses to describe a rule is strictly less useful than one that
    /// describes it and says plainly which parts would be refused live, so previews now use this.
    public static func liveActionBlockers(_ actions: RuleSchema.Action) -> [String] {
        var out: [String] = []
        if let fwd = actions.forward_to, !fwd.isEmpty {
            out.append("forward_to: a live rule that auto-sends to others is refused (edit it in Mail.app)")
        }
        if actions.delete == true {
            out.append("delete: a live rule that can auto-trash mail is refused (test it in Mail.app)")
        }
        return out
    }

    /// SHAPE validation for move_to/copy_to, split out of `liveActionPlan` so previews run it
    /// UNCONDITIONALLY (extra25): both preview paths used to gate the whole plan on
    /// `blockers.isEmpty`, so a malformed target paired with a delete/forward_to blocker
    /// skipped these checks entirely and previewed ok — where oracle A validates always.
    public static func validateActionShapes(_ actions: RuleSchema.Action) throws {
        if let mv = actions.move_to, !mv.isEmpty {
            guard mv.rangeOfCharacter(from: ctrlChars) == nil else { throw AppleError.validation("move_to must not contain RS/US (0x1E/0x1F) control characters.") }
            guard mv.contains("/") else { throw AppleError.validation("move_to must be 'Account/Mailbox' (e.g. 'iCloud/Archive'); got '\(mv)'.") }
        }
        if let cp = actions.copy_to, !cp.isEmpty {
            guard cp.rangeOfCharacter(from: ctrlChars) == nil else { throw AppleError.validation("copy_to must not contain RS/US (0x1E/0x1F) control characters.") }
            guard cp.contains("/") else { throw AppleError.validation("copy_to must be 'Account/Mailbox' (e.g. 'iCloud/Archive'); got '\(cp)'.") }
        }
    }

    public static func liveActionPlan(_ actions: RuleSchema.Action) throws -> LiveActionPlan {
        try validateActionShapes(actions)
        if let fwd = actions.forward_to, !fwd.isEmpty {
            throw AppleError.mailSafety("a live rule with forward_to can auto-send to others — refused; edit such a rule in Mail.app.")
        }
        if actions.delete == true {
            throw AppleError.mailSafety("a live rule with a delete action could auto-trash mail once enabled — refused; test delete-action rules in Mail.app.")
        }
        var plan = LiveActionPlan(markRead: actions.mark_read == true, markFlagged: actions.mark_flagged == true,
                                  moveTo: nil, copyTo: nil, flagColorIndex: nil, tokens: [])
        var toks: [String] = []
        if let mv = actions.move_to, !mv.isEmpty {
            guard mv.rangeOfCharacter(from: ctrlChars) == nil else { throw AppleError.validation("move_to must not contain RS/US (0x1E/0x1F) control characters.") }
            guard mv.contains("/") else { throw AppleError.validation("move_to must be 'Account/Mailbox' (e.g. 'iCloud/Archive'); got '\(mv)'.") }
            plan.moveTo = mv; toks.append("move_to=\(mv)")
        }
        if let cp = actions.copy_to, !cp.isEmpty {
            guard cp.rangeOfCharacter(from: ctrlChars) == nil else { throw AppleError.validation("copy_to must not contain RS/US (0x1E/0x1F) control characters.") }
            guard cp.contains("/") else { throw AppleError.validation("copy_to must be 'Account/Mailbox' (e.g. 'iCloud/Archive'); got '\(cp)'.") }
            plan.copyTo = cp; toks.append("copy_to=\(cp)")
        }
        if let fc = actions.flag_color, let idx = MailFlagColor.fromToken(fc)?.rawValue {
            plan.flagColorIndex = idx; plan.markFlagged = true; toks.append("flag_color=\(fc)")
        }
        if plan.markRead { toks.append("mark_read") }
        // Emit a bare mark_flagged only when NO color resolved — gate on the resolved index, not on
        // token presence: `flag_color=none` (accepted but resolves to no index) must NOT suppress an
        // accompanying mark_flagged, and `flag_color=<color>` already implies flagged via its token.
        if plan.markFlagged && plan.flagColorIndex == nil { toks.append("mark_flagged") }
        guard !toks.isEmpty else {
            throw AppleError.validation("live rule mutation needs at least one of move_to/copy_to/mark_read/mark_flagged/flag_color (delete/forward remain refused).")
        }
        plan.tokens = toks
        return plan
    }
}
