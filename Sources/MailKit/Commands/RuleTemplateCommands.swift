import Foundation
import ArgumentParser
import AppleKit

// P1b: rules (list = live read; mutations = dry-run default, guarded) + templates (file-based).

// MARK: rules

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "List and manage Mail rules.",
        subcommands: [RulesList.self, RulesCreate.self, RulesUpdate.self, RulesDelete.self, RulesEnable.self, RulesDisable.self],
        defaultSubcommand: RulesList.self)
}

struct RulesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Mail rules (1-based index, name, enabled).")
    @OptionGroup var global: GlobalOptions
    struct RuleInfo: Encodable { let index: Int; let name: String; let enabled: Bool }
    struct Result: Encodable { let rules: [RuleInfo]; let count: Int }
    func run() throws {
        try runGuarded(tool: "mail") {
            let rules: [MailScript.ScriptRule]
            do { rules = try MailScript().listRules() }
            catch { throw AppleError.upstream("could not read Mail rules — is Mail.app available with automation permitted? (\(error))") }
            let infos = rules.map { RuleInfo(index: $0.index, name: $0.name, enabled: $0.enabled) }
            let result = Result(rules: infos, count: infos.count)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { for r in infos { Output.printText("\(r.index). \(r.name) [\(r.enabled ? "enabled" : "disabled")]") } }
        }
    }
}

