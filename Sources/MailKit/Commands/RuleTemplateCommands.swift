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
            else { for r in infos { print("\(r.index). \(r.name) [\(r.enabled ? "enabled" : "disabled")]") } }
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
                // predicting is not the same as refusing: `delete`, `forward_to` and `--match any`
                // are real oracle capabilities the live path declines for safety, and a preview
                // that cannot even describe them loses the capability entirely. So: report every
                // blocker, and only fail the preview on genuinely MALFORMED input.
                // MALFORMED input still fails the preview. Control characters in a name/value/
                // header would desynchronize the US/RS framing the condition blob uses, so they
                // are rejected here too — not only on the live path, which a preview would
                // otherwise misreport as fine.
                try RuleLiveGuards.requireNoControlChars(name: name, conditions: conditions)
                // Blockers are computed under the SAME sandboxActive the execute path uses, or
                // the preview lies (docs/write-model-v2.md). The delete/forward_to blockers are
                // UNWIRED capabilities and apply in both modes; the label/self-scope/match-any
                // restrictions are the sandbox's.
                var blockers = RuleLiveGuards.liveActionBlockers(actions)
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
                if blockers.isEmpty { _ = try RuleLiveGuards.liveActionPlan(actions) }
                try emitRulePreview(rule, willExecute: false, json: global.json, liveBlockers: blockers,
                                    sandboxActive: sandboxActive)
                return
            }
            // ---- Live create (write-model v2). Sandboxed: SELF-SCOPED, non-destructive,
            // force-disabled — a sandboxed rule must be UNABLE to affect real mail even if later
            // enabled: (a) bound to the test label, (b) no destructive/redirect action, (c)
            // force-disabled. Unsandboxed: the rule is created AS SPECIFIED (the oracle's
            // create_rule creates on call) — delete/forward_to remain refused in liveActionPlan
            // because they are unwired in MailScript, a tracked capability gap, not a gate.
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
            if createEnabled {
                try script.updateRuleMeta(index: created.index, name: nil, enabled: true, matchAll: nil, plan: nil)
            }
            // Oracle A `create_rule` returns `rule_index` (the new total rule count) and `name`.
            // Mail exposes no "index of this rule" property, so re-read the list and take the
            // count — same definition the oracle uses. Best-effort: a read failure must not fail
            // an already-successful create, so the key is simply omitted then.
            let newIndex = (try? script.listRules().count).map(AnyEncodableBox.init)
            try Output.emit(tool: "mail", data: [
                "created_rule": AnyEncodableBox(name), "conditions": AnyEncodableBox(conditions),
                // `name` + `rule_index` are oracle A's wire names; `created_rule` is the CLI's
                // original key, kept so existing consumers don't break (additive → MINOR).
                "name": AnyEncodableBox(name), "rule_index": AnyEncodableBox(newIndex),
                "actions": AnyEncodableBox(plan.tokens), "match_logic": AnyEncodableBox(createMatchAll ? "all" : "any"),
                "enabled": AnyEncodableBox(createEnabled), "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                "note": AnyEncodableBox(sandboxActive
                    ? "sandbox: created SELF-SCOPED to the test label + DISABLED — it can only ever act on apple-cli-test mail; `rules enable <index>` to activate"
                    : nil)], sandboxActive: sandboxActive)
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
            // OR-rule and a delete/forward_to action are real oracle capabilities, and a preview
            // that refuses to describe them loses the capability from the surface entirely. Under
            // --execute they are still hard refusals (below).
            // Blockers computed under the SAME sandboxActive the execute path uses, or the
            // preview lies. delete/forward_to blockers are unwired capabilities (both modes);
            // the label/self-scope/match-any restrictions are the sandbox's.
            var blockers: [String] = []
            if let acts { blockers.append(contentsOf: RuleLiveGuards.liveActionBlockers(acts)) }
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
            }

            guard willExecute else {
                // Still fail the preview on MALFORMED input, so a dry-run keeps predicting the
                // execute outcome for everything that is not a deliberate safety refusal.
                try RuleLiveGuards.requireNoControlChars(name: name, conditions: conds ?? [])
                if blockers.isEmpty, let acts { _ = try RuleLiveGuards.liveActionPlan(acts) }
                let recreates = conds != nil
                let note = blockers.isEmpty ? nil
                    : "preview only — `--execute` would refuse this update: " + blockers.joined(separator: "; ")
                if global.json {
                    try Output.emit(tool: "mail", data: ["dry_run": AnyEncodableBox(true), "patch": AnyEncodableBox(patch),
                        "would_recreate": AnyEncodableBox(recreates), "live_blockers": AnyEncodableBox(blockers),
                        "note": AnyEncodableBox(note)], sandboxActive: sandboxActive)
                } else {
                    print("Would update rule \(index) (dry-run; \(recreates ? "condition change → delete-and-recreate" : "in-place"))")
                    for b in blockers { print("  would be refused live: \(b)") }
                }
                return
            }
            if sandboxActive {
                if match == "any" {   // a sandboxed rule must stay match=all so its label always constrains it
                    throw AppleError.mailSafety("sandbox active: a sandboxed rule must stay --match all so its label condition always constrains it — refusing to set --match any.")
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
                // conditions are NOT re-verified self-scoped (same boundary as `rules enable`). The
                // tool's own create/recreate can't author a labeled rule that acts on real mail; a
                // hand-made one (Mail.app UI) is the operator's responsibility. To keep that boundary
                // from being widened by the newly-wired move/copy actions, refuse to ENABLE a rule in
                // the SAME call that wires a move_to/copy_to: activation must be a separate, operator-
                // visible `rules enable` (or pass --condition to route through the self-scoping
                // recreate path). A CLI-authored rule is always created disabled + self-scoped, so this
                // never blocks the normal flow.
                if sandboxActive, enabled == true, let p = plan, (p.moveTo != nil || p.copyTo != nil) {
                    throw AppleError.mailSafety("sandbox active: wiring move_to/copy_to on an in-place update cannot also ENABLE the rule in the same command (its existing conditions are not re-verified self-scoped) — omit --enabled and enable separately after review, or pass --condition to route through the self-scoping recreate path.")
                }
                // `map` so `--match any` actually applies (false = set OR). The old
                // `match == "all" ? true : nil` collapsed "any" to nil = "don't change" — a
                // silent no-op reported as executed:true once the sandbox-only refusal stopped
                // covering the unsandboxed path (review-caught).
                try MailScript().updateRuleMeta(index: target.index, name: name, enabled: enabled,
                                                matchAll: match.map { $0 == "all" }, plan: plan)
                try Output.emit(tool: "mail", data: [
                    "updated_rule_index": AnyEncodableBox(target.index),
                    // `rule_index` is oracle A update_rule's wire name; `updated_rule_index` is
                    // the CLI's original key, kept for existing consumers (additive → MINOR).
                    "rule_index": AnyEncodableBox(target.index),
                    "rule_name": AnyEncodableBox(name ?? target.name),
                    "name": AnyEncodableBox(name ?? target.name),
                    "patch": AnyEncodableBox(patch), "recreated": AnyEncodableBox(false),
                    "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                    // When --action is given, the supported action set is RESET then reapplied
                    // (wholesale replace, matching the oracle) — the `patch.actions` ARE the rule's
                    // full modeled action set afterward; rules carrying unmodeled actions were refused
                    // above, so nothing unmanaged survives.
                    "note": AnyEncodableBox(plan != nil ? "patched in place; supported actions reset to the given set (wholesale replace)" : "patched in place")], sandboxActive: sandboxActive)
                return
            }
            // ---- Condition replacement → whole-rule DELETE-AND-RECREATE. Two Mail bugs force this
            // shape: (1) `delete rule condition` crashes Mail (-609), and (2) `make new rule` with a
            // name that ALREADY EXISTS silently mangles the new rule's conditions. So delete the old
            // rule FIRST (name becomes unique), create a fresh rule DISABLED, VERIFY its conditions
            // attached, and only THEN re-enable it (a silently-condition-less rule would match ALL
            // mail). Two documented divergences from the MCP's in-place update (see CHANGELOG): the
            // rule MOVES TO THE END of the list, and its actions are RESET to the carried
            // mark_read/mark_flagged set — a non-mark action set manually in Mail.app is NOT preserved
            // (readRuleScalars reads only the mark flags). ----
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
                // No --action given: carry the old rule's actions. readRuleScalars reads only the mark
                // flags (Mail exposes no easy readback of a rule's move/copy/flag-color target), so a
                // condition-replace recreate WITHOUT an explicit --action loses any prior move/copy/
                // flag-color action — a documented divergence (CHANGELOG); pass --action to preserve it.
                var carried: [String] = []
                if old.markRead { carried.append("mark_read") }
                if old.markFlagged { carried.append("mark_flagged") }
                mergedPlan = RuleLiveGuards.LiveActionPlan(markRead: old.markRead, markFlagged: old.markFlagged,
                                                           moveTo: nil, copyTo: nil, flagColorIndex: nil, tokens: carried)
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
                "note": AnyEncodableBox("condition change → delete-and-recreated (Mail can't delete a rule condition); created disabled, conditions verified, re-enabled if it was enabled. DIVERGES from the MCP in-place update: rule MOVED TO END of list, and actions RESET to [\(mergedPlan.tokens.joined(separator: ", "))] — pass --action (move_to/copy_to/mark_read/mark_flagged/flag_color) to set them explicitly, since a prior action NOT re-passed is not read back off the old rule.")], sandboxActive: sandboxActive)
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
                try Output.emit(tool: "mail", data: ["would_delete_rule_index": AnyEncodableBox(index), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)], sandboxActive: sandboxActive)
                return
            }
            let r = try requireLabeledRule(index: index, sandboxActive: sandboxActive)
            try MailScript().deleteRule(index: r.index)
            try Output.emit(tool: "mail", data: ["deleted_rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name),
             // `rule_index` + `deleted_name` are oracle A delete_rule's wire names.
             "rule_index": AnyEncodableBox(index), "deleted_name": AnyEncodableBox(r.name),
             "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true)], sandboxActive: sandboxActive)
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
        throw AppleError.mailSafety("sandbox active: rule \(index) ('\(r.name)') is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate it.")
    }
    return r
}

