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
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a rule (dry-run preview by default; --execute to apply).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var name: String
    @Option(name: .long, help: "Condition 'field:operator:value[:header]' (repeatable).") var condition: [String] = []
    @Option(name: .long, help: "Action 'key=value' (repeatable): move_to/copy_to/mark_read/mark_flagged/flag_color/delete/forward_to.") var action: [String] = []
    @Option(name: .long, help: "Match logic: all (AND) or any (OR).") var match: String = "all"
    @Flag(name: .long, help: "Create the rule disabled.") var disabled = false

    func run() throws {
        try runGuarded(tool: "mail") {
            guard !condition.isEmpty else { throw AppleError.validation("at least one --condition is required.") }
            guard match == "all" || match == "any" else { throw AppleError.validation("--match must be 'all' or 'any'.") }
            let conditions = try condition.map { try RuleSchema.parseCondition($0) }
            let actions = try RuleSchema.parseActions(action)
            let rule = RuleSchema.Rule(name: name, conditions: conditions, actions: actions, match_logic: match, enabled: !disabled)
            guard global.willExecute else {
                try emitRulePreview(rule, willExecute: false, json: global.json); return
            }
            // ---- Live create: SELF-SCOPED, non-destructive, force-disabled. ----
            // A test rule must be UNABLE to affect real mail even if later enabled by the same
            // agent: (a) bound to the test label so it only ever matches test mail, (b) no
            // destructive/redirect action, (c) force-disabled. The (a)+(b) invariant lives in
            // RuleLiveGuards so `rules create` and `rules update` enforce it identically.
            guard global.testMode && TestMode.isEnabled else {
                throw AppleError.mailSafety("creating a rule requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
            }
            try RuleLiveGuards.requireLabeledName(name)
            try RuleLiveGuards.requireNoControlChars(name: name, conditions: conditions)
            try RuleLiveGuards.requireSelfScoped(conditions: conditions, match: match)   // enforces --match all
            let actToks = try RuleLiveGuards.liveActionTokens(actions)
            let conds = conditions.map { (type: $0.field, op: $0.operator, value: $0.value) }
            // match=all is enforced by requireSelfScoped, so the rule is an AND rule — thread it.
            try MailScript().createRule(name: name, enabled: false, matchAll: true, conditions: conds, actions: actToks)
            try Output.emit(tool: "mail", data: [
                "created_rule": AnyEncodableBox(name), "conditions": AnyEncodableBox(conditions),
                "actions": AnyEncodableBox(actToks), "match_logic": AnyEncodableBox("all"),
                "enabled": AnyEncodableBox(false), "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                "note": AnyEncodableBox("created SELF-SCOPED to the test label + DISABLED — it can only ever act on apple-cli-test mail; `rules enable <index>` to activate")])
        }
    }
}

struct RulesUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a rule by index (patch; dry-run by default).")
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
            if match == "any" {   // a live test rule must stay match=all so its label always constrains it
                throw AppleError.mailSafety("a live test rule must stay --match all so its label condition always constrains it — refusing to set --match any.")
            }
            if let name { try RuleLiveGuards.requireLabeledName(name) }        // a rename must keep the label
            try RuleLiveGuards.requireNoControlChars(name: name, conditions: conds ?? [])
            if let conds { try RuleLiveGuards.requireSelfScoped(conditions: conds, match: "all") }
            let actToks = try acts.map { try RuleLiveGuards.liveActionTokens($0) }

            guard global.willExecute else {
                let recreates = conds != nil
                if global.json { try Output.emit(tool: "mail", data: ["dry_run": AnyEncodableBox(true), "patch": AnyEncodableBox(patch), "would_recreate": AnyEncodableBox(recreates), "note": AnyEncodableBox(Optional<String>.none)]) }
                else { print("Would update rule \(index) (dry-run; \(recreates ? "condition change → delete-and-recreate" : "in-place"))") }
                return
            }
            // ---- Live. Target MUST be a labeled test rule (requireLabeledRule fail-closes on real rules). ----
            let target = try requireLabeledRule(index: index, testMode: global.testMode)

            guard let conds else {
                // ---- Metadata-only patch → modify IN PLACE (reliable; preserves rule position). ----
                // LABEL-TRUST BOUNDARY: enabling here trusts the rule's NAME label only — its EXISTING
                // conditions/actions are NOT re-verified (same boundary as `rules enable`). The tool's
                // own create/recreate can't author a labeled rule that acts on real mail; a hand-made
                // one (Mail.app UI) is the operator's responsibility.
                try MailScript().updateRuleMeta(index: target.index, name: name, enabled: enabled,
                                                matchAll: match == "all" ? true : nil, actions: actToks)
                try Output.emit(tool: "mail", data: [
                    "updated_rule_index": AnyEncodableBox(target.index),
                    "rule_name": AnyEncodableBox(name ?? target.name),
                    "patch": AnyEncodableBox(patch), "recreated": AnyEncodableBox(false),
                    "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                    "note": AnyEncodableBox("patched in place")])
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
            try RuleLiveGuards.requireLabeledName(mergedName)          // a preserved/renamed name must be labeled
            let mergedEnabled = enabled ?? old.enabled
            var mergedTokens = actToks
            if mergedTokens == nil {
                var carried: [String] = []
                if old.markRead { carried.append("mark_read") }
                if old.markFlagged { carried.append("mark_flagged") }
                mergedTokens = carried
            }
            guard let finalTokens = mergedTokens, !finalTokens.isEmpty else {
                throw AppleError.validation("the rule has no mark_read/mark_flagged action and none was given — a live rule needs one; add --action mark_read=true or mark_flagged=true.")
            }
            let condTriples = conds.map { (type: $0.field, op: $0.operator, value: $0.value) }
            // Refuse if a DIFFERENT rule already carries the target name (the recreate would trigger
            // the duplicate-name condition-mangling). Checked BEFORE the old rule is deleted.
            if try MailScript().listRules().contains(where: { $0.index != target.index && $0.name == mergedName }) {
                throw AppleError.validation("another rule is already named '\(mergedName)' — recreate would collide; pick a different --name.")
            }
            // Delete-old-first is forced by the duplicate-name bug, so if the create then fails the old
            // rule is GONE — surface the spec needed to rebuild it by hand in every failure path.
            let recovery = "name='\(mergedName)' match=all enabled=\(mergedEnabled) conditions=[\(condTriples.map { "\($0.type):\($0.op):\($0.value)" }.joined(separator: ", "))] actions=[\(finalTokens.joined(separator: ", "))]"
            try MailScript().deleteRule(index: target.index)                                // 1) old gone → name unique
            do {
                try MailScript().createRule(name: mergedName, enabled: false, matchAll: true,   // 2) create DISABLED
                                            conditions: condTriples, actions: finalTokens)
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
                try MailScript().updateRuleMeta(index: created.index, name: nil, enabled: true, matchAll: nil, actions: nil)
            }
            let newIndex = (try? MailScript().listRules())?.first(where: { $0.name == mergedName })?.index ?? created.index
            try Output.emit(tool: "mail", data: [
                "updated_rule_index": AnyEncodableBox(newIndex),
                "previous_index": AnyEncodableBox(target.index),
                "rule_name": AnyEncodableBox(mergedName),
                "conditions_attached": AnyEncodableBox(attached),
                "enabled": AnyEncodableBox(mergedEnabled),
                "actions": AnyEncodableBox(finalTokens),
                "patch": AnyEncodableBox(patch), "recreated": AnyEncodableBox(true),
                "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                "note": AnyEncodableBox("condition change → delete-and-recreated (Mail can't delete a rule condition); created disabled, conditions verified, re-enabled if it was enabled. DIVERGES from the MCP in-place update: rule MOVED TO END of list, and actions RESET to [\(finalTokens.joined(separator: ", "))] (a non-mark action set in Mail.app is NOT preserved).")])
        }
    }
}

struct RulesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a rule by index (irreversible; --execute to apply).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "1-based rule index.") var index: Int
    func run() throws {
        try runGuarded(tool: "mail") {
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: ["would_delete_rule_index": AnyEncodableBox(index), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)])
                return
            }
            let r = try requireLabeledRule(index: index, testMode: global.testMode)
            try MailScript().deleteRule(index: r.index)
            try Output.emit(tool: "mail", data: ["deleted_rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name), "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true)])
        }
    }
}