struct RulesCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a rule (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var name: String
    @Option(name: .long, help: "Condition 'field:operator:value[:header]' (repeatable).") var condition: [String] = []
    @Option(name: .long, help: "Action 'key=value' (repeatable): move_to/copy_to/mark_read/mark_flagged/flag_color/delete/forward_to.") var action: [String] = []
    @Option(name: .long, help: "Match logic: all (AND) or any (OR).") var match: String = "all"
    @Flag(name: .long, help: "Create the rule disabled.") var disabled = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            guard !condition.isEmpty else { throw AppleError.validation("at least one --condition is required.") }
            guard match == "all" || match == "any" else { throw AppleError.validation("--match must be 'all' or 'any'.") }
            let conditions = try condition.map { try RuleSchema.parseCondition($0) }
            let actions = try RuleSchema.parseActions(action)
            // `enabled` mirrors what EXECUTE will actually produce: a sandboxed create is
            // force-DISABLED, and the preview must predict that, not echo --disabled back
            // (review-caught: the sandboxed preview said enabled:true for a rule execute
            // creates disabled).
            let rule = RuleSchema.Rule(name: name, conditions: conditions, actions: actions, match_logic: match,
                                       enabled: sandboxActive ? false : !disabled)
            guard willExecute else {
                // A dry-run must still faithfully PREDICT the execute outcome — a malformed
                // `move_to=Archive` (missing the Account/Mailbox slash) previewing ok and then
                // failing under --execute was the original create-vs-update divergence. But
                // predicting is not the same as refusing: `forward_to` and (sandboxed) `--match
                // any` are real oracle capabilities the live path declines for safety, and a
                // preview that cannot even describe them loses the capability entirely. So: report
                // every blocker, and only fail the preview on genuinely MALFORMED input. `delete`
                // is live-wired (no longer a blocker) but still carries an advisory `warnings`
                // entry — see `liveActionWarnings`.
                // MALFORMED input still fails the preview. Control characters in a name/value/
                // header would desynchronize the US/RS framing the condition blob uses, so they
                // are rejected here too — not only on the live path, which a preview would
                // otherwise misreport as fine.
                try RuleLiveGuards.requireNoControlChars(name: name, conditions: conditions)
                // Blockers are computed under the SAME sandboxActive the execute path uses, or
                // the preview lies (docs/write-model-v2.md). The forward_to blocker is an UNWIRED
                // capability and applies in both modes; the label/self-scope/match-any
                // restrictions are the sandbox's. `warnings` are advisory-only (never thrown on).
                var blockers = RuleLiveGuards.liveActionBlockers(actions)
                let warnings = RuleLiveGuards.liveActionWarnings(actions)
                if sandboxActive {
                    if match == "any" {
                        blockers.append("--match any: a sandboxed rule must stay --match all so its test-label condition always constrains it")
                    }
                    // EVERY live refusal COMPUTABLE WITHOUT MAIL must be reported, not just the
                    // three relaxations. A preview that omits one and prints `live_blockers: []`
                    // makes the affirmative claim that execute would accept the rule — the exact
                    // preview/execute divergence this whole block exists to prevent. DOCUMENTED
                    // EXCEPTION: the duplicate-NAME refusal on the execute path requires reading
                    // Mail's rule list, which this preview deliberately never does (dry-runs stay
                    // Mail-free and CI-runnable) — a colliding name previews clean here and is
                    // refused with a clear validation_error at --execute (fail-closed; CHANGELOG'd).
                    if !name.hasPrefix(TestMode.sandboxPrefix) {
                        blockers.append("--name must start with \"\(TestMode.sandboxPrefix)\" for a sandboxed create")
                    }
                    if !RuleLiveGuards.isSelfScoped(conditions) {
                        blockers.append("conditions: a sandboxed rule must include a subject condition bound to \"\(TestMode.sandboxPrefix)\" so it only ever acts on test mail")
                    }
                }
                // extra25: SHAPE validation runs unconditionally — a malformed move_to/copy_to
                // must fail the preview even when a safety blocker is also present.
                try RuleLiveGuards.validateActionShapes(actions)
                if blockers.isEmpty { _ = try RuleLiveGuards.liveActionPlan(actions) }
                try emitRulePreview(rule, willExecute: false, json: global.json, liveBlockers: blockers,
                                    warnings: warnings, sandboxActive: sandboxActive)
                return
            }
            // ---- Live create (write-model v2). Sandboxed: SELF-SCOPED + force-disabled — a
            // sandboxed rule must be UNABLE to affect real mail even if later enabled: (a) bound
            // to the test label, (b) force-disabled. `delete` (auto-trash) is live-wired
            // (operator-ruled full parity, 2026-08-19) and safe even in the sandbox because the
            // self-scoping invariant confines it to `apple-cli-test`-labeled mail only. Unsandboxed:
            // the rule is created AS SPECIFIED (the oracle's create_rule creates on call) —
            // forward_to remains refused in liveActionPlan (a live rule that can auto-send to a
            // third party is a latent exfil surface, a deliberate gate, not an unwired gap).
            try RuleLiveGuards.requireNoControlChars(name: name, conditions: conditions)
            if sandboxActive {
                try RuleLiveGuards.requireLabeledName(name)
                try RuleLiveGuards.requireSelfScoped(conditions: conditions, match: match)   // enforces --match all
            }
            let plan = try RuleLiveGuards.liveActionPlan(actions)
            let conds = conditions.map { (type: $0.field, op: $0.operator, value: $0.value, header: $0.header_name ?? "") }
            let createEnabled = sandboxActive ? false : !disabled
            let createMatchAll = sandboxActive ? true : (match == "all")
            let script = MailScript()
            // Refuse a DUPLICATE NAME up front, in both modes. Mail's `make new rule` with an
            // already-taken name silently mangles the NEW rule's conditions (documented at the
            // recreate path below) — and worse, the post-create verification resolves by name, so
            // with a duplicate it would bind the PRE-EXISTING rule and the mismatch cleanup could
            // delete the operator's REAL rule (review-caught). RulesUpdate's recreate already
            // refuses collisions; create gets the same guard.
            if try script.listRules().contains(where: { $0.name == name }) {
                throw AppleError.validation("a rule named '\(name)' already exists — Mail silently mangles a duplicate-name create; pick a different --name or use `rules update`.")
            }
            // Create DISABLED regardless of mode, VERIFY the conditions attached, and only THEN
            // enable (mirrors the recreate path's documented ordering). Mail's `make new rule
            // condition` sits in a bare `try` that swallows every error and the script still
            // returns "ok" — creating ENABLED first would let a silently-condition-less rule
            // (which matches ALL mail) act on real messages in the window before verification,
            // and a failed readback would leave it enabled permanently (review-caught). With
            // create-disabled-first, every failure mode leaves the rule INERT.
            try script.createRule(name: name, enabled: false, matchAll: createMatchAll, conditions: conds, plan: plan)
            // `last(where:)` — Mail appends new rules, so the LAST name-match is the one just
            // created (belt-and-braces on top of the duplicate-name refusal above). A readback
            // failure is a HARD error here: the rule stays disabled (fail-safe), the operator is
            // told what state it is in.
            guard let created = try? script.listRules().last(where: { $0.name == name }) else {
                throw AppleError.upstream("rule '\(name)' was created (disabled) but could not be read back to verify its conditions — it was NOT enabled. Inspect it in Mail.app, then `rules enable` it or delete it.")
            }
            let attached = (try? script.ruleConditionCount(index: created.index)) ?? -1
            if attached != conds.count {
                try? script.deleteRule(index: created.index)
                throw AppleError.upstream("rule create attached \(attached)/\(conds.count) conditions — removed the malformed rule rather than leave one whose conditions may be missing (a 0-condition rule matches ALL mail).")
            }
            // MATCH-LOGIC VERIFICATION (review-caught 2026-08-19): the sandboxed self-scoping
            // invariant argues safety purely from "match=all + a test-label subject condition",
            // so the CLI must not just ASK Mail for match=all and trust it took — it must CONFIRM
            // the rule actually carries it, exactly like `attached` confirms the condition count
            // above. A readback failure is treated the same as a mismatch: fail closed (remove
            // the rule) rather than leave one whose AND/OR logic is unverified.
            let matchLogicReadback: Bool
            do {
                matchLogicReadback = try script.readRuleScalars(index: created.index).matchAll
            } catch {
                try? script.deleteRule(index: created.index)
                throw AppleError.upstream("rule create could not verify its match-all/any logic after creation (\(error)) — removed the malformed rule rather than leave one whose AND/OR logic is unverified.")
            }
            if let mismatch = RuleLiveGuards.matchLogicMismatch(requested: createMatchAll, readback: matchLogicReadback) {
                try? script.deleteRule(index: created.index)
                throw AppleError.upstream(mismatch)
            }
            if createEnabled {
                try script.updateRuleMeta(index: created.index, name: nil, enabled: true, matchAll: nil, plan: nil)
            }
            // Oracle A `create_rule` returns `rule_index` (the new total rule count) and `name`.
            // Mail exposes no "index of this rule" property, so re-read the list and take the
            // count — same definition the oracle uses. Best-effort: a read failure must not fail
            // an already-successful create, so the key is simply omitted then.
            let newIndex = (try? script.listRules().count).map(AnyEncodableBox.init)
            // Advisory note, independent of the sandbox note below: a live delete action needs to
            // stay visible even in the success envelope, not just the dry-run preview — the rule
            // now exists and (once enabled) will auto-trash matching mail unattended.
            let noteParts = [
                sandboxActive
                    ? "sandbox: created SELF-SCOPED to the test label + DISABLED — it can only ever act on apple-cli-test mail; `rules enable <index>` to activate"
                    : nil,
                plan.delete
                    ? "WARNING: this rule's delete action will auto-trash matching mail (move it to Trash) once enabled — unattended, no confirmation step"
                    : nil,
            ].compactMap { $0 }
            // `warnings` is MACHINE-READABLE on the preview envelope, so it must be machine-readable
            // here too: JSON is the contract (AGENTS.md), and an agent that parsed `warnings[]` on
            // --dry-run should not have to substring-match the prose `note` to learn the same fact
            // after --execute. Computed off the RESOLVED plan (what the rule actually carries), and
            // ADDITIVE — the `note` above is unchanged, so no consumer loses anything (MINOR).
            let warnings = RuleLiveGuards.liveActionWarnings(plan: plan)
            try Output.emit(tool: "mail", data: [
                "created_rule": AnyEncodableBox(name), "conditions": AnyEncodableBox(conditions),
                // `name` + `rule_index` are oracle A's wire names; `created_rule` is the CLI's
                // original key, kept so existing consumers don't break (additive → MINOR).
                "name": AnyEncodableBox(name), "rule_index": AnyEncodableBox(newIndex),
                "actions": AnyEncodableBox(plan.tokens), "match_logic": AnyEncodableBox(createMatchAll ? "all" : "any"),
                "enabled": AnyEncodableBox(createEnabled), "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                "warnings": AnyEncodableBox(warnings),
                "note": AnyEncodableBox(noteParts.isEmpty ? nil : noteParts.joined(separator: " "))], text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct RulesUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a rule by index (patch; EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "1-based rule index (from `rules list`).") var index: Int
    @Option(name: .long) var name: String?
    @Option(name: .long, help: "Replacement condition (repeatable; replaces all).") var condition: [String] = []
    @Option(name: .long, help: "Replacement action (repeatable; replaces all).") var action: [String] = []
    @Option(name: .long, help: "Match logic: all or any.") var match: String?
    @Flag(name: .long, inversion: .prefixedNo, help: "Enable/disable the rule.") var enabled: Bool?

    struct Patch: Encodable { let index: Int; let name: String?; let conditions: [RuleSchema.Condition]?; let actions: RuleSchema.Action?; let match_logic: String?; let enabled: Bool? }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            if let match, match != "all", match != "any" { throw AppleError.validation("--match must be 'all' or 'any'.") }
            let conds = condition.isEmpty ? nil : try condition.map { try RuleSchema.parseCondition($0) }
            // parseActions enforces the unsupported-action refusal (run-AppleScript/redirect/reply/sound/color).
            let acts = action.isEmpty ? nil : try RuleSchema.parseActions(action)
            let patch = Patch(index: index, name: name, conditions: conds, actions: acts, match_logic: match, enabled: enabled)

            // ---- Validation that needs no Mail — enforced for BOTH dry-run and execute so a preview
            // faithfully predicts the execute outcome (a rename / --match any / action that --execute
            // would refuse is refused in the preview too, not shown as if it would apply). ----
            guard name != nil || enabled != nil || match != nil || conds != nil || acts != nil else {
                throw AppleError.validation("nothing to update — pass at least one of --name/--enabled/--match/--condition/--action.")
            }
            // Blockers the LIVE path enforces. In a dry-run these are REPORTED, not thrown: an
            // OR-rule and a forward_to action are real oracle capabilities, and a preview that
            // refuses to describe them loses the capability from the surface entirely. Under
            // --execute they are still hard refusals (below).
            // Blockers computed under the SAME sandboxActive the execute path uses, or the
            // preview lies. forward_to is an unwired capability (both modes); the
            // label/self-scope/match-any restrictions are the sandbox's. `warnings` are
            // advisory-only (delete is live-wired but dangerous) and never thrown on.
            var blockers: [String] = []
            var warnings: [String] = []
            if let acts {
                blockers.append(contentsOf: RuleLiveGuards.liveActionBlockers(acts))
                warnings.append(contentsOf: RuleLiveGuards.liveActionWarnings(acts))
            }
            if sandboxActive {
                if match == "any" {
                    blockers.append("--match any: a sandboxed rule must stay --match all so its test-label condition always constrains it")
                }
                // requireSelfScoped used to run BEFORE the dry-run guard, so a condition set with no
                // test-label conjunct exited 77 in preview. Moving the guard above it dropped that
                // refusal from the preview entirely — reported as `live_blockers: []`, i.e. "execute
                // would accept this", for a rule execute refuses. Report it instead.
                if let conds, !RuleLiveGuards.isSelfScoped(conds) {
                    blockers.append("conditions: a sandboxed rule must include a subject condition bound to \"\(TestMode.sandboxPrefix)\" so it only ever acts on test mail")
                }
                if let name, !name.hasPrefix(TestMode.sandboxPrefix) {
                    blockers.append("--name must keep the \"\(TestMode.sandboxPrefix)\" label for a sandboxed rename")
                }
                // Mirror of the execute path's in-place ENABLE-GATE (in the `guard let conds else`
                // branch below): a sandboxed metadata-only update may not wire a relocating/
                // destructive action AND enable the rule in one command. Gated on `conds == nil`
                // because that guard sits on the metadata-only path — WITH --condition the update
                // routes through the self-scoping recreate, which re-verifies the conditions and so
                // is not refused. Without this mirror the preview printed `live_blockers: []` for
                // an update execute refuses with 77 — the affirmative "execute would accept this"
                // claim this whole block exists to prevent. The gate predates `delete`; the mirror
                // was missing for move_to/copy_to too, and covers all three via the shared
                // predicate so the two can never diverge again (review-caught 2026-08-19).
                if conds == nil, enabled == true, let acts,
                   RuleLiveGuards.armsRelocatingOrDestructiveAction(acts) {
                    blockers.append(RuleLiveGuards.inPlaceEnableRefusal)
                }
            }

            guard willExecute else {
                // Still fail the preview on MALFORMED input, so a dry-run keeps predicting the
                // execute outcome for everything that is not a deliberate safety refusal.
                try RuleLiveGuards.requireNoControlChars(name: name, conditions: conds ?? [])
                if let acts { try RuleLiveGuards.validateActionShapes(acts) }   // extra25: unconditional
                if blockers.isEmpty, let acts { _ = try RuleLiveGuards.liveActionPlan(acts) }
                let recreates = conds != nil
                var noteParts: [String] = []
                if !blockers.isEmpty {
                    noteParts.append("preview only — `--execute` would refuse this update: " + blockers.joined(separator: "; "))
                }
                if !warnings.isEmpty {
                    noteParts.append("advisory (would NOT be refused, but): " + warnings.joined(separator: "; "))
                }
                let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")
                if global.json {
                    try Output.emit(tool: "mail", data: ["dry_run": AnyEncodableBox(true), "patch": AnyEncodableBox(patch),
                        "would_recreate": AnyEncodableBox(recreates), "live_blockers": AnyEncodableBox(blockers),
                        "warnings": AnyEncodableBox(warnings),
                        "note": AnyEncodableBox(note)], sandboxActive: sandboxActive)
                } else {
                    Output.printText("Would update rule \(index) (dry-run; \(recreates ? "condition change → delete-and-recreate" : "in-place"))")
                    for b in blockers { Output.printText("  would be refused live: \(b)") }
                    for w in warnings { Output.printText("  warning: \(w)") }
                }
                return
            }
            if sandboxActive {
                if match == "any" {   // a sandboxed rule must stay match=all so its label always constrains it
                    throw AppleError.mailSafety("sandbox active: a sandboxed rule must stay --match all so its label condition always constrains it — refusing to set --match any.", sandbox: true)
                }
                if let name { try RuleLiveGuards.requireLabeledName(name) }    // a rename must keep the label
                if let conds { try RuleLiveGuards.requireSelfScoped(conditions: conds, match: "all") }
            }
            try RuleLiveGuards.requireNoControlChars(name: name, conditions: conds ?? [])
            let plan = try acts.map { try RuleLiveGuards.liveActionPlan($0) }
            // ---- Live. Inside the sandbox the target must be a labeled test rule. ----
            let target = try requireLabeledRule(index: index, sandboxActive: sandboxActive)
            // Mirror the oracle's `_check_supported_actions`: refuse to touch a rule whose EXISTING
            // actions include something the CLI can't model (run-script/redirect/reply-text/etc.).
            // In place we'd silently preserve+misrepresent them; on recreate we'd silently drop them.
            // Gates BOTH update paths (matching the oracle's unconditional check in update_rule).
            try MailScript().checkSupportedActions(index: target.index)

            guard let conds else {
                // ---- Metadata-only patch → modify IN PLACE (reliable; preserves rule position). ----
                // LABEL-TRUST BOUNDARY: enabling here trusts the rule's NAME label only — its EXISTING
                // conditions are NOT re-verified self-scoped (same boundary as `rules enable`).
                // CORRECTED (review-caught 2026-08-19; the prior wording here was a false rationale
                // load-bearing in a safety guard): under write-model v2 an UNSANDBOXED `rules
                // create`/`rules update` absolutely CAN author a labeled `apple-cli-test…` rule
                // with arbitrary, non-self-scoped conditions and arbitrary actions — creation only
                // enforces self-scoping while `--test-mode`/`APPLE_TEST_MODE` is engaged. So the
                // label alone is NOT proof the rule's conditions are self-scoped; it is proof only
                // that a prior command (this tool's or a hand-made one in Mail.app) chose that
                // name. `realDeleteEnableWarnings` below closes the gap this created for `delete`
                // specifically. To keep the remaining (move_to/copy_to) label-trust boundary from
                // being widened further, refuse to ENABLE a rule in
                // the SAME call that wires a move_to/copy_to: activation must be a separate, operator-
                // visible `rules enable` (or pass --condition to route through the self-scoping
                // recreate path). A CLI-authored rule is always created disabled + self-scoped, so this
                // never blocks the normal flow.
                // `delete` joined move_to/copy_to as a live-wired action on 2026-08-19 (gap25) and
                // belongs in this condition for the same reason, only more so: arming an unverified
                // rule with auto-trash is strictly worse than arming it with a move. It was omitted
                // when delete was wired — review-caught before the change shipped.
                // The gated set and the refusal wording now live in RuleLiveGuards, called from BOTH
                // here and the dry-run blocker above, so preview and execute cannot disagree about
                // which actions this gate covers. Reading `acts` rather than `plan` is equivalent
                // (plan is derived from acts, and is non-nil exactly when acts is) and keeps one
                // predicate over one input type.
                if sandboxActive, enabled == true, let acts,
                   RuleLiveGuards.armsRelocatingOrDestructiveAction(acts) {
                    throw AppleError.mailSafety("sandbox active: " + RuleLiveGuards.inPlaceEnableRefusal, sandbox: true)
                }
                // GATE OFF THE RULE'S REAL STATE, not just THIS command's --action (review-caught
                // 2026-08-19): the check above only sees an action THIS call wires. `rules update
                // <n> --action delete=true` (no --enabled) followed by a SEPARATE `rules update
                // <n> --enabled` (no --action) never touched the check above and could arm a
                // PRE-EXISTING delete action unverified — the same two-command bypass `rules
                // enable` closes via `realDeleteEnableWarnings` (see
                // `RuleLiveGuards.realDeleteEnableRefusal`); this is the metadata-only-update half
                // of that same fix. Runs BEFORE any mutation applies, so a sandboxed refusal here
                // leaves the rule untouched. Only read back when ARMING (`enabled == true`).
                let realDeleteMessage = (enabled == true) ? try MailScript().readRuleScalars(index: target.index).deleteMessage : false
                let realDeleteWarnings = try realDeleteEnableWarnings(target: target, realDeleteMessage: realDeleteMessage,
                                                                       enabling: enabled == true, sandboxActive: sandboxActive)
                // `map` so `--match any` actually applies (false = set OR). The old
                // `match == "all" ? true : nil` collapsed "any" to nil = "don't change" — a
                // silent no-op reported as executed:true once the sandbox-only refusal stopped
                // covering the unsandboxed path (review-caught).
                try MailScript().updateRuleMeta(index: target.index, name: name, enabled: enabled,
                                                matchAll: match.map { $0 == "all" }, plan: plan)
                // When --action is given, the supported action set is RESET then reapplied
                // (wholesale replace, matching the oracle) — the `patch.actions` ARE the rule's
                // full modeled action set afterward; rules carrying unmodeled actions were refused
                // above, so nothing unmanaged survives. A live delete action needs to stay visible
                // in the success envelope too, not just the dry-run preview.
                let inPlaceNoteParts = [
                    plan != nil ? "patched in place; supported actions reset to the given set (wholesale replace)" : "patched in place",
                    (plan?.delete == true)
                        ? "WARNING: this rule's delete action will auto-trash matching mail (move it to Trash) once enabled — unattended, no confirmation step"
                        : nil,
                ].compactMap { $0 }
                // Machine-readable twin of the prose advisory above (same reason as `rules create`:
                // `warnings[]` is parseable on the preview envelope, so it must be parseable here).
                // Merges in `realDeleteWarnings` (the rule's REAL pre-existing delete state, read
                // back above) alongside whatever THIS command's --action resolved: the two are
                // disjoint in the sandboxed-and-newly-wired case (the arms-gate above already
                // refuses that combination before either warning list is computed), but a plain
                // `rules update --enabled` with no --action still needs the real-state warning
                // surfaced on the unsandboxed path.
                var inPlaceWarnings = plan.map { RuleLiveGuards.liveActionWarnings(plan: $0) } ?? []
                for w in realDeleteWarnings where !inPlaceWarnings.contains(w) { inPlaceWarnings.append(w) }
                try Output.emit(tool: "mail", data: [
                    "updated_rule_index": AnyEncodableBox(target.index),
                    // `rule_index` is oracle A update_rule's wire name; `updated_rule_index` is
                    // the CLI's original key, kept for existing consumers (additive → MINOR).
                    "rule_index": AnyEncodableBox(target.index),
                    "rule_name": AnyEncodableBox(name ?? target.name),
                    "name": AnyEncodableBox(name ?? target.name),
                    "patch": AnyEncodableBox(patch), "recreated": AnyEncodableBox(false),
                    "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                    "warnings": AnyEncodableBox(inPlaceWarnings),
                    "note": AnyEncodableBox(inPlaceNoteParts.joined(separator: " "))], text: global.text, sandboxActive: sandboxActive)
                return
            }
            // ---- Condition replacement → whole-rule DELETE-AND-RECREATE. Two Mail bugs force this
            // shape: (1) `delete rule condition` crashes Mail (-609), and (2) `make new rule` with a
            // name that ALREADY EXISTS silently mangles the new rule's conditions. So delete the old
            // rule FIRST (name becomes unique), create a fresh rule DISABLED, VERIFY its conditions
            // attached, and only THEN re-enable it (a silently-condition-less rule would match ALL
            // mail). Two documented divergences from the MCP's in-place update (see CHANGELOG): the
            // rule MOVES TO THE END of the list, and its actions are RESET to the carried
            // mark_read/mark_flagged/delete set (2026-08-19, review-caught: `delete` joined the mark
            // flags once `readRuleScalars` started reading `delete message` back) — a move_to/
            // copy_to/flag_color action set manually in Mail.app is still NOT preserved
            // (readRuleScalars doesn't read those back). ----
            let old = try MailScript().readRuleScalars(index: target.index)
            let mergedName = name ?? old.name
            if sandboxActive { try RuleLiveGuards.requireLabeledName(mergedName) }  // sandboxed: preserved/renamed name stays labeled
            let mergedEnabled = enabled ?? old.enabled
            // Match logic: an explicit --match wins; else PRESERVE the rule's own OR/AND (the old
            // hardcoded `matchAll: true` silently converted a real OR rule to AND — review-caught).
            // Sandboxed recreates still force match=all so the label condition always constrains.
            let mergedMatchAll = sandboxActive ? true : (match.map { $0 == "all" } ?? old.matchAll)
            let mergedPlan: RuleLiveGuards.LiveActionPlan
            if let plan {
                mergedPlan = plan
            } else {
                // No --action given: carry the old rule's actions. readRuleScalars reads the mark
                // flags AND (2026-08-19, review-caught) `delete message` back; it still has no easy
                // readback of a rule's move/copy/flag-color target, so a condition-replace recreate
                // WITHOUT an explicit --action still loses any prior move_to/copy_to/flag_color
                // action — a documented divergence (CHANGELOG); pass --action to preserve those.
                var carried: [String] = []
                if old.markRead { carried.append("mark_read") }
                if old.markFlagged { carried.append("mark_flagged") }
                // delete IS now carried forward — readRuleScalars reads `delete message` back,
                // closing the gap this comment used to document. Safe: self-scoping for the
                // recreated rule is re-verified above (`requireSelfScoped` on the passed
                // --condition, sandboxed), so preserving a real delete action here is exactly as
                // safe as wiring it explicitly with --action delete=true would be.
                if old.deleteMessage { carried.append("delete") }
                mergedPlan = RuleLiveGuards.LiveActionPlan(markRead: old.markRead, markFlagged: old.markFlagged,
                                                           moveTo: nil, copyTo: nil, flagColorIndex: nil,
                                                           delete: old.deleteMessage, tokens: carried)
            }
            guard !mergedPlan.tokens.isEmpty else {
                throw AppleError.validation("the rule has no action and none was given — a live rule needs one; add --action move_to=… / mark_read=true / mark_flagged=true / flag_color=… .")
            }
            let condTriples = conds.map { (type: $0.field, op: $0.operator, value: $0.value, header: $0.header_name ?? "") }
            // Refuse if a DIFFERENT rule already carries the target name (the recreate would trigger
            // the duplicate-name condition-mangling). Checked BEFORE the old rule is deleted.
            if try MailScript().listRules().contains(where: { $0.index != target.index && $0.name == mergedName }) {
                throw AppleError.validation("another rule is already named '\(mergedName)' — recreate would collide; pick a different --name.")
            }
            // Delete-old-first is forced by the duplicate-name bug, so if the create then fails the old
            // rule is GONE — surface the spec needed to rebuild it by hand in every failure path.
            let recovery = "name='\(mergedName)' match=\(mergedMatchAll ? "all" : "any") enabled=\(mergedEnabled) conditions=[\(condTriples.map { "\($0.type):\($0.op):\($0.value)" }.joined(separator: ", "))] actions=[\(mergedPlan.tokens.joined(separator: ", "))]"
            try MailScript().deleteRule(index: target.index)                                // 1) old gone → name unique
            do {
                try MailScript().createRule(name: mergedName, enabled: false, matchAll: mergedMatchAll,   // 2) create DISABLED
                                            conditions: condTriples, plan: mergedPlan)
            } catch {
                throw AppleError.upstream("rule recreate FAILED to create the replacement AFTER deleting the old rule — the rule is GONE. Recreate it in Mail.app: \(recovery). (underlying: \(error))")
            }
            guard let created = try MailScript().listRules().first(where: { $0.name == mergedName }) else {
                throw AppleError.upstream("rule recreate failed — '\(mergedName)' is missing after create; the old rule was already deleted. Recreate in Mail.app: \(recovery)")
            }
            let attached = try MailScript().ruleConditionCount(index: created.index)         // 3) VERIFY conditions
            guard attached == condTriples.count else {
                try? MailScript().deleteRule(index: created.index)                           //    remove the malformed rule
                throw AppleError.upstream("rule recreate dropped conditions (\(attached)/\(condTriples.count) attached) — removed the malformed rule and did NOT enable it (a 0-condition rule matches ALL mail). Recreate in Mail.app: \(recovery)")
            }
            // MATCH-LOGIC VERIFICATION (review-caught 2026-08-19) — same rationale + fail-safe
            // shape as `RulesCreate.run()`'s twin (RuleLiveGuards.matchLogicMismatch): this
            // recreate calls the SAME createRule AppleScript, so it depends on the SAME
            // match-all invariant (forced true when sandboxed, so the label condition always
            // constrains the rebuilt rule) — it needs the same readback confirmation.
            let matchLogicReadback: Bool
            do {
                matchLogicReadback = try MailScript().readRuleScalars(index: created.index).matchAll
            } catch {
                try? MailScript().deleteRule(index: created.index)
                throw AppleError.upstream("rule recreate could not verify its match-all/any logic after creation (\(error)) — removed the malformed rule and did NOT enable it. Recreate in Mail.app: \(recovery)")
            }
            if let mismatch = RuleLiveGuards.matchLogicMismatch(requested: mergedMatchAll, readback: matchLogicReadback) {
                try? MailScript().deleteRule(index: created.index)
                throw AppleError.upstream(mismatch + " Recreate in Mail.app: \(recovery)")
            }
            if mergedEnabled {                                                              // 4) re-enable only once verified
                try MailScript().updateRuleMeta(index: created.index, name: nil, enabled: true, matchAll: nil, plan: nil)
            }
            let newIndex = (try? MailScript().listRules())?.first(where: { $0.name == mergedName })?.index ?? created.index
            try Output.emit(tool: "mail", data: [
                "updated_rule_index": AnyEncodableBox(newIndex),
                // Oracle A wire names (`rule_index` / `name`) alongside the CLI's originals.
                "rule_index": AnyEncodableBox(newIndex),
                "previous_index": AnyEncodableBox(target.index),
                "rule_name": AnyEncodableBox(mergedName),
                "name": AnyEncodableBox(mergedName),
                "conditions_attached": AnyEncodableBox(attached),
                "enabled": AnyEncodableBox(mergedEnabled),
                "match_logic": AnyEncodableBox(mergedMatchAll ? "all" : "any"),
                "actions": AnyEncodableBox(mergedPlan.tokens),
                "patch": AnyEncodableBox(patch), "recreated": AnyEncodableBox(true),
                "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                // Machine-readable twin of the prose advisory appended to `note` below. Computed off
                // the MERGED plan, not the requested --action: a recreate RESETS the action set, so
                // the merged plan is what the rebuilt rule actually carries.
                "warnings": AnyEncodableBox(RuleLiveGuards.liveActionWarnings(plan: mergedPlan)),
                "note": AnyEncodableBox("condition change → delete-and-recreated (Mail can't delete a rule condition); created disabled, conditions verified, re-enabled if it was enabled. DIVERGES from the MCP in-place update: rule MOVED TO END of list, and actions RESET to [\(mergedPlan.tokens.joined(separator: ", "))] — pass --action (move_to/copy_to/mark_read/mark_flagged/flag_color/delete) to set them explicitly, since a prior action NOT re-passed is not read back off the old rule."
                    + (mergedPlan.delete ? " WARNING: this rule's delete action will auto-trash matching mail (move it to Trash) once enabled — unattended, no confirmation step." : ""))], text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct RulesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a rule by index (irreversible; EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "1-based rule index.") var index: Int
    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            guard willExecute else {
                try Output.emit(tool: "mail", data: ["would_delete_rule_index": AnyEncodableBox(index), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)], text: global.text, sandboxActive: sandboxActive)
                return
            }
            let r = try requireLabeledRule(index: index, sandboxActive: sandboxActive)
            try MailScript().deleteRule(index: r.index)
            try Output.emit(tool: "mail", data: ["deleted_rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name),
             // `rule_index` + `deleted_name` are oracle A delete_rule's wire names.
             "rule_index": AnyEncodableBox(index), "deleted_name": AnyEncodableBox(r.name),
             "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true)], text: global.text, sandboxActive: sandboxActive)
        }
    }
}

struct RulesEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable a rule by index (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument var index: Int
    func run() throws { try setEnabled(index: index, enabled: true, global: global) }
}
struct RulesDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a rule by index (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument var index: Int
    func run() throws { try setEnabled(index: index, enabled: false, global: global) }
}

/// Resolve a rule by 1-based index (write-model v2). Inside the sandbox the rule's name must
/// be a labeled `apple-cli-test…` item — an agent run can only toggle/delete rules it created,
/// never a pre-existing real rule. Outside the sandbox, any rule resolves (the oracle's rule
/// ops operate on any rule on call).
func requireLabeledRule(index: Int, sandboxActive: Bool) throws -> MailScript.ScriptRule {
    let rules = try MailScript().listRules()
    guard let r = rules.first(where: { $0.index == index }) else {
        // Oracle A raises MailRuleNotFoundError → `error_type: "rule_not_found"` on every rule op.
        // Emitting the generic `not_found` left a consumer unable to tell "no such rule index"
        // from "no such message/mailbox". The exit code stays 65 (this CLI's not-found code) —
        // only the type string becomes oracle-exact.
        throw AppleError(type: "rule_not_found",
                         message: "no rule at index \(index) (see `rules list`).",
                         exitCode: AppleExit.notFound)
    }
    if sandboxActive, !r.name.hasPrefix(TestMode.sandboxPrefix) {
        throw AppleError.mailSafety("sandbox active: rule \(index) ('\(r.name)') is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate it.", sandbox: true)
    }
    return r
}

/// Gate/warn an ENABLE mutation off `target`'s REAL, on-disk delete state — not off any
/// `--action` passed in the CURRENT command. PURE (the caller reads `realDeleteMessage` back via
/// `MailScript.readRuleScalars` BEFORE calling this — `MailScript.runner` is the concrete
/// `AppleScriptRunner`, not an injectable protocol, so keeping the DECISION free of I/O is what
/// makes it directly unit-testable). Shared by `setEnabled` (`rules enable`/`rules disable`) and
/// the metadata-only branch of `rules update --enabled`, so a rule armed with `delete` by ONE
/// command and enabled by a SEPARATE command cannot bypass the single-command
/// `armsRelocatingOrDestructiveAction` refusal (review-caught 2026-08-19 — see
/// `RuleLiveGuards.realDeleteEnableRefusal`). Always `[]` when `enabling` is false — disabling a
/// rule only ever REDUCES what it can do, never arms anything.
func realDeleteEnableWarnings(target: MailScript.ScriptRule, realDeleteMessage: Bool, enabling: Bool,
                              sandboxActive: Bool) throws -> [String] {
    guard enabling, realDeleteMessage else { return [] }
    if sandboxActive {
        // Neither this gate nor the metadata-only `rules update --enabled` path re-reads/
        // re-verifies the rule's CONDITIONS as self-scoped — only its name label was checked
        // (`requireLabeledRule`), and under write-model v2 an UNSANDBOXED `rules create`/`rules
        // update` can author a labeled rule with arbitrary (non-self-scoped) conditions, so the
        // label alone is not trustworthy for a destructive action. Refuse unconditionally.
        throw AppleError.mailSafety("sandbox active: rule \(target.index) ('\(target.name)') "
            + RuleLiveGuards.realDeleteEnableRefusal, sandbox: true)
    }
    return [RuleLiveGuards.deleteActionWarning]
}

private func setEnabled(index: Int, enabled: Bool, global: GlobalOptions) throws {
    try runGuarded(tool: "mail") {
        // Write-model v2 preamble.
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)

        guard willExecute else {
            try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "would_set_enabled": AnyEncodableBox(enabled), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)], text: global.text, sandboxActive: sandboxActive)
            return
        }
        let r = try requireLabeledRule(index: index, sandboxActive: sandboxActive)
        // ARMING GATE (review-caught 2026-08-19; closes the two-command bypass — see
        // `realDeleteEnableWarnings` + `RuleLiveGuards.realDeleteEnableRefusal`). This command is
        // the ARMING MOMENT for any rule the sandboxed `rules create` path leaves disabled (its
        // envelope tells the operator to run `rules enable <index>`), so it is exactly where a
        // rule carrying a real `delete` action starts auto-trashing mail unattended if left
        // ungated. Gated off the rule's REAL on-disk state (`MailScript.readRuleScalars`), not
        // off anything passed in this command — `rules enable` takes no --action at all. Only
        // read back when ARMING (`enabled`): disabling never needs it (`realDeleteEnableWarnings`
        // is a no-op there anyway, but skipping the read avoids a pointless AppleScript round trip).
        let realDeleteMessage = enabled ? try MailScript().readRuleScalars(index: r.index).deleteMessage : false
        let warnings = try realDeleteEnableWarnings(target: r, realDeleteMessage: realDeleteMessage,
                                                     enabling: enabled, sandboxActive: sandboxActive)
        try MailScript().setRuleEnabled(index: r.index, enabled: enabled)
        try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name), "set_enabled": AnyEncodableBox(enabled),
         // `name` + `enabled` are oracle A set_rule_enabled's wire names; `rule_name` +
         // `set_enabled` are the CLI's original keys, kept for existing consumers.
         "name": AnyEncodableBox(r.name), "enabled": AnyEncodableBox(enabled), "warnings": AnyEncodableBox(warnings),
         "executed": AnyEncodableBox(true), "dry_run": AnyEncodableBox(false)], text: global.text, sandboxActive: sandboxActive)
    }
}

