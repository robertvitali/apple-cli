import Foundation

/// Abstracts the subset of `AppleScriptRunner` that `NotesKit.NotesScript` calls, so tests can
/// inject a fake in place of the real `/usr/bin/osascript` process — in particular to pin the
/// retry-vs-no-retry policy (`NotesScript.run`) without a live Notes.app. See `AppleScriptRunner`
/// for the concrete implementation and the security rules governing `arguments`.
public protocol AppleScriptRunning {
    /// See `AppleScriptRunner.run(_:arguments:)`.
    func run(_ script: String, arguments: [String]) throws -> String
}
