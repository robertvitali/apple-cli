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
            throw AppleError.validation("condition must be 'field:operator:value' (e.g. 'from:contains:boss@example.com'); got '\(raw)'.")
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
            // Sandbox-only gate (every caller is under `if sandboxActive`), so it carries error.sandbox (Q14).
            throw AppleError.mailSafety("rule name '\(name)' is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing.", sandbox: true)
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
            throw AppleError.mailSafety("a live test rule must use --match all so its test-label condition always constrains it — refusing (use the preview for --match any).", sandbox: true)
        }
        guard isSelfScoped(conditions) else {
            throw AppleError.mailSafety("a live test rule must include a subject condition bound to the test label (e.g. \"subject:contains:\(TestMode.sandboxPrefix)\") so it only ever acts on test mail — refusing.", sandbox: true)
        }
        // header_name IS now wired for live mutation (Mail.sdef RuleType `header key` + the rule
        // condition's `header` property), so it is no longer refused. The self-scoping invariant
        // above is what keeps such a rule safe: it is an AND-rule that still carries the
        // test-label subject condition, so adding a header condition can only NARROW it further.
    }

    /// The live-safe rule action plan resolved from an Action: move_to/copy_to (resolved-mailbox
    /// move/copy), mark_read, mark_flagged, flag_color, and delete are WIRED for live execution;
    /// forward_to stays refused (see `liveActionPlan`). `tokens` is the human/JSON-facing summary.
    public struct LiveActionPlan: Encodable {
        public var markRead: Bool
        public var markFlagged: Bool
        public var moveTo: String?          // "Account/Mailbox"
        public var copyTo: String?          // "Account/Mailbox"
        public var flagColorIndex: Int?     // 0..6 (MailFlagColor rawValue)
        /// Delete (auto-trash) action. Operator-ruled full parity with oracle A (2026-08-19): a
        /// live rule may now carry `delete` — matching mail moves to Trash automatically once the
        /// rule is enabled. `liveActionWarnings` surfaces the advisory that goes with wiring this;
        /// it is not a blocker.
        public var delete: Bool
        public var tokens: [String]
    }

    /// Reduce an Action to the live-safe plan. move_to/copy_to (a resolved-mailbox move/copy),
    /// mark_read, mark_flagged, flag_color, and delete (auto-trash) are now WIRED for live
    /// execution; forward_to (auto-send to others) remains refused — a live rule that can silently
    /// send mail to a third party is a latent exfil surface once enabled, so it stays
    /// Mail.app-only. At least one supported action is required. move_to/copy_to must be
    /// `Account/Mailbox` so the AppleScript can resolve a concrete target mailbox.
    /// The actions the LIVE path refuses, as caller-facing reasons. Empty means `liveActionPlan`
    /// will succeed for these actions.
    ///
    /// WHY THIS EXISTS: `liveActionPlan` throws, and the create/update commands call it before the
    /// dry-run branch so a preview faithfully predicts execute. The side effect was that a rule
    /// with an action the live path refuses — a real oracle capability — could not even be
    /// PREVIEWED. A preview that refuses to describe a rule is strictly less useful than one that
    /// describes it and says plainly which parts would be refused live, so previews now use this.
    public static func liveActionBlockers(_ actions: RuleSchema.Action) -> [String] {
        var out: [String] = []
        if let fwd = actions.forward_to, !fwd.isEmpty {
            out.append("forward_to: a live rule that auto-sends to others is refused (edit it in Mail.app)")
        }
        return out
    }

    /// The ONE wording for the delete advisory, so the dry-run preview, the execute envelope, and
    /// the `--text` renderer cannot drift apart into three near-identical sentences.
    public static let deleteActionWarning =
        "delete: this rule will auto-trash matching mail (move it to Trash) once enabled — unattended, no confirmation step (test it in Mail.app first if unsure)"

    /// Non-blocking ADVISORY warnings for live-wired actions that stay dangerous even though they
    /// are no longer refused. `delete` is wired for live execution (full oracle-A parity,
    /// operator-ruled 2026-08-19) but can silently move matching mail to Trash, unattended, once
    /// the rule is enabled — surfaced here so both the dry-run preview and the execute success
    /// envelope carry the same wording. `liveActionPlan` does NOT throw on any of these; they are
    /// disjoint from `liveActionBlockers`.
    public static func liveActionWarnings(_ actions: RuleSchema.Action) -> [String] {
        actions.delete == true ? [deleteActionWarning] : []
    }

    /// Same advisory set computed from a RESOLVED plan rather than the requested `--action` tokens.
    /// The condition-replacing recreate path emits a MERGED plan (an existing rule's delete action
    /// is not read back, so it is NOT carried unless `--action delete=true` is re-passed), so an
    /// envelope warning off the requested actions there would misreport what the rule now carries.
    /// Both overloads return the identical wording — one constant, two accessors.
    public static func liveActionWarnings(plan: LiveActionPlan) -> [String] {
        plan.delete ? [deleteActionWarning] : []
    }

    /// True when an Action wires one of the live actions that RELOCATE or DESTROY mail
    /// (`move_to` / `copy_to` / `delete`), as opposed to the merely-annotating ones (`mark_read` /
    /// `mark_flagged` / `flag_color`). This is the set a SANDBOXED in-place `rules update` refuses
    /// to arm and ENABLE in the same command, because the target rule's EXISTING conditions are
    /// not re-verified self-scoped on that path.
    ///
    /// ONE source of truth, deliberately: the execute-path guard AND the dry-run blocker that must
    /// predict it both call this. `delete` shipped into the guard but not into the preview's
    /// blocker list, so a preview reported `live_blockers: []` — an affirmative "execute would
    /// accept this" — for an update execute refuses with 77. Two hand-maintained copies of the
    /// condition is exactly how that divergence happened (review-caught 2026-08-19).
    ///
    /// Equivalent to `plan.moveTo != nil || plan.copyTo != nil || plan.delete` on the plan
    /// `liveActionPlan` resolves from the same Action — locked by
    /// `RuleDeleteAdvisoryTests.armsPredicateMatchesResolvedPlan`.
    public static func armsRelocatingOrDestructiveAction(_ actions: RuleSchema.Action) -> Bool {
        actions.move_to?.isEmpty == false || actions.copy_to?.isEmpty == false || actions.delete == true
    }

    /// The ONE wording for that refusal, shared by the live `mailSafety` throw (prefixed with
    /// "sandbox active: ") and the dry-run blocker entry, so the preview quotes the reason execute
    /// will actually give instead of a paraphrase that can rot independently.
    public static let inPlaceEnableRefusal =
        "wiring move_to/copy_to/delete on an in-place update cannot also ENABLE the rule in the same command (its existing conditions are not re-verified self-scoped) — omit --enabled and enable separately after review, or pass --condition to route through the self-scoping recreate path."

    /// The failure reason when a freshly-created (or freshly-recreated) rule's match-all/any
    /// READBACK does not agree with what was requested — nil when they agree. Split out (mirrors
    /// `isSelfScoped` / `armsRelocatingOrDestructiveAction` above) so the create-path verification
    /// (`RulesCreate.run()`, right next to its condition-COUNT verification) and its test read
    /// from ONE predicate rather than a hand-inlined `!=` at the call site. Review-caught
    /// 2026-08-19: the AppleScript-level match-all SET used to be silently swallowed
    /// (`try ... end try`), so nothing downstream ever confirmed it actually took — a sandboxed
    /// rule's entire self-scoping argument depends on staying match-all. This is the Swift-side
    /// half of closing that gap; the AppleScript half is now fail-loud too (see
    /// `MailScript.createRuleScript` / `updateRuleMetaScript`).
    public static func matchLogicMismatch(requested: Bool, readback: Bool) -> String? {
        guard requested != readback else { return nil }
        return "rule create match logic mismatch (requested matchAll=\(requested), Mail reports matchAll=\(readback)) — removed the malformed rule rather than leave one whose AND/OR logic doesn't match what was requested (a sandboxed rule's self-scoping depends on staying match-all so its test-label condition always constrains it)."
    }

    /// The ONE wording for the enable-time refusal fired when a rule's REAL, on-disk state already
    /// carries a live delete action — shared by `rules enable`/`rules disable` (`setEnabled`, via
    /// `realDeleteEnableWarnings` in RuleTemplateCommands.swift) and the metadata-only branch of
    /// `rules update --enabled`. Closes the two-command bypass (review-caught 2026-08-19):
    /// `rules update <n> --action delete=true` (wires delete, no --enabled) followed by a SEPARATE
    /// `rules enable <n>` never re-checked the target's real action state — only its name label
    /// (`requireLabeledRule`), and under write-model v2 that label alone is not trustworthy for a
    /// destructive action: an UNSANDBOXED create/update can author a labeled rule with arbitrary,
    /// non-self-scoped conditions. Neither `rules enable` nor the metadata-only update re-reads
    /// the rule's CONDITIONS, so the refusal fires unconditionally rather than trust the label —
    /// arm such a rule via `rules update <index> --condition ... --action delete=true --enabled`,
    /// which re-verifies self-scoping against the conditions it is given.
    public static let realDeleteEnableRefusal =
        "already carries a live delete action — refusing to enable it because its conditions were not re-verified self-scoped (only its name label was checked). Re-arm it via `rules update <index> --condition ... --action delete=true --enabled`, which re-verifies self-scoping from the conditions you pass."

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
        var plan = LiveActionPlan(markRead: actions.mark_read == true, markFlagged: actions.mark_flagged == true,
                                  moveTo: nil, copyTo: nil, flagColorIndex: nil, delete: actions.delete == true, tokens: [])
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
        if plan.delete { toks.append("delete") }
        guard !toks.isEmpty else {
            throw AppleError.validation("live rule mutation needs at least one of move_to/copy_to/mark_read/mark_flagged/flag_color/delete (forward remains refused).")
        }
        plan.tokens = toks
        return plan
    }
}
