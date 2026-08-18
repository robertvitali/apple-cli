import Foundation

/// Argv preprocessing for the natural negative-value CLI form (CAL-11 / REM-10).
///
/// ArgumentParser refuses to consume a `-`-prefixed token as an option's VALUE in the
/// space-separated form: `--geo-lon -122.4` fails with "Missing value for '--geo-lon'" because
/// `-122.4` reads as an (unknown) option; only the attached form `--geo-lon=-122.4` parses.
/// The oracle these commands replace (`mcp-server-apple-events`) is an MCP server receiving
/// `geo_lon: -122.4` as a JSON NUMBER — it has no argv layer and no such restriction — so a
/// strict superset must accept the natural space-separated CLI form too. REM-10 is sharper
/// still: `--alarm -15m` is documented in the CLI's OWN `--help` yet fails to parse.
///
/// The fix rewrites exactly `--<name> <neg>` → `--<name>=<neg>` for an explicit allowlist of
/// options that legitimately take a negative value, and ONLY when the following token is
/// unambiguously a negative number / time-offset (`-` then a digit or a dot). No other option,
/// positional, or already-attached (`=`) form is touched, so the blast radius on the shared
/// entry point is minimal. Applied to a LOCAL copy of the args passed to `parseAsRoot`;
/// `CommandLine.arguments` itself is never mutated (so `toolForParseFailure`'s `argv[1]` read
/// is unaffected).
public enum ArgvPreprocess {

    /// Option long-names (WITHOUT the leading `--`) whose value may be negative:
    ///   * `geo-lat` / `geo-lon` — latitude/longitude (southern/western hemisphere is negative),
    ///     on Calendar `events create`/`update` and Reminders `tasks create`/`update`;
    ///   * `alarm` — the Reminders relative-offset form `-15m` / `-2h` / `-1d` (before), repeatable,
    ///     on the same commands. Calendar's `--alarm` documents only the unsigned `15m` before /
    ///     `+15m` after forms, so a Calendar `--alarm -15m` is not a supported form; if one is
    ///     given it still merges (the rewrite is purely syntactic) and the Calendar alarm parser
    ///     then rejects it downstream like any other unrecognized value.
    ///
    /// INVARIANT (reviewers, LOW): every name here must remain a value-taking `@Option`, never an
    /// `@Flag`, ANYWHERE in the fleet. The merge runs over the whole argv before subcommand
    /// resolution, so if a future domain registered `@Flag(name: .customLong("alarm"))`, then
    /// `--alarm -15m` would rewrite to the illegal `--alarm=-15m` and change that flag's parse.
    /// It is safe today because all three names exist ONLY as value-`@Option`s in Calendar and
    /// Reminders (grep-verified). Keep it that way when adding options fleet-wide.
    public static let negativeValueOptions: Set<String> = ["geo-lat", "geo-lon", "alarm"]

    /// Rewrite `--<allowlisted> <neg>` → `--<allowlisted>=<neg>` in `args`. Order-preserving;
    /// every non-matching token passes through verbatim. Stops rewriting at a bare `--`
    /// (ArgumentParser's end-of-options terminator — everything after it is positional).
    public static func mergeNegativeValues(_ args: [String],
                                           options: Set<String> = negativeValueOptions) -> [String] {
        var out: [String] = []
        out.reserveCapacity(args.count)
        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok == "--" {                       // options terminator: pass the rest through
                out.append(contentsOf: args[i...])
                break
            }
            if tok.hasPrefix("--"), !tok.contains("="),
               options.contains(String(tok.dropFirst(2))),
               i + 1 < args.count, isNegativeValue(args[i + 1]) {
                out.append("\(tok)=\(args[i + 1])")
                i += 2
                continue
            }
            out.append(tok)
            i += 1
        }
        return out
    }

    /// A token that is a negative number or negative time-offset: `-` followed by an ASCII digit
    /// or a dot. `-122.4`, `-15m`, `-1d`, `-.5` match; `--flag`, a bare `-`, and `-x` do not (so a
    /// real option can never be swallowed as a value). The digit test is ASCII-only on purpose
    /// (reviewers, LOW): `Character.isNumber` is Unicode-broad (it accepts `²`, Arabic-Indic `٤`,
    /// …) which every value here — coordinates and `NNu` offsets — never uses, and a merge on
    /// such a token would only produce a value the downstream parser rejects anyway.
    static func isNegativeValue(_ s: String) -> Bool {
        guard s.hasPrefix("-"), s.count >= 2 else { return false }
        let c = s[s.index(after: s.startIndex)]
        return c.isASCII && (c.isNumber || c == ".")
    }
}
