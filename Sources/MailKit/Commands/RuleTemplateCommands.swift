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
            try emitRulePreview(rule, willExecute: global.willExecute, json: global.json)
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
            // Rules are pre-existing real data; live mutation is disabled in this build (safety) —
            // emit exactly one preview envelope, never a second (error) envelope.
            let note = global.willExecute ? "live rule deletion is disabled in this build (rules are pre-existing real data); this is a preview" : nil
            try Output.emit(tool: "mail", data: ["would_delete_rule_index": AnyEncodableBox(index), "dry_run": AnyEncodableBox(!global.willExecute), "note": AnyEncodableBox(note)])
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

private func setEnabled(index: Int, enabled: Bool, global: GlobalOptions) throws {
    try runGuarded(tool: "mail") {
        // Rules are pre-existing real data; live mutation is disabled in this build (safety) —
        // exactly one preview envelope.
        let note = global.willExecute ? "live rule enable/disable is disabled in this build (rules are pre-existing real data); this is a preview" : nil
        try Output.emit(tool: "mail", data: ["rule_index": AnyEncodableBox(index), "would_set_enabled": AnyEncodableBox(enabled), "dry_run": AnyEncodableBox(!global.willExecute), "note": AnyEncodableBox(note)])
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
