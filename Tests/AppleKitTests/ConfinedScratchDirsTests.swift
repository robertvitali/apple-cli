import Dispatch
import Foundation
import Testing
@testable import TestSupport

@Suite("ConfinedScratchDirs lifecycle", .serialized)
struct ConfinedScratchDirsTests {
    @Test("cleanup cannot remove the root while another owner is creating its leaf")
    func creationExcludesOtherOwnerCleanup() throws {
        let state = try LifecycleState()
        try state.prepareFirstOwner()
        let creating = DispatchGroup()
        let cleaning = DispatchGroup()
        let creationQueue = DispatchQueue(label: "synthetic.confined.creation")
        let cleanupQueue = DispatchQueue(label: "synthetic.confined.cleanup")
        var creationStarted = false
        var cleanupStarted = false
        defer {
            // Release B on every path, including failed setup/observations. Joining
            // effectful blocks precedes helper/scratch release; no abandoned wait.
            state.continueCreation.signal()
            let creationJoined = !creationStarted || creating.wait(timeout: .now() + 5) == .success
            let cleanupJoined = !cleanupStarted || cleaning.wait(timeout: .now() + 5) == .success
            #expect(creationJoined, "creation worker did not finish within its join bound")
            #expect(cleanupJoined, "cleanup worker did not finish within its join bound")
            if creationJoined && cleanupJoined {
                state.releaseHelpers()
            }
            // If a join fails, each still-running block retains state (and its
            // ScratchDirs owner). The parent cannot delete that worker's files.
        }

        creationStarted = true
        creationQueue.async(group: creating) { state.createSecondOwner() }
        let entered = state.rootCreated.wait(timeout: .now() + 5) == .success
        #expect(entered, "creation never reached the root-to-leaf checkpoint")
        guard entered else { return }

        cleanupStarted = true
        cleanupQueue.async(group: cleaning) { state.destroyFirstOwner() }
        let observed = state.firstEventReady.wait(timeout: .now() + 5) == .success
        #expect(observed, "neither completed cleanup nor actual contention was observed")
        guard observed else { return }

        // B stays paused. Baseline A completes cleanup and removes the root;
        // repaired A must report genuine lock contention before it can clean up.
        #expect(state.event() == .contended)
        #expect(FileManager.default.fileExists(atPath: state.root.path))

        state.continueCreation.signal()
        let creationJoined = creating.wait(timeout: .now() + 5) == .success
        let cleanupJoined = cleaning.wait(timeout: .now() + 5) == .success
        #expect(creationJoined)
        #expect(cleanupJoined)
        guard creationJoined && cleanupJoined else { return }
        #expect(!state.creationFailed())
        #expect(!state.checkpointExpired())
        let leaf = try #require(state.leaf())
        #expect(try permissions(state.root) == 0o700)
        #expect(try permissions(leaf) == 0o700)
        let sentinel = leaf.appendingPathComponent("sentinel.txt")
        let bytes = Data("synthetic retained leaf".utf8)
        try bytes.write(to: sentinel)
        #expect(try Data(contentsOf: sentinel) == bytes)

        state.releaseHelpers()
        #expect(!FileManager.default.fileExists(atPath: leaf.path))
        #expect(!FileManager.default.fileExists(atPath: state.root.path))
    }

    @Test("contention before cleanup is armed cannot satisfy its observation")
    func earlyContentionCannotSatisfyCleanupObservation() throws {
        let state = try LifecycleState()
        state.observeCleanupContention()
        #expect(state.event() == nil)
        #expect(state.firstEventReady.wait(timeout: .now()) == .timedOut)
    }

    @Test("all registered leaves are private and reclaimed with their empty root")
    func registeredLeavesArePrivateAndReclaimed() throws {
        let scratch = ScratchDirs("confined-reclamation")
        let root = try scratch.directory().appendingPathComponent("shared-root", isDirectory: true)
        var owner: ConfinedScratchDirs? = ConfinedScratchDirs("owned", rootForTesting: root)
        let first = try #require(try owner?.directory())
        let second = try #require(try owner?.directory())
        #expect(first != second)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(first) == 0o700)
        #expect(try permissions(second) == 0o700)
        try Data("synthetic owned data".utf8).write(to: first.appendingPathComponent("sentinel.txt"))
        withExtendedLifetime(owner) {}
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        withExtendedLifetime(scratch) {}
    }