/// Emit exactly one envelope for a rule create DRY-RUN preview (the non-execute path only —
/// RulesCreate calls this with `willExecute: false`). Live create/update now apply real
/// mutations behind the RuleLiveGuards safety invariant, each emitting their own executed envelope.
/// Render a rule dry-run. `live_blockers` names every reason `--execute` would refuse THIS rule,
/// so the preview describes the rule the caller asked for (including oracle capabilities the live
/// path declines, such as `forward_to` / `--match any`) instead of failing outright. `warnings`
/// names advisory-only concerns for actions that ARE live-wired but stay dangerous (e.g. `delete`
/// auto-trashing matching mail once enabled) — these do NOT block execute. A preview that cannot
/// represent a capability is strictly less useful than one that represents it and says plainly
/// what would be refused (or should give the caller pause).
func emitRulePreview(_ rule: RuleSchema.Rule, willExecute: Bool, json: Bool,
                     liveBlockers: [String] = [], warnings: [String] = [], sandboxActive: Bool = false) throws {
    var noteParts: [String] = []
    if !liveBlockers.isEmpty {
        noteParts.append("preview only — `--execute` would refuse this rule: " + liveBlockers.joined(separator: "; "))
    }
    if !warnings.isEmpty {
        noteParts.append("advisory (would NOT be refused, but): " + warnings.joined(separator: "; "))
    }
    let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")
    if json {
        try Output.emit(tool: "mail", data: [
            "dry_run": AnyEncodableBox(!willExecute), "rule": AnyEncodableBox(rule),
            "live_blockers": AnyEncodableBox(liveBlockers), "warnings": AnyEncodableBox(warnings),
            "note": AnyEncodableBox(note)],
            sandboxActive: sandboxActive)
    } else {
        Output.printText("Rule '\(rule.name)' (\(rule.match_logic), \(rule.enabled ? "enabled" : "disabled")) — dry-run: \(!willExecute)")
        for b in liveBlockers { Output.printText("  would be refused live: \(b)") }
        for w in warnings { Output.printText("  warning: \(w)") }
    }
}