private func setEnabled(index: Int, enabled: Bool, global: GlobalOptions) throws {
    try runGuarded(tool: "mail") {
        // Write-model v2 preamble.
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)

        guard willExecute else {
            try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "would_set_enabled": AnyEncodableBox(enabled), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)], sandboxActive: sandboxActive)
            return
        }
        let r = try requireLabeledRule(index: index, sandboxActive: sandboxActive)
        try MailScript().setRuleEnabled(index: r.index, enabled: enabled)
        try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name), "set_enabled": AnyEncodableBox(enabled),
         // `name` + `enabled` are oracle A set_rule_enabled's wire names; `rule_name` +
         // `set_enabled` are the CLI's original keys, kept for existing consumers.
         "name": AnyEncodableBox(r.name), "enabled": AnyEncodableBox(enabled),
         "executed": AnyEncodableBox(true), "dry_run": AnyEncodableBox(false)], sandboxActive: sandboxActive)
    }
}

/// Emit exactly one envelope for a rule create DRY-RUN preview (the non-execute path only —
/// RulesCreate calls this with `willExecute: false`). Live create/update now apply real
/// mutations behind the RuleLiveGuards safety invariant, each emitting their own executed envelope.
/// Render a rule dry-run. `live_blockers` names every reason `--execute` would refuse THIS rule,
/// so the preview describes the rule the caller asked for (including oracle capabilities the live
/// path declines, such as `delete` / `forward_to` / `--match any`) instead of failing outright.
/// A preview that cannot represent a capability is strictly less useful than one that represents
/// it and says plainly what would be refused.
func emitRulePreview(_ rule: RuleSchema.Rule, willExecute: Bool, json: Bool,
                     liveBlockers: [String] = [], sandboxActive: Bool = false) throws {
    let note = liveBlockers.isEmpty ? nil
        : "preview only — `--execute` would refuse this rule: " + liveBlockers.joined(separator: "; ")
    if json {
        try Output.emit(tool: "mail", data: [
            "dry_run": AnyEncodableBox(!willExecute), "rule": AnyEncodableBox(rule),
            "live_blockers": AnyEncodableBox(liveBlockers), "note": AnyEncodableBox(note)],
            sandboxActive: sandboxActive)
    } else {
        print("Rule '\(rule.name)' (\(rule.match_logic), \(rule.enabled ? "enabled" : "disabled")) — dry-run: \(!willExecute)")
        for b in liveBlockers { print("  would be refused live: \(b)") }
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
            try Output.emit(tool: "mail", data: TemplateStore.TemplatesResult(templates: list, count: list.count))
        }
    }
}