    @Test("cleanup preserves another live owner's leaf and an unregistered child")
    func cleanupPreservesLiveOwnerAndForeignChild() throws {
        let scratch = ScratchDirs("confined-preservation")
        let root = try scratch.directory().appendingPathComponent("shared-root", isDirectory: true)
        var first: ConfinedScratchDirs? = ConfinedScratchDirs("first", rootForTesting: root)
        var second: ConfinedScratchDirs? = ConfinedScratchDirs("second", rootForTesting: root)
        let firstLeaf = try #require(try first?.directory())
        let secondLeaf = try #require(try second?.directory())
        let sentinel = secondLeaf.appendingPathComponent("sentinel.txt")
        let foreign = root.appendingPathComponent("unregistered.txt")
        let bytes = Data("synthetic preserved data".utf8)
        try bytes.write(to: sentinel)
        try bytes.write(to: foreign)
        withExtendedLifetime(first) {}
        first = nil
        #expect(!FileManager.default.fileExists(atPath: firstLeaf.path))
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try Data(contentsOf: foreign) == bytes)
        withExtendedLifetime(second) {}
        second = nil
        #expect(!FileManager.default.fileExists(atPath: secondLeaf.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try Data(contentsOf: foreign) == bytes)
        // This test created the unregistered child; the helper must never remove it.
        try FileManager.default.removeItem(at: foreign)
        try FileManager.default.removeItem(at: root)
        withExtendedLifetime(scratch) {}
    }

    @Test("a creation error propagates and releases the shared lifecycle lock")
    func creationErrorReleasesLifecycleLock() throws {
        let scratch = ScratchDirs("confined-error")
        let parent = try scratch.directory()
        let blockedRoot = parent.appendingPathComponent("blocked-root")
        let sentinel = Data("synthetic blocking file".utf8)
        try sentinel.write(to: blockedRoot)
        var failing: ConfinedScratchDirs? = ConfinedScratchDirs("failure", rootForTesting: blockedRoot)
        var refused = false
        do {
            _ = try failing?.directory()
        } catch {
            refused = true
        }
        #expect(refused)
        #expect(try Data(contentsOf: blockedRoot) == sentinel)
        withExtendedLifetime(failing) {}
        failing = nil
        // An instance that never registered a leaf cannot remove the blocking file.
        #expect(try Data(contentsOf: blockedRoot) == sentinel)

        let validRoot = parent.appendingPathComponent("valid-root", isDirectory: true)
        var next: ConfinedScratchDirs? = ConfinedScratchDirs("next", rootForTesting: validRoot)
        let leaf = try #require(try next?.directory())
        #expect(try permissions(leaf) == 0o700)
        withExtendedLifetime(next) {}
        next = nil
        #expect(!FileManager.default.fileExists(atPath: validRoot.path))
        #expect(try Data(contentsOf: blockedRoot) == sentinel)
        withExtendedLifetime(scratch) {}
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? Int)
    }
}

// Test-only reference transfer. Every mutable field uses the state lock. Helper
// calls, final reference release, observers and waits occur outside that lock.
// The queues retain this object for their whole block, so its scratch owner cannot
// be destroyed while any worker remains unresolved. No helper captures it strongly.
private final class LifecycleState: @unchecked Sendable {
    enum Event { case contended, cleanupCompleted }
    private let scratch: ScratchDirs
    let root: URL
    let rootCreated = DispatchSemaphore(value: 0)
    let continueCreation = DispatchSemaphore(value: 0)
    let firstEventReady = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first: ConfinedScratchDirs?
    private var second: ConfinedScratchDirs?
    private var firstEvent: Event?
    private var cleanupArmed = false
    private var createdLeaf: URL?
    private var failed = false
    private var expired = false

    init() throws {
        let owner = ScratchDirs("confined-lifecycle")
        scratch = owner
        root = try owner.directory().appendingPathComponent("shared-root", isDirectory: true)
    }

    func prepareFirstOwner() throws {
        let owner = ConfinedScratchDirs("first", rootForTesting: root,
                                       onLifecycleContention: { [weak self] in
            self?.observeCleanupContention()
        })
        _ = try owner.directory()
        lock.lock(); first = owner; lock.unlock()
    }

    func createSecondOwner() {
        let owner = ConfinedScratchDirs("second", rootForTesting: root,
                                       afterRootCreated: { [weak self] in
            guard let self else { return }
            self.rootCreated.signal()
            if self.continueCreation.wait(timeout: .now() + 5) != .success {
                self.lock.lock(); self.expired = true; self.lock.unlock()
            }
        })
        do {
            let result = try owner.directory()
            lock.lock(); second = owner; createdLeaf = result; lock.unlock()
        } catch {
            lock.lock(); failed = true; lock.unlock()
        }
    }

    func destroyFirstOwner() {
        // Transfer, then release the final strong reference outside the state lock.
        var transferred: ConfinedScratchDirs?
        lock.lock()
        cleanupArmed = true
        transferred = first
        first = nil
        lock.unlock()
        withExtendedLifetime(transferred) {}
        transferred = nil
        publish(.cleanupCompleted)
    }

    func observeCleanupContention() {
        lock.lock()
        let firstObservation = cleanupArmed && firstEvent == nil
        if firstObservation { firstEvent = .contended }
        lock.unlock()
        if firstObservation { firstEventReady.signal() }
    }

    private func publish(_ event: Event) {
        lock.lock()
        let firstObservation = firstEvent == nil
        if firstObservation { firstEvent = event }
        lock.unlock()
        if firstObservation { firstEventReady.signal() }
    }

    func event() -> Event? { lock.lock(); defer { lock.unlock() }; return firstEvent }
    func leaf() -> URL? { lock.lock(); defer { lock.unlock() }; return createdLeaf }
    func creationFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func checkpointExpired() -> Bool { lock.lock(); defer { lock.unlock() }; return expired }

    func releaseHelpers() {
        var retained: [ConfinedScratchDirs] = []
        lock.lock()
        if let first { retained.append(first) }
        if let second { retained.append(second) }
        first = nil; second = nil
        lock.unlock()
        retained.removeAll()
    }

    deinit {
        // Worker captures prevent entry here until their effects have ended.
        // Drop helpers before releasing the enclosing ScratchDirs owner.
        first = nil
        second = nil
    }
}