struct RulesEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable a rule by index.")
    @OptionGroup var global: GlobalOptions
    @Argument var index: Int
    func run() throws { try setEnabled(index: index, enabled: true, global: global) }
}
struct RulesDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a rule by index.")
    @OptionGroup var global: GlobalOptions
    @Argument var index: Int
    func run() throws { try setEnabled(index: index, enabled: false, global: global) }
}

/// Resolve a rule by 1-based index and FAIL-CLOSED unless test-mode is on AND the rule's name is
/// a labeled `apple-cli-test…` item — so an autonomous run can only toggle/delete rules it
/// created, never a pre-existing real rule (AGENTS.md dangerous-action rule).
func requireLabeledRule(index: Int, testMode: Bool) throws -> MailScript.ScriptRule {
    guard testMode && TestMode.isEnabled else {
        throw AppleError.mailSafety("live rule mutation requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
    }
    let rules = try MailScript().listRules()
    guard let r = rules.first(where: { $0.index == index }) else {
        throw AppleError.notFound("no rule at index \(index) (see `rules list`).")
    }
    guard r.name.hasPrefix(TestMode.sandboxPrefix) else {
        throw AppleError.mailSafety("rule \(index) ('\(r.name)') is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate a real rule.")
    }
    return r
}

private func setEnabled(index: Int, enabled: Bool, global: GlobalOptions) throws {
    try runGuarded(tool: "mail") {
        guard global.willExecute else {
            try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "would_set_enabled": AnyEncodableBox(enabled), "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox(Optional<String>.none)])
            return
        }
        let r = try requireLabeledRule(index: index, testMode: global.testMode)
        try MailScript().setRuleEnabled(index: r.index, enabled: enabled)
        try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "rule_name": AnyEncodableBox(r.name), "set_enabled": AnyEncodableBox(enabled), "executed": AnyEncodableBox(true), "dry_run": AnyEncodableBox(false)])
    }
}

