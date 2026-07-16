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
            // agent, so it must (a) be bound to the test label so it only ever matches test mail,
            // and (b) carry no destructive/redirect action. Force-disabled is the third layer.
            guard global.testMode && TestMode.isEnabled else {
                throw AppleError.mailSafety("creating a rule requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
            }
            guard name.hasPrefix(TestMode.sandboxPrefix) else {
                throw AppleError.mailSafety("rule name '\(name)' is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing.")
            }
            // Reject the argv field delimiters so a stray control char can't desync the blob parse.
            let ctrl = CharacterSet(charactersIn: "\u{1e}\u{1f}")
            if name.rangeOfCharacter(from: ctrl) != nil || conditions.contains(where: { $0.value.rangeOfCharacter(from: ctrl) != nil }) {
                throw AppleError.validation("rule name/condition values must not contain RS/US (0x1E/0x1F) control characters.")
            }
            // (a) Self-scoping: --match all AND a subject condition bound to the test label, so the
            // rule can only ever fire on `apple-cli-test…` mail — never real mail, even once enabled.
            guard match == "all" else {
                throw AppleError.mailSafety("a live-created test rule must use --match all so its test-label condition always constrains it — refusing (use the preview for --match any).")
            }
            let selfScoped = conditions.contains {
                $0.field == "subject" && ["contains", "begins_with", "equals"].contains($0.operator) && $0.value.contains(TestMode.sandboxPrefix)
            }
            guard selfScoped else {
                throw AppleError.mailSafety("a live-created test rule must include a subject condition bound to the test label (e.g. --condition \"subject:contains:\(TestMode.sandboxPrefix)\") so it only ever acts on test mail — refusing.")
            }
            // (b) No destructive / redirect / unresolved actions on a live-created rule.
            if let fwd = actions.forward_to, !fwd.isEmpty {
                throw AppleError.mailSafety("a live-created rule with forward_to can auto-send to others — refused; create such a rule in Mail.app.")
            }
            if actions.delete == true {
                throw AppleError.mailSafety("a live-created rule with a delete action could auto-trash mail once enabled — refused; test delete-action rules in Mail.app.")
            }
            if actions.move_to != nil || actions.copy_to != nil {
                throw AppleError.validation("live rule create supports mark_read/mark_flagged; move_to/copy_to need a resolved mailbox — set them in Mail.app or use the preview.")
            }
            if actions.flag_color != nil {
                throw AppleError.validation("live rule create does not wire the flag_color action yet — set it in Mail.app or use the preview.")
            }
            if conditions.contains(where: { $0.field == "header_name" }) {
                throw AppleError.validation("live rule create does not support header_name conditions yet — set them in Mail.app or use the preview.")
            }
            let conds = conditions.map { (type: $0.field, op: $0.operator, value: $0.value) }
            var actToks: [String] = []
            if actions.mark_read == true { actToks.append("mark_read") }
            if actions.mark_flagged == true { actToks.append("mark_flagged") }
            guard !actToks.isEmpty else {
                throw AppleError.validation("live rule create needs at least one of mark_read/mark_flagged (delete/forward/color/move are refused or preview-only).")
            }
            // match=all is enforced above, so the rule is an AND rule — thread it so execute matches preview.
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
            let note = global.willExecute ? "live rule mutation is disabled in this build (rules are pre-existing real data); this is a preview" : nil
            if global.json { try Output.emit(tool: "mail", data: ["dry_run": AnyEncodableBox(!global.willExecute), "patch": AnyEncodableBox(patch), "note": AnyEncodableBox(note)]) }
            else { print("Would update rule \(index) (dry-run: \(!global.willExecute))") }
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

/// Emit exactly one envelope for a rule create/update preview. Live rule mutation is not
/// wired in this build (rules are pre-existing real data), so `--execute` yields a preview
/// with a `note`, never a second (error) envelope.
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
