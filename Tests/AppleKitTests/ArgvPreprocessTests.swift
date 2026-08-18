import Testing
@testable import AppleKit

/// CAL-11 / REM-10: the space-separated negative-value form (`--geo-lon -122.4`, `--alarm -15m`)
/// must reach ArgumentParser as the attached form it accepts, WITHOUT swallowing real options or
/// touching any other token.
@Suite("ArgvPreprocess (negative-value merge)")
struct ArgvPreprocessTests {

    @Test func mergesAllowlistedOptionWithNegativeNumber() {
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon", "-122.4"]) == ["--geo-lon=-122.4"])
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lat", "-33.8"]) == ["--geo-lat=-33.8"])
    }

    @Test func mergesAlarmNegativeOffset() {
        #expect(ArgvPreprocess.mergeNegativeValues(["--alarm", "-15m"]) == ["--alarm=-15m"])
        #expect(ArgvPreprocess.mergeNegativeValues(["--alarm", "-1d"]) == ["--alarm=-1d"])
    }

    @Test func mergesEachOccurrenceOfARepeatableOption() {
        #expect(ArgvPreprocess.mergeNegativeValues(["--alarm", "-15m", "--alarm", "-2h"])
                == ["--alarm=-15m", "--alarm=-2h"])
    }

    @Test func preservesSurroundingTokensAndOrder() {
        let got = ArgvPreprocess.mergeNegativeValues(
            ["reminders", "tasks", "create", "--title", "x", "--geo-lon", "-122.4", "--geo-lat", "37.7", "--dry-run"])
        #expect(got == ["reminders", "tasks", "create", "--title", "x", "--geo-lon=-122.4", "--geo-lat", "37.7", "--dry-run"])
        // A positive value is left space-separated (ArgumentParser accepts it as-is).
    }

    @Test func doesNotMergeANonAllowlistedOption() {
        // `--bogus -5` must stay two tokens so ArgumentParser reports the unknown option rather
        // than silently binding a value to it.
        #expect(ArgvPreprocess.mergeNegativeValues(["--bogus", "-5"]) == ["--bogus", "-5"])
    }

    @Test func doesNotSwallowAFollowingOption() {
        // The token after the allowlisted option is itself an option, not a negative value.
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon", "--dry-run"]) == ["--geo-lon", "--dry-run"])
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon", "-"]) == ["--geo-lon", "-"])
    }

    @Test func leavesAlreadyAttachedAndPositiveFormsUntouched() {
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon=-122.4"]) == ["--geo-lon=-122.4"])
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon", "122.4"]) == ["--geo-lon", "122.4"])
    }

    @Test func stopsAtTheOptionsTerminator() {
        // After a bare `--`, everything is positional and must pass through verbatim.
        #expect(ArgvPreprocess.mergeNegativeValues(["--", "--geo-lon", "-122.4"])
                == ["--", "--geo-lon", "-122.4"])
    }

    @Test func optionAsLastTokenPassesThrough() {
        // No following token to merge — must not index out of bounds; ArgumentParser then
        // reports the missing value itself.
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon"]) == ["--geo-lon"])
        #expect(ArgvPreprocess.mergeNegativeValues([]) == [])
    }

    @Test func doesNotMergeCalendarAfterOffsetPlusForm() {
        // Calendar's after-offset `+15m` starts with `+`, which ArgumentParser already accepts as
        // a value space-separated — it must NOT be merged (no regression on a working form).
        #expect(ArgvPreprocess.mergeNegativeValues(["--alarm", "+15m"]) == ["--alarm", "+15m"])
    }

    @Test func doesNotMergeAUnicodeDigitValue() {
        // `Character.isNumber` would accept `²` / Arabic-Indic digits; the ASCII-only guard means
        // a `-²5` token is left untouched (no coordinate/offset ever uses a non-ASCII digit).
        #expect(ArgvPreprocess.mergeNegativeValues(["--geo-lon", "-\u{00B2}5"]) == ["--geo-lon", "-\u{00B2}5"])
        #expect(!ArgvPreprocess.isNegativeValue("-\u{00B2}5"))       // superscript two
        #expect(!ArgvPreprocess.isNegativeValue("-\u{0664}"))        // Arabic-Indic four
    }

    @Test func isNegativeValueClassification() {
        for good in ["-122.4", "-15m", "-1d", "-.5", "-0"] {
            #expect(ArgvPreprocess.isNegativeValue(good), "\(good) should be a negative value")
        }
        for bad in ["--flag", "-", "-x", "5", "15m", "", "-abc"] {
            #expect(!ArgvPreprocess.isNegativeValue(bad), "\(bad) should NOT be a negative value")
        }
    }
}