/// Emit exactly one envelope for a rule create DRY-RUN preview (the non-execute path only —
/// RulesCreate calls this with `willExecute: false`). Live create/update now apply real
/// mutations behind the RuleLiveGuards safety invariant, each emitting their own executed envelope.
func emitRulePreview(_ rule: RuleSchema.Rule, willExecute: Bool, json: Bool) throws {
    let note = willExecute ? "live rule mutation is disabled in this build (rules are pre-existing real data); this is a preview" : nil
    if json {
        try Output.emit(tool: "mail", data: ["dry_run": AnyEncodableBox(!willExecute), "rule": AnyEncodableBox(rule), "note": AnyEncodableBox(note)])
    } else {
        print("Rule '\(rule.name)' (\(rule.match_logic), \(rule.enabled ? "enabled" : "disabled")) — dry-run: \(!willExecute)")
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
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Create or overwrite a template.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Template body (may contain {placeholder} tokens).") var body: String
    @Option(name: .long, help: "Optional subject template.") var subject: String?
    func run() throws {
        try runGuarded(tool: "mail") {
            let tpl = try TemplateStore().save(name: name, body: body, subject: subject)
            try Output.emit(tool: "mail", data: tpl)
        }
    }
}

struct TemplatesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a template (irreversible; --execute to apply).")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() throws {
        try runGuarded(tool: "mail") {
            let store = TemplateStore()
            _ = try store.get(name)   // 404 if missing
            if global.willExecute {
                try store.delete(name)
                try Output.emit(tool: "mail", data: ["deleted_template": AnyEncodableBox(name), "executed": AnyEncodableBox(true)])
            } else {
                try Output.emit(tool: "mail", data: ["would_delete_template": AnyEncodableBox(name), "dry_run": AnyEncodableBox(true)])
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
                if let row = try resolveMessageRow(ctx: ctx, id: messageId) {
                    let m = ctx.decodeSummary(row)
                    if let n = m.sender_name { autoVars["recipient_name"] = n }
                    if let a = m.sender_address { autoVars["recipient_email"] = a }
                    autoVars["original_subject"] = m.subject
                }
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