struct TemplatesGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a template by name.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() throws { try runGuarded(tool: "mail") { try Output.emit(tool: "mail", data: try TemplateStore().get(name)) } }
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
            // execute-path envelope keeps its original shape (the template object) unchanged.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            // Preview honesty: the same PURE validations the write performs, on both paths —
            // adding the willExecute branch had made `--dry-run` skip them, so a preview could
            // name a save execute refuses with 64 (review-caught).
            try TemplateStore.validateSave(name: name, body: body, subject: subject)
            guard willExecute else {
                try Output.emit(tool: "mail", data: ["would_save_template": AnyEncodableBox(name),
                    "has_subject": AnyEncodableBox(subject != nil), "dry_run": AnyEncodableBox(true)], sandboxActive: sandboxActive)
                return
            }
            let tpl = try TemplateStore().save(name: name, body: body, subject: subject)
            try Output.emit(tool: "mail", data: tpl, sandboxActive: sandboxActive)
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
                try Output.emit(tool: "mail", data: ["deleted_template": AnyEncodableBox(name), "name": AnyEncodableBox(name), "executed": AnyEncodableBox(true), "dry_run": AnyEncodableBox(false)], sandboxActive: sandboxActive)
            } else {
                try Output.emit(tool: "mail", data: ["would_delete_template": AnyEncodableBox(name), "dry_run": AnyEncodableBox(true)], sandboxActive: sandboxActive)
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
            try Output.emit(tool: "mail", data: result)
        }
    }
}
