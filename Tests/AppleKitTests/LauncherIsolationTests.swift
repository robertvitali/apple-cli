import Darwin
import Dispatch
import Foundation
import Testing
import TestSupport
@testable import AppleKit

/// All process-global descriptor changes happen only in an exact-filter reexec child. The
/// controller checks its private result and actual capture bytes; child reporter output is not
/// authoritative (closing 0/1/2 can disrupt Swift Testing's cached reporter).
@Suite("Launcher descriptor isolation", .serialized)
struct LauncherIsolationTests {
    private let scratch = ScratchDirs("launcher-isolation")
    private static let prefix = "APPLE_CLI_LAUNCHER_FIXTURE_"
    private static let keys = ["ROLE", "DIRECTORY", "NONCE", "PARENT", "ID"].map { prefix + $0 }
    private static let input = "synthetic stdin\nzero:\0 unicode:λ\n"
    private static let probeOut = Data("probe-stdout\n".utf8)
    private static let probeErr = Data("probe-stderr\n".utf8)

    // Nonparameterized by design: its exact runtime ID selects one child test, never all argument
    // cases or a reconstructed source-location-dependent ID.
    //
    // No deadline here is the subject; the subject is the descriptor evidence, and every wait is
    // bounded only so a starved runner cannot hang the run. The run is 58 sequential re-executions
    // of the whole test bundle, and a child's own expiry starts only once its body runs, so the
    // parent kills a child still running `childPatience` after spawn. Every child and probe launch
    // shares one budget (`budgetSeconds`, less when the test starts late, see `stageShare`), and
    // running out records one issue that says so.
    //
    // An attempt that left no usable evidence for a reason starvation explains is a miss: a child
    // ended by its own expiry or killed here, a launch deadline, an overlap wait, a probe ended by
    // its own alarm (except in the no-EOF shape below), or its stdin failing with EPIPE once that
    // alarm could have fired. A miss is printed and re-run, at most twice per scenario and
    // `rerunLimit` times per test, and the attempt that cannot be re-run records it.
    //
    // Time explains a launch deadline only for a form that has one and only once it had passed
    // since the launch began, and a probe's SIGALRM or late EPIPE only once its alarm could have
    // fired. Neither counts when the probe's status, as the launcher observed it, or anything the
    // probe left on its stdout or stderr contradicts that stream's healthy bytes (see
    // `launchProbe`). Every attempt checks the evidence it did leave, restoration and captures
    // included on a cut attempt (`healed`), and a failed product check (an inherited descriptor,
    // wrong bytes or status, identity, restoration or captures) is recorded at once and never
    // re-run.
    //
    // A probe that echoed all its input and was then cut short by its alarm before EOF is the
    // shape an inherited stdin write end leaves, so on every attempt it is a failed product check,
    // never a miss, and its issue names that write end as the likely cause (see `starvedEvidence`).
    // Residual: the runner withholding the probe, or the launcher between its last stdin write and
    // closing that pipe, so long that the probe's alarm (eight seconds after its `main` arms it)
    // fires after its last echo and before its stderr write (its EOF read lies between) leaves the
    // same shape, and a correct launcher then fails.
    @Test func isolatedDescriptors() throws {
        let environment = ProcessInfo.processInfo.environment
        if Self.keys.contains(where: { environment[$0] != nil }) {
            Self.armExpiry()
            guard let current = Test.current?.id.description else { Darwin._exit(86) }
            do { try runChild(current: current, environment: environment) }
            catch { Darwin._exit(86) } // Malformed/stale role is terminal; never recurse.
            return
        }
        let current = try #require(Test.current?.id.description)
        let host = try HostContext.current()
        let root = try scratch.directory().resolvingSymlinksInPath()
        guard chmod(root.path, 0o700) == 0 else { throw FixtureFailure("private root") }
        let budget = try Budget()
        defer { if let summary = budget.summary { Issue.record(Comment(rawValue: summary)) } }
        let healthy = { (scenario: String) throws -> Verdict in
            let configuration = try prepare(root: root, testID: current, scenario: scenario)
            let receipt = try invoke(host: host, configuration: configuration, budget: budget)
            return verdict(receipt, configuration)
        }

        // Handshake establishes this exact helper/bundle/library/filter route before any
        // descriptor-closing scenario. A zero-exit empty selection cannot satisfy its receipt.
        guard try run("handshake", budget, { _ in try healthy("handshake") }) else { return }

        for mode in ["inline", "timed", "stdin", "timedStdin", "spawnFailure"] {
            for mask in 0...7 {
                let scenario = "\(mode)-\(mask)"
                try run(scenario, budget) { _ in try healthy(scenario) }
            }
        }
        for scenario in ["sentinel", "overlap", "status7"] {
            try run(scenario, budget) { _ in try healthy(scenario) }
        }
        try positiveInheritanceControls(host: host, root: root, budget: budget)

        // These children still exit zero. Each differs from a healthy receipt in one field;
        // acceptance must reject the specific missing or corrupted evidence.
        for (scenario, expected) in [
            ("negative-missing", Rejection.missingResult), ("negative-nonce", .identity),
            ("negative-id", .identity), ("negative-bytes", .outcome),
            ("negative-restoration", .restoration), ("negative-malformed", .malformedResult),
        ] {
            try run(scenario, budget) { _ in
                let configuration = try prepare(root: root, testID: current, scenario: scenario)
                let receipt = try invoke(host: host, configuration: configuration, budget: budget)
                return negativeVerdict(receipt, configuration, expected: expected)
            }
        }
        for fault in ["role", "missing-role", "nonce", "parent", "id", "config", "permissions", "claimed"] {
            try run("role fault \(fault)", budget) { _ in
                let configuration = try prepare(root: root, testID: current, scenario: "handshake")
                let receipt = try invoke(host: host, configuration: configuration, budget: budget,
                                         roleFault: fault)
                return roleVerdict(receipt, configuration)
            }
        }
        #expect(throws: FixtureFailure.self) {
            _ = try HostContext.resolve(host: host.executable, arguments: [], activeBundle: host.bundle, activePayload: host.payload)
        }
        #expect(throws: FixtureFailure.self) {
            _ = try HostContext.resolve(host: host.executable,
                                        arguments: ["--test-bundle-path", root.path], activeBundle: host.bundle, activePayload: host.payload)
        }
        #expect(throws: FixtureFailure.self) {
            _ = try HostContext.resolve(host: root.appendingPathComponent("missing-helper"),
                                        arguments: ["--test-bundle-path", host.bundle.path], activeBundle: host.bundle, activePayload: host.payload)
        }
    }

    @Test func unrelatedTestIsNeverSelectedByTheFixtureFilter() throws {
        if Self.keys.contains(where: { ProcessInfo.processInfo.environment[$0] != nil }) {
            throw FixtureFailure("fixture filter selected an unrelated test")
        }
    }

    // Each bound only stops a wait that would otherwise never return, so each is sized for a
    // starved runner and sits about twice above the end it waits for: a hung child body ends at its
    // own `childExpiry`, under half of `childPatience`; that expiry is about twice the overlap
    // scenario's longest path; and a probe ends itself at eight seconds, well under
    // `probePatience`. `budgetSeconds` is twelve times the slowest of seven starved runs that
    // passed in 45 to 75 s and 1.35 times the slowest that finished every scenario (666 s); a
    // slower run stops at the budget with an issue that says why.
    //
    // What binds is the 1200 s timeout `scripts/ci/quality.py` gives each `swift test` stage
    // (`hosted-test`, `swiftly-test`). Its clock starts before `swift test` builds the test
    // targets, so before this process starts (81 s of a 147 s stage on an unloaded `macos-26`
    // runner), and a test may also wait for a free worker before it starts. So the budget is capped
    // at what `stageShare` leaves: 1200 s less 180 s for the build (over twice the hosted one) and
    // 60 s for the end of the run (the last launch's kill and reap, at most 30 s, then the other
    // tests' tail and the xUnit report) is 960 s from this process's start. A test starting within
    // 60 s of it keeps all 900 s (180 + 60 + 900 + 60 = 1200); a later one gets 960 s less its
    // start, none past 960 s, and the issue says so either way.
    //
    // Residuals: a slower build (615 s on a local host shared with other builds) eats that margin
    // unseen, and the stage can then end a starved run before this test explains itself. Nor is the
    // tail sized for the other suites: their re-run chains can take minutes, and one still running
    // when this test ends can take the stage past its timeout with no issue here.
    private static let childExpiry: UInt32 = 120
    private static let childPatience = 300.0
    private static let probePatience = 60.0
    private static let budgetSeconds = 900.0
    private static let stageShare = 960.0
    // At most two re-runs per scenario, as the re-run rule in docs/learnings/hot/hosted-ci.md words
    // it ("re-runs an attempt that still misses the scenario at most twice"). That rule's other
    // tests carry one scenario each; this one carries 60 (58 children and two positive controls),
    // since each child is selected by this test's exact runtime ID. As 60 tests they could re-run
    // 120 times between them; `rerunLimit` caps the whole run at 6, so no scenario gets more
    // chances than the rule gives it and the run as a whole gets fewer. A miss is never a failed
    // product check (see `run`), and the no-EOF shape an inherited stdin write end leaves is a
    // failed check on every attempt, never a miss (see `starvedEvidence`).
    private static let rerunLimit = 6
    private static let syntheticRestoration = "synthetic restoration failure"

    private final class BundleMarker: NSObject {}
    private struct FixtureFailure: Error {
        let reason: String
        /// True only for a wait this file chose that ran out; never for wrong evidence.
        let timing: Bool
        init(_ reason: String, timing: Bool = false) { self.reason = reason; self.timing = timing }
    }

    private struct HostContext {
        let executable: URL
        let bundle: URL
        let payload: URL
        let observer: URL
        static func current() throws -> Self {
            guard let executable = Bundle.main.executableURL else { throw FixtureFailure("missing helper") }
            let active = Bundle(for: BundleMarker.self)
            guard let payload = active.executableURL else { throw FixtureFailure("missing active test payload") }
            return try resolve(host: executable, arguments: CommandLine.arguments,
                               activeBundle: active.bundleURL, activePayload: payload)
        }
        static func resolve(host: URL, arguments: [String], activeBundle: URL, activePayload: URL) throws -> Self {
            let indices = arguments.indices.filter { arguments[$0] == "--test-bundle-path" }
            guard host.lastPathComponent == "swiftpm-testing-helper", host.path.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: host.path), indices.count == 1,
                  let index = indices.first, index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/") else { throw FixtureFailure("unsupported test host") }
            // The helper accepts the inner Mach-O payload, while Foundation identifies its
            // enclosing .xctest bundle. Validate both identities and preserve the exact payload.
            let payload = URL(fileURLWithPath: arguments[index + 1])
            let bundle = activeBundle.resolvingSymlinksInPath()
            let expectedPayload = bundle.appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(bundle.deletingPathExtension().lastPathComponent)
            guard bundle.pathExtension == "xctest",
                  payload.resolvingSymlinksInPath() == activePayload.resolvingSymlinksInPath(),
                  payload.resolvingSymlinksInPath() == expectedPayload else {
                throw FixtureFailure("test bundle identity mismatch")
            }
            var payloadInfo = stat()
            guard lstat(payload.path, &payloadInfo) == 0, (payloadInfo.st_mode & S_IFMT) == S_IFREG else {
                throw FixtureFailure("invalid test payload")
            }
            let observer = bundle.deletingLastPathComponent().appendingPathComponent("LauncherFDProbe")
            var info = stat()
            guard lstat(observer.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  FileManager.default.isExecutableFile(atPath: observer.path) else {
                throw FixtureFailure("missing adjacent C observer")
            }
            return Self(executable: host.resolvingSymlinksInPath(), bundle: bundle, payload: payload, observer: observer)
        }
        func arguments(testID: String) -> [String] {
            ["--test-bundle-path", payload.path, "--testing-library", "swift-testing", "--no-parallel",
             "--filter", "^" + NSRegularExpression.escapedPattern(for: testID) + "$"]
        }
    }

    private struct Configuration: Codable, Sendable {
        let schema: Int
        let nonce: String
        let testID: String
        let parent: Int32
        let scenario: String
        let directory: URL
    }
    private struct Identity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let rdev: UInt64
        init(_ info: stat) {
            device = UInt64(UInt32(bitPattern: info.st_dev)); inode = UInt64(info.st_ino)
            mode = UInt32(info.st_mode); rdev = UInt64(UInt32(bitPattern: info.st_rdev))
        }
        var arguments: [String] { [String(device), String(inode), String(mode), String(rdev)] }
        static func read(_ fd: Int32) throws -> Self {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw FixtureFailure("fstat errno \(errno)") }
            return Self(info)
        }
    }
    private struct DescriptorFact: Codable, Equatable {
        let descriptor: Int32
        let identity: Identity
        let flags: Int32
        static func read(_ fd: Int32) throws -> Self {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { throw FixtureFailure("get descriptor flags errno \(errno)") }
            return Self(descriptor: fd, identity: try Identity.read(fd), flags: flags)
        }
    }
    private struct FailureRecord: Codable {
        let type: String
        let domain: String
        let code: Int
        let description: String
        let details: [String: String]
        let launcherKind: String?
        /// A launch deadline or one of this file's own waits ran out. A launch deadline counts only
        /// through `Starved`, once it had passed (see `launchProbe`); a bare `TimeoutError` is a
        /// product failure, as for `spawnFailure-*`.
        let timing: Bool
        init(_ error: any Error, timing explicit: Bool? = nil) {
            let ns = error as NSError
            type = String(reflecting: Swift.type(of: error)); domain = ns.domain; code = ns.code
            description = String(describing: error)
            details = ns.userInfo.mapValues { String(describing: $0) }
            timing = explicit ?? ((error as? FixtureFailure)?.timing == true)
            if let runnerError = error as? AppleScriptRunner.RunError, case .launchFailed = runnerError {
                launcherKind = "launchFailed"
            } else { launcherKind = nil }
        }
    }
    private struct OutcomeRecord: Codable, Equatable, Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        init(_ outcome: ScriptOutcome) {
            status = outcome.terminationStatus; stdout = outcome.standardOutput; stderr = outcome.standardError
        }
    }
    private struct Report: Codable {
        var schema = 1
        var nonce: String
        var testID: String
        var scenario: String
        var outcomes: [OutcomeRecord] = []
        var failure: FailureRecord?
        var original: [DescriptorFact] = []
        var restored: [DescriptorFact] = []
        var restorationErrors: [String] = []
        var writes: [Int] = []
    }
    /// How a launch ended. `expired` means this process killed it, still running at its bound;
    /// `exited` and `signaled` carry what `launch` decoded from `waitpid`'s status. `unreaped`
    /// means this process killed it that way and 30 s later had still not reaped it.
    private enum End: Equatable, CustomStringConvertible {
        case exited(Int32), signaled(Int32), expired(Int), unreaped(Int)
        var description: String {
            switch self {
            case .exited(let status): "exited \(status)"
            case .signaled(let number): "ended by signal \(number)"
            case .expired(let seconds): "killed here, still running \(seconds) s after spawn"
            case .unreaped(let seconds):
                "killed here \(seconds) s after spawn and still unreaped 30 s later"
            }
        }
    }
    private struct Receipt {
        var end: End
        let seconds: Double
        var result: Data?
        let stdout: Data
        let stderr: Data
        let identities: [Identity]
        var exitedNormally: Bool {
            switch end { case .exited: true; case .signaled, .expired, .unreaped: false }
        }
        var status: Int32 {
            switch end {
            case .exited(let value), .signaled(let value): value
            case .expired, .unreaped: SIGKILL
            }
        }
    }
    private enum Rejection: Equatable { case process, missingResult, malformedResult, identity, outcome, restoration, captures }
    private enum Verdict { case passed, failed(String), missed(String) }

    /// Shared by every child and probe launch of one parent run. It grants `budgetSeconds`, or what
    /// `stageShare` leaves this process if that is less. Running out names a product change that
    /// slows launches beside a slow runner, as `meaning(of:)` does, since misses that each run a
    /// probe to its alarm can spend the budget.
    private final class Budget {
        let started = DispatchTime.now()
        let processAge: Double
        let seconds: Double
        var launches = 0
        var launchSeconds = 0.0
        var reruns = 0
        var misses: [String] = []
        var stoppedAt: String?
        init() throws {
            processAge = try Self.age()
            seconds = max(0, min(LauncherIsolationTests.budgetSeconds,
                                 LauncherIsolationTests.stageShare - processAge))
        }
        var limit: DispatchTime { started + seconds }
        var isExhausted: Bool { DispatchTime.now() >= limit }
        func record(_ seconds: Double) { launches += 1; launchSeconds += seconds }
        var summary: String? {
            guard let stoppedAt else { return nil }
            let mean = String(format: "%.1f", launchSeconds / Double(max(launches, 1)))
            let missed = misses.isEmpty ? "none" : misses.joined(separator: "; ")
            let cut = seconds < LauncherIsolationTests.budgetSeconds
                ? " (not \(Int(LauncherIsolationTests.budgetSeconds)) s: this test started "
                    + "\(Int(processAge)) s after its process, which has "
                    + "\(Int(LauncherIsolationTests.stageShare)) s of the stage timeout)"
                : ""
            return "isolation scenarios stopped at \(stoppedAt): their \(Int(seconds)) s budget"
                + "\(cut) ran out after \(launches) launches (\(reruns) re-runs), \(mean) s each. "
                + "Scenarios not reached have no descriptor evidence; the runner was too slow, the "
                + "test started too late, a launcher wait never returned, or a product change made "
                + "launches slow (an inherited stdin write end runs a probe to its alarm); misses: "
                + missed
        }
        /// Seconds since this process started, by the kernel's record of its start time.
        static func age() throws -> Double {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else {
                throw FixtureFailure("process start time errno \(errno)")
            }
            var now = timeval()
            guard gettimeofday(&now, nil) == 0 else { throw FixtureFailure("time errno \(errno)") }
            let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
            return Double(now.tv_sec) + Double(now.tv_usec) / 1e6 - start
        }
    }

    /// One scenario, up to three attempts. A miss is printed and re-run while this scenario has
    /// attempts and the test has re-runs left; the attempt that cannot be re-run records it. A
    /// failed check is recorded at once. A spent budget stops the scenario before its next attempt,
    /// and the first scenario it stops is named in the budget summary. Returns whether an attempt
    /// passed.
    @discardableResult
    private func run(_ label: String, _ budget: Budget,
                     _ attempt: (Int) throws -> Verdict) rethrows -> Bool {
        var reasons: [String] = []
        for number in 1...3 {
            guard !budget.isExhausted else {
                if budget.stoppedAt == nil { budget.stoppedAt = label }
                return false
            }
            switch try attempt(number) {
            case .passed: return true
            case .failed(let message):
                Issue.record("\(label): \(message)")
                return false
            case .missed(let reason):
                reasons.append(reason)
                budget.misses.append("\(label) attempt \(number): \(reason)")
                if budget.isExhausted {
                    if budget.stoppedAt == nil { budget.stoppedAt = label }
                    return false
                }
                if number < 3 && budget.reruns < Self.rerunLimit {
                    budget.reruns += 1
                    print("isolation scenario \(label) missed on attempt \(number) of 3, "
                        + "re-running: \(reason)")
                    continue
                }
                let why = number == 3 ? "no attempt left" : "all \(Self.rerunLimit) re-runs used"
                let message = "\(label) missed on attempt \(number) of 3 and was not re-run "
                    + "(\(why)): \(reason). " + Self.meaning(of: reasons)
                Issue.record(Comment(rawValue: message))
                return false
            }
        }
        // Every attempt above ends in a verdict, a recorded miss or a spent budget; reaching here
        // means the last one did not, which must never pass silently.
        Issue.record("\(label): the last attempt returned without a verdict")
        return false
    }

    /// What a recorded miss can mean. A miss is evidence cut short in a way time explains, not
    /// proof of a sound launcher: a launcher wait that never returns, or a product change that
    /// leaves a miss's shape, repeats the way a slow runner does, so neither branch claims a miss
    /// leaves no descriptor evidence. When every attempt missed in exactly the same way, the text
    /// says so and names those causes beside a slow runner; a reason carries no timing, so the same
    /// words alone cannot tell them apart. The other branch (one miss once the re-runs are spent,
    /// or mixed reasons) names them too. The no-EOF shape an inherited stdin write end leaves is
    /// never a miss (see `starvedEvidence`), so neither branch names it.
    private static func meaning(of reasons: [String]) -> String {
        if reasons.count > 1 && Set(reasons).count == 1 {
            return "A miss is evidence cut short in a way time explains. All \(reasons.count) "
                + "attempts missed in exactly this way, which a launcher wait that never returns "
                + "or a product change that leaves this shape would also do; it need not be the "
                + "runner."
        }
        return "A miss is evidence cut short in a way time explains; repeated, it means the "
            + "runner withheld that much time, a launcher wait never returned, or a product "
            + "change leaves this shape."
    }

    private func verdict(_ receipt: Receipt, _ configuration: Configuration) -> Verdict {
        guard let rejected = rejection(of: receipt, expected: configuration) else { return .passed }
        if let reason = missReason(receipt, configuration) { return .missed(reason) }
        // A check after the outcome that fails too is named, not hidden by the first.
        let later = healed(receipt, configuration)
            .flatMap { rejection(of: $0, expected: configuration) }
        let also = later.map { $0 == rejected ? "" : ", and as \($0) with healthy outcomes" } ?? ""
        return .failed("isolated scenario \(configuration.scenario) must return exact evidence; "
            + "rejected as \(rejected)\(also) (\(summary(receipt)))"
            + withheldEOF(receipt, configuration))
    }

    /// How many of the report's outcomes have the no-EOF shape (`unended`), which
    /// `starvedEvidence` never classes as a miss.
    private func unendedCount(_ report: Report, _ scenario: String) -> Int {
        zip(report.outcomes, expectedOutcomes(scenario)).filter { outcome, expected in
            Self.unended(outcome, of: expected)
        }.count
    }

    /// The failure text's explanation when an outcome has the no-EOF shape (`unendedCount`), or
    /// empty when none has. It names the likely cause first and the timing that can also leave it.
    private func withheldEOF(_ receipt: Receipt, _ configuration: Configuration) -> String {
        guard let bytes = receipt.result,
              let report = try? JSONDecoder().decode(Report.self, from: bytes) else { return "" }
        let count = unendedCount(report, configuration.scenario)
        guard count > 0 else { return "" }
        return ". \(count) probe outcome(s) echoed all their input and then ran to the probe's "
            + "own alarm without EOF: the likely cause is an inherited stdin write end withholding "
            + "EOF; the alternative is the runner withholding the probe, or the launcher before it "
            + "closed the stdin pipe, until the probe's \(Int(Self.probeAlarm)) s alarm fired "
            + "after its last echo and before its stderr write"
    }

    /// A malformed role exits 86 before it enters; a child that starvation ended first did not get
    /// that far, which `entered` and the absent result confirm.
    private func roleVerdict(_ receipt: Receipt, _ configuration: Configuration) -> Verdict {
        let entered = FileManager.default.fileExists(
            atPath: configuration.directory.appendingPathComponent("entered").path)
        if receipt.end == .exited(86) && receipt.result == nil && !entered { return .passed }
        if let reason = processMiss(receipt.end, seconds: receipt.seconds), receipt.result == nil,
           !entered {
            return .missed(reason)
        }
        return .failed("a malformed role must exit 86 before entering; child \(receipt.end), "
            + "result \(receipt.result == nil ? "absent" : "present"), entered \(entered)")
    }

    /// Each negative must be rejected for its injected fault alone: with that fault undone (see
    /// `control`), the same evidence must be accepted. Without that, a probe cut short by
    /// starvation would fail `negative-restoration` as `.outcome`, and a timed-out launch could let
    /// `negative-bytes` pass for the wrong reason.
    ///
    /// A child that starvation may have ended is judged on what it left, with its injected fault
    /// undone, as `verdict` judges a healthy scenario: a miss only when that is absent, partial,
    /// healthy or itself only cut short; any other rejection fails at once.
    private func negativeVerdict(_ receipt: Receipt, _ configuration: Configuration,
                                 expected: Rejection) -> Verdict {
        if processMiss(receipt.end, seconds: receipt.seconds) != nil {
            let undone = control(of: receipt, configuration) ?? receipt
            if let reason = missReason(undone, configuration) { return .missed(reason) }
            var evidence = undone
            evidence.end = .exited(0)
            let other = rejection(of: evidence, expected: configuration).map { "\($0)" }
            return .failed("a negative control that ended early left evidence that, without its "
                + "injected fault, is rejected as \(other ?? "nothing") (\(summary(undone)))")
        }
        guard receipt.end == .exited(0) else {
            return .failed("a negative control must still exit zero (\(summary(receipt)))")
        }
        if let control = control(of: receipt, configuration),
           let other = rejection(of: control, expected: configuration) {
            if let reason = missReason(control, configuration) { return .missed(reason) }
            return .failed("without its injected fault the evidence is still rejected as \(other) "
                + "(\(summary(control)))")
        }
        let rejected = rejection(of: receipt, expected: configuration)
        guard rejected == expected else {
            return .failed("rejected as \(rejected.map { "\($0)" } ?? "nothing") instead of "
                + "\(expected) (\(summary(receipt)))")
        }
        return .passed
    }

    /// The negative's receipt with its injected fault undone, or nil when it has nothing to undo (a
    /// missing or malformed result, which no starvation can produce from a child that exited).
    private func control(of receipt: Receipt, _ configuration: Configuration) -> Receipt? {
        guard let bytes = receipt.result,
              var report = try? JSONDecoder().decode(Report.self, from: bytes) else { return nil }
        switch configuration.scenario {
        case "negative-nonce": report.nonce = configuration.nonce
        case "negative-id": report.testID = configuration.testID
        case "negative-bytes":
            if !report.outcomes.isEmpty {
                report.outcomes[0].stdout = expectedOutcomes(configuration.scenario)[0].stdout
            }
        case "negative-restoration":
            report.restorationErrors.removeAll { $0 == Self.syntheticRestoration }
        default: return nil
        }
        var control = receipt
        control.result = try? JSONEncoder().encode(report)
        return control
    }

    /// A child killed here (`expired`, `unreaped`) is a starvation shape. A SIGALRM counts as the
    /// child's own expiry only once the child has run that long: it arms `alarm(childExpiry)` after
    /// spawn, so an earlier SIGALRM is not a starvation shape and is judged as a failure. The span
    /// is uptime, which a host's sleep pauses while the alarm may count on, so a run that spans a
    /// sleep can fail this way.
    private func processMiss(_ end: End, seconds: Double) -> String? {
        switch end {
        case .expired, .unreaped: "the child was \(end)"
        case .signaled(SIGALRM) where seconds >= Double(Self.childExpiry):
            "the child was ended by its own \(Self.childExpiry) s expiry"
        case .exited, .signaled: nil
        }
    }

    /// Why an attempt left no usable evidence for a reason starvation explains, or nil when what it
    /// did leave fails a check. A child that starvation ended is a miss only if its result is
    /// absent, partial, healthy, or itself only cut short, with restoration and captures holding
    /// (see `starvedEvidence`).
    private func missReason(_ receipt: Receipt, _ configuration: Configuration) -> String? {
        if let ended = processMiss(receipt.end, seconds: receipt.seconds) {
            var evidence = receipt
            evidence.end = .exited(0)
            switch rejection(of: evidence, expected: configuration) {
            case nil, .missingResult?, .malformedResult?: return ended
            case .outcome?:
                return starvedEvidence(evidence, configuration).map { "\(ended); \($0)" }
            default: return nil
            }
        }
        guard receipt.end == .exited(0),
              rejection(of: receipt, expected: configuration) == .outcome else { return nil }
        return starvedEvidence(receipt, configuration)
    }

    /// Why a result's outcomes are incomplete in a way time explains, or nil when they are wrong. A
    /// launch deadline or one of this file's waits reports itself as timing. A probe outcome is cut
    /// short by the probe's own eight-second alarm when `cutShort` holds. With no failure reported,
    /// the result must carry one outcome for each healthy one: a child that returns fewer without
    /// recording a failure has a fixture or product defect, which time never explains.
    ///
    /// An inherited descriptor the sentinel or scan probe sees shows in its first line
    /// (`sentinel=1`, `foreign=1`), never as a prefix of the healthy bytes, so it cannot pass as a
    /// cut. An inherited stdin write end shows as a probe that echoed all its input and was cut
    /// short before EOF (`unendedCount`), so any such cut is never a miss: the attempt fails, on
    /// every attempt, and `verdict` names that write end as the likely cause. The alternative it
    /// names then fails a correct launcher: the runner withholding the probe, or the launcher
    /// between its last stdin write and closing that pipe, so long that the probe's alarm (eight
    /// seconds after its `main` arms it) fires after its last echo and before its stderr write
    /// (`LauncherFDProbe/main.c`). `spawnFailure-*` has nothing time can cut, since its deadline
    /// never starts. The checks `rejection` makes after the outcome (restoration, captures) must
    /// hold on what the attempt left (`healed`), so a re-run cannot pass over their failure.
    private func starvedEvidence(_ receipt: Receipt, _ configuration: Configuration) -> String? {
        let scenario = configuration.scenario
        guard !scenario.hasPrefix("spawnFailure-"), let bytes = receipt.result,
              let report = try? JSONDecoder().decode(Report.self, from: bytes) else { return nil }
        let healthy = expectedOutcomes(scenario)
        guard report.outcomes.count <= healthy.count,
              unendedCount(report, scenario) == 0 else { return nil }
        var cut = 0
        for (outcome, expected) in zip(report.outcomes, healthy) where outcome != expected {
            guard Self.cutShort(outcome, of: expected) else { return nil }
            cut += 1
        }
        let reason: String
        if let failure = report.failure {
            guard failure.timing else { return nil }
            reason = "the child reported \(failure.description)"
        } else {
            guard report.outcomes.count == healthy.count, cut > 0 else { return nil }
            reason = "\(cut) of \(healthy.count) probe outcomes cut short by the probe's own alarm"
        }
        guard let whole = healed(receipt, configuration),
              rejection(of: whole, expected: configuration) == nil else { return nil }
        return reason
    }

    /// Whether `outcome` is `expected` cut short by the probe's own alarm: status SIGALRM and both
    /// streams prefixes of the healthy ones, so nothing it wrote contradicts them.
    private static func cutShort(_ outcome: OutcomeRecord, of expected: OutcomeRecord) -> Bool {
        outcome.status == SIGALRM && expected.stdout.starts(with: outcome.stdout)
            && expected.stderr.starts(with: outcome.stderr)
    }

    /// Whether `outcome` is `expected` cut short by the probe's own alarm after it echoed all its
    /// input: every healthy stdout byte, input included, and no stderr, which the probe writes only
    /// after its EOF read. That is the shape an inherited stdin write end leaves, so it is a
    /// product failure on every attempt, never a miss.
    private static func unended(_ outcome: OutcomeRecord, of expected: OutcomeRecord) -> Bool {
        let input = Data(Self.input.utf8)
        return outcome != expected && cutShort(outcome, of: expected)
            && outcome.stdout == expected.stdout && outcome.stderr.isEmpty
            && expected.stdout.suffix(input.count) == input
    }

    /// The receipt with its outcomes taken as healthy, no failure and a clean exit, so the checks
    /// `rejection` makes after the outcome (restoration, captures) judge what the attempt left. Nil
    /// for `spawnFailure-*`, whose healthy evidence is a failure, and for a result that does not
    /// decode.
    private func healed(_ receipt: Receipt, _ configuration: Configuration) -> Receipt? {
        guard !configuration.scenario.hasPrefix("spawnFailure-"), let bytes = receipt.result,
              var report = try? JSONDecoder().decode(Report.self, from: bytes) else { return nil }
        report.outcomes = expectedOutcomes(configuration.scenario)
        report.failure = nil
        var whole = receipt
        whole.end = .exited(0)
        whole.result = try? JSONEncoder().encode(report)
        return whole
    }

    private func summary(_ receipt: Receipt) -> String {
        var parts = ["child \(receipt.end) after \(String(format: "%.1f", receipt.seconds)) s"]
        if let bytes = receipt.result,
           let report = try? JSONDecoder().decode(Report.self, from: bytes) {
            parts.append("outcome statuses \(report.outcomes.map(\.status))")
            // The probes' first lines are fixed tokens (`foreign=1`, `probe-stdout`, ...).
            let first = report.outcomes.map {
                String(decoding: $0.stdout.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
            }
            parts.append("first stdout lines \(first)")
            if let failure = report.failure { parts.append("failure \(failure.description)") }
            if !report.restorationErrors.isEmpty {
                parts.append("restoration \(report.restorationErrors)")
            }
        } else {
            parts.append(receipt.result == nil ? "no result" : "undecodable result")
        }
        return parts.joined(separator: "; ")
    }

    private func prepare(root: URL, testID: String, scenario: String) throws -> Configuration {
        let nonce = UUID().uuidString
        let directory = root.appendingPathComponent(nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let configuration = Configuration(schema: 1, nonce: nonce, testID: testID,
                                          parent: getpid(), scenario: scenario, directory: directory)
        try Self.writePrivate(try JSONEncoder().encode(configuration), to: directory.appendingPathComponent("config"))
        return configuration
    }

    private func invoke(host: HostContext, configuration: Configuration, budget: Budget,
                        roleFault: String? = nil) throws -> Receipt {
        let directory = configuration.directory
        var environment = ProcessInfo.processInfo.environment
        environment[Self.prefix + "ROLE"] = "child-v1"
        environment[Self.prefix + "DIRECTORY"] = directory.path
        environment[Self.prefix + "NONCE"] = configuration.nonce
        environment[Self.prefix + "PARENT"] = String(configuration.parent)
        environment[Self.prefix + "ID"] = configuration.testID
        switch roleFault {
        case "role": environment[Self.prefix + "ROLE"] = "invalid"
        case "missing-role": environment.removeValue(forKey: Self.prefix + "ROLE")
        case "nonce": environment[Self.prefix + "NONCE"] = "malformed"
        case "parent": environment[Self.prefix + "PARENT"] = String(configuration.parent + 1)
        case "id": environment[Self.prefix + "ID"] = "unrelated.synthetic.test"
        case "config":
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config"))
        case "permissions":
            guard chmod(directory.appendingPathComponent("config").path, 0o644) == 0 else { throw FixtureFailure("chmod") }
        case "claimed":
            try Self.writePrivate(Data(configuration.nonce.utf8), to: directory.appendingPathComponent("claimed"))
        default: break
        }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        let out = try Self.newFile(stdoutURL), err = try Self.newFile(stderrURL)
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? out.close(); try? err.close(); try? input.close() }
        let identities = try [Identity.read(input.fileDescriptor), Identity.read(out.fileDescriptor), Identity.read(err.fileDescriptor)]
        // Each selected fixture arms SIGALRM once its body starts, but its start-up before that has
        // no bound of its own, so `launch` kills a child still running `childPatience` after spawn,
        // or when the run's budget is spent, and only one it has not reaped, so no stale PID is
        // ever signalled.
        let launched = try Self.launch(
            host.executable, host.arguments(testID: configuration.testID), environment: environment,
            stdio: [input.fileDescriptor, out.fileDescriptor, err.fileDescriptor],
            patience: Self.childPatience, limit: budget.limit)
        budget.record(launched.seconds)
        return Receipt(end: launched.end, seconds: launched.seconds,
                       result: try? Data(contentsOf: directory.appendingPathComponent("result")),
                       stdout: try Data(contentsOf: stdoutURL),
                       stderr: try Data(contentsOf: stderrURL), identities: identities)
    }

    /// Starts `executable` with `stdio` as its descriptors 0, 1 and 2 and nothing else inherited,
    /// in a new process group with every signal at its default and none blocked, as Foundation's
    /// `Process` does, and polls for its exit, since `waitUntilExit()` has no bound. A child still
    /// running at `limit`, or `patience` seconds after spawn if that is sooner, is sent SIGKILL; it
    /// has not been reaped, so its PID cannot have been reused. One still unreaped 30 s after that
    /// is returned as `unreaped`, a miss, since a stalled host can outlast the kernel's teardown;
    /// thrown instead, it would be one error that stops every later scenario, with no miss line for
    /// it and no budget summary. It is never signalled again and stays this process's zombie until
    /// it exits.
    private static func launch(_ executable: URL, _ arguments: [String],
                               environment: [String: String], stdio: [Int32], patience: Double,
                               limit: DispatchTime) throws -> (end: End, seconds: Double) {
        guard stdio.count == 3, stdio.allSatisfy({ $0 > 2 }) else { throw FixtureFailure("stdio") }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        func check(_ code: Int32, _ step: String) throws {
            guard code == 0 else { throw FixtureFailure("\(step) error \(code)") }
        }
        try check(posix_spawnattr_init(&attributes), "attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions), "file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "signal mask")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal defaults")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "process group")
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "flags")
        for (source, target) in zip(stdio, [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]) {
            try check(posix_spawn_file_actions_adddup2(&actions, source, target), "dup2")
        }
        var argv = ([executable.path] + arguments).map { strdup($0) }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard !argv.contains(nil), !envp.contains(nil) else { throw FixtureFailure("strdup") }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let path = executable.path
        let code = argv.withUnsafeMutableBufferPointer { argument in
            envp.withUnsafeMutableBufferPointer { variables in
                posix_spawn(&pid, path, &actions, &attributes, argument.baseAddress!,
                            variables.baseAddress!)
            }
        }
        try check(code, "spawn")
        let spawned = DispatchTime.now()
        let deadline = min(spawned + patience, limit)
        var killed: DispatchTime?
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { break }
            guard reaped == 0 else {
                if errno == EINTR { continue }
                throw FixtureFailure("wait errno \(errno)")
            }
            let now = DispatchTime.now()
            if let killed {
                if now >= killed + 30 {
                    let bound = Double(killed.uptimeNanoseconds - spawned.uptimeNanoseconds) / 1e9
                    let elapsed = Double(now.uptimeNanoseconds - spawned.uptimeNanoseconds) / 1e9
                    return (.unreaped(Int(bound.rounded())), elapsed)
                }
            } else if now >= deadline {
                kill(pid, SIGKILL)
                killed = now
            }
            _ = poll(nil, 0, 10)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - spawned.uptimeNanoseconds) / 1e9
        let end: End = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
        // A child that exited on its own just before the kill keeps its own status.
        if let killed, end == .signaled(SIGKILL) {
            let bound = Double(killed.uptimeNanoseconds - spawned.uptimeNanoseconds) / 1e9
            return (.expired(Int(bound.rounded())), seconds)
        }
        return (end, seconds)
    }

    private func rejection(of receipt: Receipt, expected: Configuration) -> Rejection? {
        guard receipt.exitedNormally && receipt.status == 0 else { return .process }
        guard let bytes = receipt.result else { return .missingResult }
        guard let report = try? JSONDecoder().decode(Report.self, from: bytes), report.schema == 1 else { return .malformedResult }
        guard report.nonce == expected.nonce && report.testID == expected.testID && report.scenario == expected.scenario else { return .identity }
        if expected.scenario.hasPrefix("spawnFailure-") {
            let prototype = AppleScriptRunner.RunError.launchFailed("synthetic") as NSError
            guard report.outcomes.isEmpty, let error = report.failure, error.launcherKind == "launchFailed",
                  error.type == String(reflecting: AppleScriptRunner.RunError.self),
                  error.domain == prototype.domain, error.code == prototype.code,
                  error.description.hasPrefix("osascript launch failed: ") else { return .outcome }
        } else {
            guard report.failure == nil, report.outcomes == expectedOutcomes(expected.scenario) else { return .outcome }
        }
        guard report.restorationErrors.isEmpty, report.original.count == 3, report.restored.count == 3,
              report.original == report.restored,
              report.original.map(\.descriptor) == [0, 1, 2],
              report.original.map(\.identity) == receipt.identities else { return .restoration }
        let markers = Self.markers(expected.nonce)
        guard report.writes == markers.map(\.count),
              receipt.stdout.range(of: markers[0]) != nil, receipt.stderr.range(of: markers[1]) != nil,
              receipt.stdout.range(of: markers[1]) == nil, receipt.stderr.range(of: markers[0]) == nil else { return .captures }
        return nil
    }

    private func expectedOutcomes(_ scenario: String) -> [OutcomeRecord] {
        if scenario == "handshake" { return [] }
        var stdout = Self.probeOut
        if scenario == "sentinel" { stdout = Data("sentinel=0\n".utf8) + stdout }
        if scenario == "overlap" {
            return [OutcomeRecord(ScriptOutcome(terminationStatus: 0, standardOutput: Self.probeOut, standardError: Self.probeErr)),
                    OutcomeRecord(ScriptOutcome(terminationStatus: 0, standardOutput: Data("foreign=0\n".utf8) + Self.probeOut + Data(Self.input.utf8), standardError: Self.probeErr))]
        }
        if scenario.hasPrefix("stdin-") || scenario.hasPrefix("timedStdin-") || scenario == "sentinel" {
            stdout += Data(Self.input.utf8)
        }
        return [OutcomeRecord(ScriptOutcome(terminationStatus: scenario == "status7" ? 7 : 0,
                                             standardOutput: stdout, standardError: Self.probeErr))]
    }

    private func runChild(current: String, environment: [String: String]) throws {
        let configuration = try validateRole(current: current, environment: environment)
        let host = try HostContext.current()
        let clearing = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, String?.none) })
        try TestEnvironment.with(clearing) {
            try Self.writePrivate(Data(configuration.nonce.utf8), to: configuration.directory.appendingPathComponent("entered"))
            var report = perform(configuration: configuration, observer: host.observer)
            // Fault controls corrupt only the returned evidence, after the same healthy I/O and
            // restoration path. Parent expectations remain independently constructed above.
            switch configuration.scenario {
            case "negative-missing": return
            case "negative-nonce": report.nonce = UUID().uuidString
            case "negative-id": report.testID = "unrelated.synthetic.test"
            case "negative-bytes":
                // A failed launch leaves no outcome to corrupt; the guard keeps an empty list from
                // being indexed, and the parent's control check then sees that failure.
                if !report.outcomes.isEmpty { report.outcomes[0].stdout = Data("wrong bytes".utf8) }
            case "negative-restoration": report.restorationErrors.append(Self.syntheticRestoration)
            case "negative-malformed":
                try Self.writePrivate(Data("{}".utf8), to: configuration.directory.appendingPathComponent("result")); return
            default: break
            }
            try Self.writePrivate(try JSONEncoder().encode(report), to: configuration.directory.appendingPathComponent("result"))
        }
    }

    private func validateRole(current: String, environment: [String: String]) throws -> Configuration {
        guard environment[Self.prefix + "ROLE"] == "child-v1",
              environment[Self.prefix + "ID"] == current,
              let parent = environment[Self.prefix + "PARENT"].flatMap(Int32.init),
              parent > 1, parent != getpid(), parent == getppid(),
              let nonce = environment[Self.prefix + "NONCE"], UUID(uuidString: nonce)?.uuidString == nonce,
              let path = environment[Self.prefix + "DIRECTORY"], path.hasPrefix("/") else { throw FixtureFailure("invalid role") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard directory == directory.resolvingSymlinksInPath(), directory.lastPathComponent == nonce else { throw FixtureFailure("invalid directory") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o700 else { throw FixtureFailure("directory permissions") }
        let bytes = try Self.readPrivate(directory.appendingPathComponent("config"))
        let configuration = try JSONDecoder().decode(Configuration.self, from: bytes)
        guard configuration.schema == 1, configuration.nonce == nonce, configuration.parent == parent,
              configuration.testID == current, configuration.directory == directory,
              Self.validScenario(configuration.scenario) else { throw FixtureFailure("configuration mismatch") }
        // Exclusive, one-use claim is made before any stdfd operation. A consumed nonce fails
        // closed even if every other field is still correct.
        try Self.writePrivate(Data(nonce.utf8), to: directory.appendingPathComponent("claimed"))
        return configuration
    }

    private static func validScenario(_ scenario: String) -> Bool {
        if ["handshake", "sentinel", "overlap", "status7", "negative-missing", "negative-nonce", "negative-id",
            "negative-bytes", "negative-restoration", "negative-malformed"].contains(scenario) { return true }
        let parts = scenario.split(separator: "-")
        return parts.count == 2 && ["inline", "timed", "stdin", "timedStdin", "spawnFailure"].contains(String(parts[0]))
            && parts[1].count == 1 && parts[1].first.map { "01234567".contains($0) } == true
    }

    private func perform(configuration: Configuration, observer: URL) -> Report {
        var report = Report(nonce: configuration.nonce, testID: configuration.testID, scenario: configuration.scenario)
        var saved: [(original: Int32, duplicate: Int32, flags: Int32)] = []
        do {
            // This defer executes before error serialization, known writes, or any reporter
            // activity. Capture launcher and restoration failures independently.
            defer {
                for pair in saved {
                    if dup2(pair.duplicate, pair.original) != pair.original {
                        report.restorationErrors.append("dup2 \(pair.original) errno \(errno)")
                    } else if fcntl(pair.original, F_SETFD, pair.flags) != 0 {
                        report.restorationErrors.append("setflags \(pair.original) errno \(errno)")
                    }
                    if close(pair.duplicate) != 0 { report.restorationErrors.append("close saved errno \(errno)") }
                }
            }
            for fd: Int32 in 0...2 {
                let fact = try DescriptorFact.read(fd)
                report.original.append(fact)
                let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 64)
                guard duplicate >= 64 else { throw FixtureFailure("save stdfd errno \(errno)") }
                saved.append((fd, duplicate, fact.flags))
            }
            let mask = Int(configuration.scenario.split(separator: "-").last ?? "") ?? 0
            for fd: Int32 in 0...2 where mask & (1 << Int(fd)) != 0 {
                guard close(fd) == 0 else { throw FixtureFailure("close stdfd errno \(errno)") }
            }
            report.outcomes = try invokeLauncher(configuration: configuration, observer: observer)
        } catch let starved as Starved {
            report.failure = FailureRecord(starved.underlying, timing: true)
        } catch { report.failure = FailureRecord(error) }
        for fd: Int32 in 0...2 {
            do { report.restored.append(try DescriptorFact.read(fd)) }
            catch { report.restorationErrors.append("fstat restored \(fd): \(error)") }
        }
        for (index, marker) in Self.markers(configuration.nonce).enumerated() {
            do { report.writes.append(try Self.writeAll(Int32(index + 1), marker)) }
            catch { report.restorationErrors.append("known write \(index + 1): \(error)") }
        }
        return report
    }

    private func invokeLauncher(configuration: Configuration, observer: URL) throws -> [OutcomeRecord] {
        let scenario = configuration.scenario
        if scenario == "handshake" { return [] }
        if scenario == "overlap" { return try overlappingLaunchers(directory: configuration.directory, observer: observer) }
        if scenario.hasPrefix("spawnFailure-") {
            return [OutcomeRecord(try OsascriptLauncher().launch(ScriptInvocation(
                executablePath: configuration.directory.appendingPathComponent("missing-executable").path,
                arguments: [], delivery: .timedStdin(script: Self.input, seconds: 3))))]
        }
        var arguments = [scenario == "status7" ? "exit7" : "io"]
        var sentinel: Int32 = -1
        defer { if sentinel >= 0 { close(sentinel) } }
        if scenario == "sentinel" {
            let file = try Self.newFile(configuration.directory.appendingPathComponent("sentinel"))
            defer { try? file.close() }
            sentinel = fcntl(file.fileDescriptor, F_DUPFD, 96)
            guard sentinel >= 96, fcntl(sentinel, F_SETFD, 0) == 0 else { throw FixtureFailure("sentinel descriptor") }
            arguments = ["sentinel", String(sentinel)] + (try Identity.read(sentinel)).arguments
        }
        // No probe scenario is about its deadline: the subject is which descriptors the C entry
        // sees, the exact capture bytes, and the restoration of 0/1/2. The bound starts when
        // `spawn` returns, so it must also cover the probe's own start-up inside a re-executed and
        // possibly starved helper; a short bound would race that start-up and turn ordinary delay
        // into misses that spend the re-runs every scenario shares. Thirty seconds is past the
        // probe's eight-second alarm, which still ends a stalled probe (as a SIGALRM status, which
        // the parent classes as a miss only when all the probe wrote matches and it had not echoed
        // all its input without EOF, see `starvedEvidence`, and only once that alarm could have
        // fired, see `launchProbe`), and below the child's `armExpiry`. The `spawnFailure-*`
        // deadline above is three seconds: nothing is spawned, so it never starts.
        let delivery: ScriptDelivery
        if scenario.hasPrefix("inline-") { delivery = .inline }
        else if scenario.hasPrefix("timed-") || scenario.hasPrefix("negative-")
            || scenario == "status7" { delivery = .timed(seconds: 30) }
        else if scenario.hasPrefix("stdin-") { delivery = .stdin(script: Self.input) }
        else { delivery = .timedStdin(script: Self.input, seconds: 30) }
        guard let healthy = expectedOutcomes(scenario).first else {
            throw FixtureFailure("no healthy outcome for \(scenario)")
        }
        return [OutcomeRecord(try Self.launchProbe(ScriptInvocation(
            executablePath: observer.path, arguments: arguments, delivery: delivery),
            healthy: healthy))]
    }

    /// The probe's own expiry, `alarm(8)` in `LauncherFDProbe/main.c`, armed in its `main`.
    private static let probeAlarm = 8.0
    /// A launcher failure that only starvation can explain: a late EPIPE, or a launch deadline that
    /// had passed (see `launchProbe`).
    private struct Starved: Error { let underlying: any Error }

    /// One probe launch. A launcher descheduled past the probe's alarm finds the probe gone and
    /// reports its stdin delivery as failed (EPIPE), not as the probe's SIGALRM status. That is
    /// starvation's only when at least `probeAlarm` has passed since the launch began, since the
    /// alarm is armed after that; a probe that exits early for any other reason fails delivery
    /// sooner, and that stays a product failure, as does a delivery failure with any errno but
    /// EPIPE, however late.
    ///
    /// Likewise, a `TimeoutError` is `Starved` only for a form with a deadline and only once that
    /// deadline has passed since the launch began (the launcher starts it after `spawn`, on this
    /// same clock); for `.inline` and `.stdin`, or sooner, it is a product failure. A SIGALRM
    /// status sooner than `probeAlarm` is one too.
    ///
    /// A late failure is still a product failure when what the launcher dropped contradicts a
    /// healthy probe: the probe's status as the launcher observed it (only its alarm for EPIPE; for
    /// a deadline also its healthy status or the launcher's SIGTERM or SIGKILL), what the probe
    /// left on its stdout or stderr when that is not a prefix of the same stream's healthy bytes
    /// (`sentinel=1` or `foreign=1` arrives before stdin is read, and a crossed stream starts with
    /// the other one's line), or any byte the launcher read from a descriptor that carries neither
    /// stream. `LaunchWitness` keeps all three, including what the launcher never read.
    ///
    /// Residual: the elapsed checks use uptime, which a host's sleep pauses while the probe's alarm
    /// may count on, so a launch that spans a sleep can fail this way.
    private static func launchProbe(_ invocation: ScriptInvocation,
                                    healthy: OutcomeRecord) throws -> ScriptOutcome {
        let witness = LaunchWitness()
        let started = DispatchTime.now()
        let outcome: ScriptOutcome
        do { outcome = try witness.launcher.launch(invocation) }
        catch {
            var late: Double?
            var statuses: Set<Int32> = [SIGALRM]
            if let failure = error as? AppleScriptRunner.RunError,
               case .launchFailed(let message) = failure, message == brokenPipe {
                late = probeAlarm
            } else if error is AppleScriptRunner.TimeoutError {
                late = deadline(of: invocation.delivery)
                statuses.formUnion([healthy.status, SIGTERM, SIGKILL])
            }
            guard let bound = late, DispatchTime.now() >= started + bound else { throw error }
            if let status = witness.observed, !statuses.contains(status) {
                throw FixtureFailure("the launch failed late (\(error)), but the probe had ended "
                    + "with status \(status), which neither its alarm nor a stall explains")
            }
            for (name, left, expected) in [("stdout", witness.stdout, healthy.stdout),
                                           ("stderr", witness.stderr, healthy.stderr)]
                where !expected.starts(with: left) {
                throw FixtureFailure("the launch failed late (\(error)), but the probe had "
                    + "written \(firstLine(left)) to its \(name), which a healthy probe never "
                    + "writes there")
            }
            if witness.stray > 0 {
                throw FixtureFailure("the launch failed late (\(error)), but the launcher had "
                    + "read \(witness.stray) bytes from a descriptor that carries neither stream")
            }
            throw Starved(underlying: error)
        }
        if outcome.terminationStatus == SIGALRM, DispatchTime.now() < started + probeAlarm {
            throw FixtureFailure("the probe ended by SIGALRM within \(Int(probeAlarm)) s of its "
                + "launch, before its own alarm could have fired")
        }
        return outcome
    }
    /// The deadline `delivery` sets, or nil for the forms that have none.
    private static func deadline(of delivery: ScriptDelivery) -> Double? {
        switch delivery {
        case .timed(let seconds), .timedStdin(_, let seconds): return seconds
        case .inline, .stdin: return nil
        }
    }
    /// The first line of `bytes`, quoted; the probes' first lines are fixed tokens.
    private static func firstLine(_ bytes: Data) -> String {
        String(decoding: bytes.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self).debugDescription
    }

    /// The real descriptor and child operations of one probe launch, forwarded unchanged, keeping
    /// what the launcher drops when it throws: what the probe wrote to each stream and the probe's
    /// status as the launcher last observed it (`waitid` with `WNOWAIT`). The spawn is the
    /// product's own, so what the probe inherits is unchanged.
    ///
    /// A stream is what the launcher read from it and then, when the launcher closes it, what it
    /// still held: a pipe drained without waiting, a capture file read back by offset. Reads alone
    /// would miss what a launcher that threw before reading left behind (a deadline is checked
    /// before each `poll`, and EPIPE can come on a turn that reported only the writer), and an
    /// unread `sentinel=1` would then pass as a miss. The product closes every descriptor it still
    /// holds once it has signalled the probe (`cancel`), so each stream passes through here whole.
    /// Each stream is mapped at `spawn` from the pipe write end or capture handed to the probe as
    /// its descriptor 1 or 2, so each is judged against its own healthy bytes, never the other
    /// stream's.
    ///
    /// Not covered: which of its own streams the launcher files those bytes under. A launcher that
    /// swaps its two pipes or captures where it calls `spawn` hands the probe a pair that still
    /// matches what the probe writes, so the swap shows only in an outcome the launcher returns,
    /// never in a late failure. A swap inside `spawn`, between the descriptors and the probe's 1
    /// and 2, is judged here and fails.
    private final class LaunchWitness: ScriptProcessIO, ScriptProcessChildren,
                                       @unchecked Sendable {
        private enum ProbeStream { case stdout, stderr }
        private let io = DarwinScriptProcessIO()
        private let children = DarwinScriptProcessChildren()
        private let lock = NSLock()
        private var pipes: [(read: Int32, write: Int32)] = []
        private var captures: Set<Int32> = []
        private var streams: [Int32: ProbeStream] = [:]
        private var bytes: [ProbeStream: Data] = [:]
        private var strayBytes = 0
        private var status: Int32?
        /// What the probe left on its stdout and on its stderr.
        var stdout: Data { lock.withLock { bytes[.stdout] ?? Data() } }
        var stderr: Data { lock.withLock { bytes[.stderr] ?? Data() } }
        /// Bytes the launcher read from a descriptor that carries neither stream.
        var stray: Int { lock.withLock { strayBytes } }
        var observed: Int32? { lock.withLock { status } }
        var launcher: OsascriptLauncher {
            var dependencies = ScriptProcessDependencies()
            dependencies.io = self
            dependencies.children = self
            return OsascriptLauncher(dependencies: dependencies)
        }

        func pipe() throws -> (read: Int32, write: Int32) {
            let pair = try io.pipe()
            lock.withLock { pipes.append(pair) }
            return pair
        }
        func nullInput() throws -> Int32 { try io.nullInput() }
        func capture(in directory: URL) throws -> Int32 {
            let fd = try io.capture(in: directory)
            lock.withLock { _ = captures.insert(fd) }
            return fd
        }
        func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            let count = try io.read(fd, into: buffer)
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                lock.withLock {
                    if let stream = streams[fd] { bytes[stream, default: Data()].append(chunk) }
                    else { strayBytes += chunk.count }
                }
            }
            return count
        }
        func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int {
            try io.write(fd, from: buffer)
        }
        func captureSize(_ fd: Int32) throws -> off_t { try io.captureSize(fd) }
        func captureSnapshot(_ fd: Int32, maximumBytes: Int?,
                             configuredLimit: Int?) throws -> Data {
            try io.captureSnapshot(fd, maximumBytes: maximumBytes, configuredLimit: configuredLimit)
        }
        /// Keeps what a stream's descriptor still holds, then closes it as the launcher asked.
        func close(_ fd: Int32) throws {
            let (stream, isCapture) = lock.withLock {
                (streams.removeValue(forKey: fd), captures.remove(fd) != nil)
            }
            if let stream {
                let rest = isCapture ? Self.contents(of: fd) : drain(fd)
                lock.withLock { bytes[stream, default: Data()].append(rest) }
            }
            try io.close(fd)
        }
        /// What a pipe still holds, never waiting: each read follows a `poll` with no timeout, and
        /// it stops at end of file, an empty pipe, an error, or 64 reads.
        private func drain(_ fd: Int32) -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<64 {
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let polled = poll(&ready, 1, 0)
                if polled < 0 && errno == EINTR { continue }
                guard polled == 1, ready.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
                let count: Int
                do { count = try buffer.withUnsafeMutableBytes { try io.read(fd, into: $0) } }
                catch {
                    let value = error as NSError
                    if value.domain == NSPOSIXErrorDomain && value.code == Int(EINTR) { continue }
                    break
                }
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
        /// What a capture file holds, read by offset so the shared file position never moves, in at
        /// most 64 reads.
        private static func contents(of fd: Int32) -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<64 {
                let offset = off_t(data.count)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.pread(fd, $0.baseAddress, $0.count, offset)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }

        var reaper: any ScriptProcessReaping { children.reaper }
        func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32,
                   error: Int32) throws -> pid_t {
            let pid = try children.spawn(invocation, input: input, output: output, error: error)
            lock.withLock {
                for pair in pipes {
                    if pair.write == output { streams[pair.read] = .stdout }
                    if pair.write == error { streams[pair.read] = .stderr }
                }
                if captures.contains(output) { streams[output] = .stdout }
                if captures.contains(error) { streams[error] = .stderr }
            }
            return pid
        }
        func observe(_ pid: pid_t) throws -> Int32? {
            let value = try children.observe(pid)
            if let value { lock.withLock { status = value } }
            return value
        }
        func signal(group: pid_t, signal: Int32) throws {
            try children.signal(group: group, signal: signal)
        }
    }
    /// The product's whole message for a stdin write that found the reader gone, POSIX EPIPE (32),
    /// built as `OwnedScriptProcess` builds it, so any change there fails closed.
    private static let brokenPipe = "could not deliver script on stdin: "
        + String(describing: NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)))

    /// The first launch holds regular-file captures open. The second C entry scans for those exact
    /// live fstat identities; file descriptor numbers and ambient counts are irrelevant.
    ///
    /// None of the waits here is the subject; the expected outcomes (`foreign=0`, exact bytes) are.
    /// Both launches go through `launchProbe` with thirty-second deadlines from `spawn`, so the
    /// hold probe's own eight-second alarm (armed in its `main`) is what ends a stalled hold, and a
    /// deadline or alarm counts as time only once it could have fired.
    ///
    /// The scan sweeps every descriptor below the soft limit it inherits from this child. At the
    /// 1,048,576 a shell can hand down, that sweep alone costs about a third of a second of CPU
    /// unloaded, all inside the hold's alarm, which this file cannot change, so under starvation
    /// the alarm could end the hold before the release. Once the hold has published, and so after
    /// the first launch has allocated its captures under the inherited limit, this child lowers its
    /// soft limit to 256 above its highest open descriptor as the kernel lists them, checks the
    /// list again, makes the second launch, and restores the limit. A probe inherits descriptors at
    /// the numbers they have here and none can be created at or above the lowered limit, so the
    /// sweep still covers every descriptor the second launch could leak, wherever the first launch
    /// put it.
    ///
    /// Readiness waits until the hold publishes, its launch ends, or thirty seconds pass from the
    /// dispatch; the hold's alarm starts only in its `main`, so readiness need not fit inside it.
    /// The readiness deadline is a timing failure, and so is a hold that ends before publishing
    /// when `timedOut` holds; any other early end is a product failure. The join waits sixty
    /// seconds from the dispatch, so it does not shrink however long readiness and the second
    /// launch took; it waits only for the hold's launch, which ends by its thirty-second deadline
    /// plus about two seconds of TERM-then-KILL cleanup, leaving twenty-eight for the dispatch and
    /// spawn. Both launches are then judged together (`joint`), so one that ran out of time, or the
    /// join, never hides what the other left.
    private func overlappingLaunchers(directory: URL, observer: URL) throws -> [OutcomeRecord] {
        let ready = directory.appendingPathComponent("capture-identities")
        let release = directory.appendingPathComponent("release")
        let healthy = expectedOutcomes("overlap")
        let holdHealthy = healthy[0]
        let result = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        DispatchQueue.global().async {
            result.set(Result {
                try Self.launchProbe(ScriptInvocation(executablePath: observer.path,
                    arguments: ["hold", ready.path, release.path], delivery: .timed(seconds: 30)),
                    healthy: holdHealthy)
            })
            finished.signal()
        }
        var second: Result<ScriptOutcome, any Error>
        do {
            let deadline = started.uptimeNanoseconds + 30_000_000_000
            while true {
                if let bytes = try? Data(contentsOf: ready), bytes.last == UInt8(ascii: "\n"),
                   String(decoding: bytes, as: UTF8.self).split(separator: "\n").count == 2 {
                    break
                }
                if let ended = result.peek() {
                    throw FixtureFailure("overlap hold ended before publishing",
                                         timing: Self.timedOut(ended))
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw FixtureFailure("overlap ready deadline", timing: true)
                }
                usleep(1000)
            }
            second = try Self.withNarrowedDescriptorLimit {
                Result {
                    try Self.launchProbe(ScriptInvocation(executablePath: observer.path,
                        arguments: ["scan", ready.path],
                        delivery: .timedStdin(script: Self.input, seconds: 30)),
                        healthy: healthy[1])
                }
            }
        } catch { second = .failure(error) }
        // Release even if the second invocation/readiness failed, then join the first's bounded
        // launcher call. The C child also has its own alarm; no numeric PID is signalled here.
        let released = Result { try Self.writePrivate(Data("release\n".utf8), to: release) }
        let joined = finished.wait(timeout: started + 60) == .success
        try released.get()
        let first: Result<ScriptOutcome, any Error>
        if joined { first = result.peek() ?? .failure(FixtureFailure("missing overlap outcome")) }
        else { first = .failure(FixtureFailure("overlap join deadline", timing: true)) }
        return try Self.joint([first, second], healthy: healthy)
    }
    /// Judges both overlap launches together. When both returned, their outcomes go to the parent
    /// to judge. Otherwise it throws, in this order: a returned outcome that is neither healthy nor
    /// `cutShort`, or that has the no-EOF shape (`unended`), then a failure that is not timing, all
    /// product failures; only then the timing failure, a miss. So one launch running out of time
    /// never hides what the other left.
    private static func joint(_ results: [Result<ScriptOutcome, any Error>],
                              healthy: [OutcomeRecord]) throws -> [OutcomeRecord] {
        var records: [OutcomeRecord] = []
        var failures: [any Error] = []
        for result in results {
            switch result {
            case .success(let outcome): records.append(OutcomeRecord(outcome))
            case .failure(let error): failures.append(error)
            }
        }
        guard let failure = failures.first else { return records }
        for (index, result) in results.enumerated() {
            guard case .success(let outcome) = result else { continue }
            let record = OutcomeRecord(outcome)
            let name = index == 0 ? "hold" : "scan"
            if unended(record, of: healthy[index]) {
                throw FixtureFailure("the overlap's \(name) probe echoed all its input and then "
                    + "ran to its own alarm without EOF while the other launch failed "
                    + "(\(failure)); the likely cause is an inherited stdin write end withholding "
                    + "EOF, the alternative the runner withholding the probe or the launcher until "
                    + "the probe's \(Int(probeAlarm)) s alarm fired after its last echo")
            }
            if record != healthy[index] && !cutShort(record, of: healthy[index]) {
                throw FixtureFailure("the overlap's \(name) probe left status \(record.status) and "
                    + "first line \(firstLine(record.stdout)) while the other launch failed: "
                    + "\(failure)")
            }
        }
        if let product = failures.first(where: { !isTiming($0) }) { throw product }
        throw failure
    }
    /// Whether `error` ran out for want of time, as `perform` records it.
    private static func isTiming(_ error: any Error) -> Bool {
        error is Starved || (error as? FixtureFailure)?.timing == true
    }
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<ScriptOutcome, any Error>?
        func set(_ value: Result<ScriptOutcome, any Error>) { lock.lock(); self.value = value; lock.unlock() }
        func peek() -> Result<ScriptOutcome, any Error>? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    /// Whether the hold's launch ended for want of time: its deadline, or its own alarm, each only
    /// once it could have fired, which `launchProbe` has already checked.
    private static func timedOut(_ ended: Result<ScriptOutcome, any Error>) -> Bool {
        switch ended {
        case .failure(let error): error is Starved
        case .success(let outcome): outcome.terminationStatus == SIGALRM
        }
    }

    /// Runs `body` with this child's soft descriptor limit lowered to 256 above its highest open
    /// descriptor (see `overlappingLaunchers`), and restores the previous limit on every way out
    /// once it has changed, a throw from the second descriptor list included. Fails closed: the
    /// kernel's own list is read again after the change and must hold nothing at or above it, or
    /// `body` never runs. The restore is best effort, since a `defer` cannot throw and this child
    /// exits after the run.
    private static func withNarrowedDescriptorLimit(
        _ body: () -> Result<ScriptOutcome, any Error>
    ) throws -> Result<ScriptOutcome, any Error> {
        var original = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &original) == 0 else {
            throw FixtureFailure("getrlimit errno \(errno)")
        }
        guard let highest = try openDescriptors().max(), highest >= 0 else {
            throw FixtureFailure("descriptor list")
        }
        var narrowed = original
        narrowed.rlim_cur = min(original.rlim_cur, rlim_t(highest) + 257)
        guard setrlimit(RLIMIT_NOFILE, &narrowed) == 0 else {
            throw FixtureFailure("setrlimit errno \(errno)")
        }
        defer { _ = setrlimit(RLIMIT_NOFILE, &original) }
        guard try openDescriptors().allSatisfy({ $0 >= 0 && rlim_t($0) < narrowed.rlim_cur }) else {
            throw FixtureFailure("a descriptor is open above the lowered limit")
        }
        return body()
    }
    private static func openDescriptors() throws -> [Int32] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var capacity = 256
        while capacity <= 1 << 20 {
            var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bytes = entries.withUnsafeMutableBytes {
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else { throw FixtureFailure("descriptor list errno \(errno)") }
            // A full buffer may be truncated; ask again with room to spare.
            if Int(bytes) < capacity * stride {
                return entries.prefix(Int(bytes) / stride).map(\.proc_fd)
            }
            capacity *= 4
        }
        throw FixtureFailure("descriptor list too long")
    }

    private func positiveInheritanceControls(host: HostContext, root: URL, budget: Budget) throws {
        let directory = root.appendingPathComponent("positive-control", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let sentinel = directory.appendingPathComponent("sentinel")
        let payload = Data("synthetic sentinel\n".utf8)
        try Self.writePrivate(payload, to: sentinel)
        let input = try FileHandle(forReadingFrom: sentinel)
        defer { try? input.close() }
        let identity = try Identity.read(input.fileDescriptor)
        let identityFile = directory.appendingPathComponent("identities")
        let line = identity.arguments.joined(separator: " ") + "\n"
        try Self.writePrivate(Data((line + line).utf8), to: identityFile)
        for mode in ["sentinel", "scan"] {
            // A probe ended by its own alarm, or killed here, before it finished is a miss only
            // when everything it wrote is a prefix of the healthy output; anything else fails at
            // once.
            //
            // Residual: the scan sweeps the soft descriptor limit this test process hands down,
            // which it cannot lower while other suites run in it, so a starved sweep can still
            // outrun the probe's alarm and spend re-runs here.
            try run("positive \(mode)", budget) { attempt in
                let stdoutURL = directory.appendingPathComponent("\(mode)-\(attempt)-stdout")
                let stderrURL = directory.appendingPathComponent("\(mode)-\(attempt)-stderr")
                let out = try Self.newFile(stdoutURL), err = try Self.newFile(stderrURL)
                defer { try? out.close(); try? err.close() }
                try input.seek(toOffset: 0)
                let arguments = mode == "sentinel"
                    ? [mode, "0"] + identity.arguments : [mode, identityFile.path]
                let launched = try Self.launch(
                    host.observer, arguments, environment: ProcessInfo.processInfo.environment,
                    stdio: [input.fileDescriptor, out.fileDescriptor, err.fileDescriptor],
                    patience: Self.probePatience, limit: budget.limit)
                budget.record(launched.seconds)
                let prefix = mode == "sentinel" ? "sentinel=1\n" : "foreign=1\n"
                let stdout = try Data(contentsOf: stdoutURL)
                let stderr = try Data(contentsOf: stderrURL)
                let healthy = Data(prefix.utf8) + Self.probeOut + payload
                if launched.end == .exited(0) && stdout == healthy && stderr == Self.probeErr {
                    return .passed
                }
                let cut = switch launched.end {
                case .signaled(SIGALRM), .expired, .unreaped: true
                case .exited, .signaled: false
                }
                if cut, healthy.starts(with: stdout), Self.probeErr.starts(with: stderr) {
                    return .missed("the probe was \(launched.end) before it finished")
                }
                return .failed("the probe must see a deliberately inherited descriptor; it "
                    + "\(launched.end) with \(stdout.count) bytes of stdout and \(stderr.count) "
                    + "of stderr")
            }
        }
    }

    private static func armExpiry() {
        signal(SIGALRM, SIG_DFL)
        var signals = sigset_t()
        guard sigemptyset(&signals) == 0, sigaddset(&signals, SIGALRM) == 0,
              pthread_sigmask(SIG_UNBLOCK, &signals, nil) == 0 else { Darwin._exit(85) }
        // Remains armed through reporter shutdown, including the close012 case. 120 seconds keeps
        // it the outermost bound in the child, about twice the overlap scenario's longest path:
        // thirty seconds of readiness then a thirty-second launch plus cleanup, or the sixty-second
        // join. Its death is a `.process` receipt, which the parent classes as a miss once the
        // child has run for `childExpiry` and the rest of its evidence holds (see `missReason`):
        // printed and re-run, and recorded by the attempt that cannot be re-run.
        alarm(Self.childExpiry)
    }
    private static func markers(_ nonce: String) -> [Data] {
        [Data("restored-stdout:\(nonce)\n".utf8), Data("restored-stderr:\(nonce)\n".utf8)]
    }
    private static func newFile(_ path: URL) throws -> FileHandle {
        let fd = open(path.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FixtureFailure("private create errno \(errno)") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func writePrivate(_ bytes: Data, to path: URL) throws {
        let file = try newFile(path)
        defer { try? file.close() }
        _ = try writeAll(file.fileDescriptor, bytes)
    }
    private static func writeAll(_ descriptor: Int32, _ bytes: Data) throws -> Int {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw FixtureFailure("write errno \(errno)") }
                offset += n
            }
            return offset
        }
    }
    private static func readPrivate(_ path: URL) throws -> Data {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureFailure("private read errno \(errno)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o7777) == 0o600,
              info.st_size >= 0, info.st_size <= 16384 else { throw FixtureFailure("private file metadata") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw FixtureFailure("short private read") }
            offset += n
        }
        return Data(bytes)
    }
}
