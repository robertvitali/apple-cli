import Foundation

/// The one tilde policy every surface that takes an OPERATOR-SUPPLIED path applies BEFORE
/// `expandingTildeInPath`: attachment sources, confined write destinations, Mail's
/// `save-attachments` directory, Notes attachment saves. Deliberately outside it: paths read
/// out of the Messages database (`ChatDB`, an existence probe on store-owned values) and the
/// env-supplied rate-limiter state paths (`RateLimiter`); `AttachmentFS.resolvedPath` expands
/// raw but only ever receives an already-guarded spelling or an allowed-root constant.
/// `rawFinalLeafPath` applies the
/// policy too but, refused or not, never expands a foreign spelling: its job is to inspect
/// the spelling as written.
///
/// Assumption named: `NSUserName()` is the effective user, while `~` follows `HOME`. Under
/// `sudo` or an overridden `HOME` the two can name different directories; the own-name form is
/// collapsed to `~` on purpose so it can never mean anything `~` does not.
///
/// Foundation's treatment of a `~user` spelling for an unknown user differs by macOS release
/// (returned unchanged on macOS 27, silently replaced by the PROCESS home on macOS 15), and a
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