// MARK: templates (file-based; ~/.apple_mail_mcp/templates/<name>.md)

struct TemplatesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "templates",
        abstract: "Manage email templates (list/get/save/delete/render).",
        subcommands: [TemplatesList.self, TemplatesGet.self, TemplatesSave.self, TemplatesDelete.self, TemplatesRender.self],
        defaultSubcommand: TemplatesList.self)
}

struct TemplatesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List stored templates.")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: "mail") {
            let list = try TemplateStore().list()
            if global.json {
                try Output.emit(tool: "mail", data: TemplateStore.TemplatesResult(templates: list, count: list.count))
            } else {
                for t in list { Output.printText("\(t.name)\(t.subject != nil ? "  [subject]" : "")") }
            }
        }
    }
}

struct TemplatesGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a template by name.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() throws {
        try runGuarded(tool: "mail") {
            let tpl = try TemplateStore().get(name)
            if global.json { try Output.emit(tool: "mail", data: tpl) }
            else {
                if let subj = tpl.subject { Output.printText("subject: \(subj)") }
                Output.printText(tpl.body)
            }
        }
    }
}

struct TemplatesSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Create or overwrite a template (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Template body (may contain {placeholder} tokens).") var body: String
    @Option(name: .long, help: "Optional subject template.") var subject: String?
    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. This command was the spec's named bucket-2 defect: it had
            // NO willExecute branch and wrote despite --dry-run. It now previews faithfully; the
            // execute-path envelope is the template object plus the v2 `dry_run: false` stamp
            // (Q12 — the one Mail write that omitted it).
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            // Preview honesty: the same PURE validations the write performs, on both paths —
            // adding the willExecute branch had made `--dry-run` skip them, so a preview could
            // name a save execute refuses with 64 (review-caught).
            try TemplateStore.validateSave(name: name, body: body, subject: subject)
            guard willExecute else {
                try Output.emit(tool: "mail", data: ["would_save_template": AnyEncodableBox(name),
                    "has_subject": AnyEncodableBox(subject != nil), "dry_run": AnyEncodableBox(true)], text: global.text, sandboxActive: sandboxActive)
                return
            }
            let tpl = try TemplateStore().save(name: name, body: body, subject: subject)
            // Q12: the execute envelope stamps `dry_run: false` (additive) — the template
            // object's own fields are unchanged; "original shape" no longer trumps the v2
            // execute-envelope rule the other 20 Mail writes follow.
            if global.json { try Output.emit(tool: "mail", data: ExecutedWrite(tpl), sandboxActive: sandboxActive) }
            else { Output.printText("saved template '\(tpl.name)'") }
        }
    }
}

