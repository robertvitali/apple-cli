import Foundation

/// The one tilde policy for OPERATOR-SUPPLIED paths, applied BEFORE `expandingTildeInPath`:
/// attachment sources, confined write destinations, Mail's `save-attachments` directory, Notes
/// attachment saves. Deliberately outside it: paths read out of the Messages database (`ChatDB`,
/// an existence probe on store-owned values); `AttachmentFS.resolvedPath` expands raw but only
/// ever receives an already-guarded spelling or an allowed-root constant. Not yet under it,
/// pending a filed follow-up (docs/learnings/hot/hosted-ci.md, 2026-09-30): the `contacts`
/// `--file` reader (`ContactsOutput.readBoundedFile`), the Mail template root
/// (`APPLE_MAIL_MCP_HOME`) and the env-supplied rate-limiter state paths (`RateLimiter`).
/// `rawFinalLeafPath` applies the
/// policy too but, refused or not, never expands a foreign spelling: its job is to inspect
/// the spelling as written.
///
/// Assumption named: `NSUserName()` is the effective user, while `~` follows `HOME`. Under
/// `sudo` or an overridden `HOME` the two can name different directories; the own-name form is
/// collapsed to `~` on purpose so it can never mean anything `~` does not.
///
/// Foundation's treatment of a foreign `~user` spelling differs by macOS release: on macOS 27
/// `expandingTildeInPath` leaves an unknown user unchanged and `URL(fileURLWithPath:)` keeps the
/// tilde in a cwd-relative path; on macOS 15 `expandingTildeInPath` silently replaced an unknown
/// user with the PROCESS home while `URL(fileURLWithPath:)` kept the tilde; on macOS 26
/// `URL(fileURLWithPath:)` replaced it with the process home, for a known other account too. A
/// known user's home is never a destination or a source this tool means to name. So only the
/// operator's own home is accepted: `~`, `~/…`, and the current account's own `~name` /
/// `~name/…`, the last rewritten to the bare form so both expand through the same `HOME`.
/// Any other `~user` form is refused by the caller.
///
/// Works on UNICODE SCALARS, never Characters: `isAbsolutePath` and `expandingTildeInPath` both
/// see a leading U+007E even when a combining mark, ZWJ or variation selector follows it and
/// turns the pair into one grapheme cluster that `hasPrefix("~")` would not match.
public enum TildeSpelling {
    /// `nil` for a `~user` spelling that is not the current account; otherwise the spelling with
    /// the current account's own `~name` collapsed to `~`, and any non-tilde path unchanged.
    public static func ownHome(_ spelling: String, account: String = NSUserName()) -> String? {
        let scalars = spelling.unicodeScalars
        guard scalars.first == "~" else { return spelling }
        let rest = scalars.dropFirst()
        if rest.isEmpty || rest.first == "/" { return spelling }
        // The account component is everything up to the first `/`; it is compared WHOLE and
        // caselessly (account short names are case-insensitive on macOS, so `~Alice` and
        // `~alice` are the same account and Foundation expands both). Never slice by a
        // lowercased length: case mapping can change the scalar count (U+0130 → two scalars).
        let split = rest.firstIndex(of: "/") ?? rest.endIndex
        let component = String(String.UnicodeScalarView(rest[rest.startIndex..<split]))
        guard !account.isEmpty, component.lowercased() == account.lowercased() else { return nil }
        let tail = rest[split...]
        var own = String.UnicodeScalarView()
        own.append("~")
        own.append(contentsOf: tail)
        return String(own)
    }

    /// The noun phrase every refusal of a foreign `~user` spelling ends with, so the surfaces
    /// that refuse it read the same; the caller supplies the verb (`cannot attach …`).
    public static func refusalMessage(_ raw: String) -> String {
        "a path spelled as another user's home (`~user`); spell it as `~/…` or as an absolute path: \"\(raw)\""
    }
}
