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

    // Nonparameterized by design: its exact runtime ID selects one child test, never all
    // argument cases or a reconstructed source-location-dependent ID.
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

        // Handshake establishes this exact helper/bundle/library/filter route before any
        // descriptor-closing scenario. A zero-exit empty selection cannot satisfy its receipt.
        let handshake = try prepare(root: root, testID: current, scenario: "handshake")
        let initial = try invoke(host: host, configuration: handshake)
        try #require(rejection(of: initial, expected: handshake) == nil)

        for mode in ["inline", "timed", "stdin", "timedStdin", "spawnFailure"] {
            for mask in 0...7 {
                let configuration = try prepare(root: root, testID: current, scenario: "\(mode)-\(mask)")
                let receipt = try invoke(host: host, configuration: configuration)
                #expect(rejection(of: receipt, expected: configuration) == nil,
                        "isolated scenario \(configuration.scenario) must return exact evidence")
            }
        }
        for scenario in ["sentinel", "overlap", "status7"] {
            let configuration = try prepare(root: root, testID: current, scenario: scenario)
            #expect(rejection(of: try invoke(host: host, configuration: configuration), expected: configuration) == nil)
        }
        try positiveInheritanceControls(host: host, root: root)

        // These children still exit zero. Each differs from a healthy receipt in one field;
        // acceptance must reject the specific missing or corrupted evidence.
        for (scenario, expected) in [
            ("negative-missing", Rejection.missingResult), ("negative-nonce", .identity),
            ("negative-id", .identity), ("negative-bytes", .outcome),
            ("negative-restoration", .restoration), ("negative-malformed", .malformedResult),
        ] {
            let configuration = try prepare(root: root, testID: current, scenario: scenario)
            let receipt = try invoke(host: host, configuration: configuration)
            #expect(receipt.exitedNormally && receipt.status == 0)
            #expect(rejection(of: receipt, expected: configuration) == expected)
        }
        for fault in ["role", "missing-role", "nonce", "parent", "id", "config", "permissions", "claimed"] {
            let configuration = try prepare(root: root, testID: current, scenario: "handshake")
            let receipt = try invoke(host: host, configuration: configuration, roleFault: fault)
            #expect(receipt.exitedNormally && receipt.status == 86)
            #expect(receipt.result == nil)
            #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("entered").path))
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

    private final class BundleMarker: NSObject {}
    private struct FixtureFailure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

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
        init(_ error: any Error) {
            let ns = error as NSError
            type = String(reflecting: Swift.type(of: error)); domain = ns.domain; code = ns.code
            description = String(describing: error)
            details = ns.userInfo.mapValues { String(describing: $0) }
            if let runnerError = error as? AppleScriptRunner.RunError, case .launchFailed = runnerError {
                launcherKind = "launchFailed"
            } else { launcherKind = nil }
        }
    }
    private struct OutcomeRecord: Codable, Equatable {
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
    private struct Receipt {
        let exitedNormally: Bool
        let status: Int32
        let result: Data?
        let stdout: Data
        let stderr: Data
        let identities: [Identity]
    }
    private enum Rejection: Equatable { case process, missingResult, malformedResult, identity, outcome, restoration, captures }

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

    private func invoke(host: HostContext, configuration: Configuration, roleFault: String? = nil) throws -> Receipt {
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
        let process = Process()
        process.executableURL = host.executable; process.arguments = host.arguments(testID: configuration.testID)
        process.environment = environment
        process.standardInput = input; process.standardOutput = out; process.standardError = err
        try process.run()
        // Each selected fixture arms SIGALRM before blocking. Startup before the test body is
        // additionally bounded by the outer canonical test-process timeout; no stale-PID kill.
        process.waitUntilExit()
        return Receipt(exitedNormally: process.terminationReason == .exit, status: process.terminationStatus,
                       result: try? Data(contentsOf: directory.appendingPathComponent("result")),
                       stdout: try Data(contentsOf: stdoutURL), stderr: try Data(contentsOf: stderrURL), identities: identities)
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
            case "negative-bytes": report.outcomes[0].stdout = Data("wrong bytes".utf8)
            case "negative-restoration": report.restorationErrors.append("synthetic restoration failure")
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
        let delivery: ScriptDelivery
        if scenario.hasPrefix("inline-") { delivery = .inline }
        else if scenario.hasPrefix("timed-") || scenario.hasPrefix("negative-") || scenario == "status7" { delivery = .timed(seconds: 3) }
        else if scenario.hasPrefix("stdin-") { delivery = .stdin(script: Self.input) }
        else { delivery = .timedStdin(script: Self.input, seconds: 3) }
        return [OutcomeRecord(try OsascriptLauncher().launch(ScriptInvocation(
            executablePath: observer.path, arguments: arguments, delivery: delivery)))]
    }

    /// The first launch holds regular-file captures open. The second C entry scans for those
    /// exact live fstat identities; file descriptor numbers and ambient counts are irrelevant.
    private func overlappingLaunchers(directory: URL, observer: URL) throws -> [OutcomeRecord] {
        let ready = directory.appendingPathComponent("capture-identities")
        let release = directory.appendingPathComponent("release")
        let result = OutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.set(Result {
                try OsascriptLauncher().launch(ScriptInvocation(executablePath: observer.path,
                    arguments: ["hold", ready.path, release.path], delivery: .timed(seconds: 4)))
            })
            finished.signal()
        }
        var second: Result<ScriptOutcome, any Error>
        do {
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while true {
                if let bytes = try? Data(contentsOf: ready),
                   String(decoding: bytes, as: UTF8.self).split(separator: "\n").count == 2 { break }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw FixtureFailure("overlap ready deadline") }
                usleep(1000)
            }
            second = Result {
                try OsascriptLauncher().launch(ScriptInvocation(executablePath: observer.path,
                    arguments: ["scan", ready.path], delivery: .timedStdin(script: Self.input, seconds: 3)))
            }
        } catch { second = .failure(error) }
        // Release even if the second invocation/readiness failed, then join the first's bounded
        // launcher call. The C child also has its own alarm; no numeric PID is signalled here.
        let released = Result { try Self.writePrivate(Data("release\n".utf8), to: release) }
        guard finished.wait(timeout: .now() + 9) == .success else { throw FixtureFailure("overlap join deadline") }
        try released.get()
        return [OutcomeRecord(try result.get()), OutcomeRecord(try second.get())]
    }
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<ScriptOutcome, any Error>?
        func set(_ value: Result<ScriptOutcome, any Error>) { lock.lock(); self.value = value; lock.unlock() }
        func get() throws -> ScriptOutcome {
            lock.lock(); defer { lock.unlock() }
            guard let value else { throw FixtureFailure("missing overlap outcome") }
            return try value.get()
        }
    }

    private func positiveInheritanceControls(host: HostContext, root: URL) throws {
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
            let stdoutURL = directory.appendingPathComponent(mode + "-stdout")
            let stderrURL = directory.appendingPathComponent(mode + "-stderr")
            let out = try Self.newFile(stdoutURL), err = try Self.newFile(stderrURL)
            defer { try? out.close(); try? err.close() }
            try input.seek(toOffset: 0)
            let child = Process()
            child.executableURL = host.observer
            child.arguments = mode == "sentinel" ? [mode, "0"] + identity.arguments : [mode, identityFile.path]
            child.standardInput = input; child.standardOutput = out; child.standardError = err
            try child.run(); child.waitUntilExit()
            #expect(child.terminationReason == .exit && child.terminationStatus == 0)
            let prefix = mode == "sentinel" ? "sentinel=1\n" : "foreign=1\n"
            #expect(try Data(contentsOf: stdoutURL) == Data(prefix.utf8) + Self.probeOut + payload)
            #expect(try Data(contentsOf: stderrURL) == Self.probeErr)
        }
    }

    private static func armExpiry() {
        signal(SIGALRM, SIG_DFL)
        var signals = sigset_t()
        guard sigemptyset(&signals) == 0, sigaddset(&signals, SIGALRM) == 0,
              pthread_sigmask(SIG_UNBLOCK, &signals, nil) == 0 else { Darwin._exit(85) }
        alarm(20) // Remains armed through reporter shutdown, including the close012 case.
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