struct TemplatesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a template (irreversible; EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. Oracle A wraps delete_template in MCP elicitation; a CLI
            // has no elicitation channel — the explicit invocation is the accept (documented
            // divergence, docs/write-model-v2.md bucket 4). Executes by default.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let store = TemplateStore()
            _ = try store.get(name)   // 404 if missing
            if willExecute {
                try store.delete(name)
                // `name` mirrors the oracle's delete_template wire key; `deleted_template` is the
                // CLI's original name, kept so existing consumers don't break. dry_run: false is
                // EXPLICIT — under v2 it is how a caller distinguishes previewed from done.
                if global.json {
                    try Output.emit(tool: "mail", data: ["deleted_template": AnyEncodableBox(name), "name": AnyEncodableBox(name), "executed": AnyEncodableBox(true), "dry_run": AnyEncodableBox(false)], sandboxActive: sandboxActive)
                } else { Output.printText("deleted template '\(name)'") }
            } else {
                try Output.emit(tool: "mail", data: ["would_delete_template": AnyEncodableBox(name), "dry_run": AnyEncodableBox(true)], text: global.text, sandboxActive: sandboxActive)
            }
        }
    }
}

struct TemplatesRender: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render", abstract: "Render a template into ready-to-send subject + body.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Source message id for reply context (auto-fills recipient_name/email/original_subject).") var messageId: String?
    @Option(name: .long, help: "Variable override 'key=value' (repeatable).") var `var`: [String] = []

    func run() throws {
        try runGuarded(tool: "mail") {
            var autoVars = ["today": TemplateStore.todayString()]
            if let messageId {
                let ctx = try MailContext()
                // Oracle parity: an unresolvable message_id is an ERROR (oracle A's
                // `auto_template_vars` calls get_message, which raises MailMessageNotFoundError →
                // error_type `message_not_found`). Silently rendering with only `today` used to
                // drop recipient_name/email/original_subject AND — now that unresolved
                // placeholders raise — would surface as a confusing missing-variable error.
                guard let row = try resolveMessageRow(ctx: ctx, id: messageId) else {
                    throw AppleError(type: "message_not_found",
                                     message: "no message for id '\(messageId)'.",
                                     exitCode: AppleExit.notFound)
                }
                let m = ctx.decodeSummary(row)
                // Oracle fallback chain (`auto_template_vars`): recipient_email is the PARSED
                // address or, failing that, the raw sender field; recipient_name is the display
                // name or, failing that, recipient_email. So all three keys are ALWAYS present
                // once a message resolved — never omitted because a column was empty.
                let email = m.sender_address?.isEmpty == false ? m.sender_address! : m.sender
                autoVars["recipient_email"] = email
                autoVars["recipient_name"] = m.sender_name?.isEmpty == false ? m.sender_name! : email
                autoVars["original_subject"] = m.subject
            }
            var userVars: [String: String] = [:]
            for kv in `var` {
                guard let eq = kv.firstIndex(of: "=") else { throw AppleError.validation("--var must be 'key=value'; got '\(kv)'.") }
                userVars[String(kv[kv.startIndex..<eq])] = String(kv[kv.index(after: eq)...])
            }
            let result = try TemplateStore().render(name: name, autoVars: autoVars, userVars: userVars)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else {
                if let subj = result.subject { Output.printText("subject: \(subj)") }
                Output.printText(result.body)
            }
        }
    }
}
