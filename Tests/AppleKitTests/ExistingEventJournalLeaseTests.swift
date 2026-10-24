import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

private final class EventLeaseBundleMarker: NSObject {}

@Suite("Existing event journal leases")
struct ExistingEventJournalLeaseTests {
    private let scratch = ScratchDirs("existing-event-lease")
    private typealias Lease = ExistingEventJournalLease

    private struct Fixture {
        let root: URL
        let id: UUID
        var stream: URL { root.appendingPathComponent(id.uuidString.lowercased()) }
        func file(_ name: String) -> URL { stream.appendingPathComponent(name) }
    }

    private func fixture(journal: Bool = true) throws -> Fixture {
        let value = Fixture(root: try scratch.directory(), id: UUID())
        try FileManager.default.createDirectory(at: value.stream, withIntermediateDirectories: false)
        #expect(chmod(value.root.path, 0o700) == 0)
        #expect(chmod(value.stream.path, 0o700) == 0)
        for name in ["lock", "state.sqlite"] + (journal ? ["state.sqlite-journal"] : []) {
            try Data().write(to: value.file(name))
            #expect(chmod(value.file(name).path, 0o600) == 0)
        }
        return value
    }

    private func acquire(_ fixture: Fixture) throws -> Lease {
        try Lease.acquire(root: fixture.root.path, streamID: fixture.id)
    }

    @Test("Existing state is leased without changing file bytes or inventory", arguments: [true, false])
    func validExistingState(journal: Bool) throws {
        let f = try fixture(journal: journal)
        let bytes = Data([0, 1, 2, 255])
        try bytes.write(to: f.file("state.sqlite"))
        let before = try FileManager.default.contentsOfDirectory(atPath: f.stream.path).sorted()
        let lease = try acquire(f)
        try lease.validate()
        try lease.validate()
        #expect(try Data(contentsOf: f.file("state.sqlite")) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.stream.path).sorted() == before)
        withExtendedLifetime(lease) {}
    }

    @Test("Missing root and stream are not created")
    func missingDirectories() throws {
        let parent = try scratch.directory()
        let missing = parent.appendingPathComponent("missing")
        #expect(throws: Lease.Failure.unavailable) {
            try Lease.acquire(root: missing.path, streamID: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(chmod(parent.path, 0o700) == 0)
        #expect(throws: Lease.Failure.unavailable) {
            try Lease.acquire(root: parent.path, streamID: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test("Missing required file stays missing", arguments: ["lock", "state.sqlite"])
    func missingRequiredFile(name: String) throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.file(name))
        #expect(throws: Lease.Failure.unavailable) { try acquire(f) }
        #expect(!FileManager.default.fileExists(atPath: f.file(name).path))
    }

    @Test("Nonzero lock is refused unchanged")
    func nonzeroLock() throws {
        let f = try fixture()
        let bytes = Data([7])
        try bytes.write(to: f.file("lock"))
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        #expect(try Data(contentsOf: f.file("lock")) == bytes)
    }

    @Test("Exact modes are required", arguments: ["root", "stream", "lock", "state.sqlite", "state.sqlite-journal"])
    func modeRejected(name: String) throws {
        let f = try fixture()
        let path = name == "root" ? f.root : name == "stream" ? f.stream : f.file(name)
        #expect(chmod(path.path, name == "root" || name == "stream" ? 0o750 : 0o640) == 0)
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
    }

    @Test("Symlink files are refused", arguments: ["lock", "state.sqlite", "state.sqlite-journal"])
    func symlinkRejected(name: String) throws {
        let f = try fixture()
        let target = try scratch.directory().appendingPathComponent("target")
        try Data([42]).write(to: target)
        try FileManager.default.removeItem(at: f.file(name))
        try FileManager.default.createSymbolicLink(at: f.file(name), withDestinationURL: target)
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        #expect(try Data(contentsOf: target) == Data([42]))
    }

    @Test("Hard links are refused", arguments: ["lock", "state.sqlite", "state.sqlite-journal"])
    func hardLinkRejected(name: String) throws {
        let f = try fixture()
        let alias = try scratch.directory().appendingPathComponent("alias")
        #expect(link(f.file(name).path, alias.path) == 0)
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
    }

    @Test("Unexpected entries are refused without deletion", arguments: ["state.sqlite-wal", "extra"])
    func unexpectedEntry(name: String) throws {
        let f = try fixture()
        try Data([9]).write(to: f.file(name))
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        #expect(try Data(contentsOf: f.file(name)) == Data([9]))
    }

    @Test("Lock contention is immediate and last reference releases the lease")
    func contentionAndLifetime() throws {
        let f = try fixture()
        var lease: Lease? = try acquire(f)
        var retained = lease
        lease = nil
        let start = ContinuousClock.now
        #expect(throws: Lease.Failure.busy) { try acquire(f) }
        #expect(start.duration(to: .now) < .seconds(1))
        try retained?.validate()
        retained = nil
        try acquire(f).validate()
    }

    @Test("A failed inventory check releases the lock")
    func failureCleanup() throws {
        let f = try fixture()
        try Data().write(to: f.file("extra"))
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        try FileManager.default.removeItem(at: f.file("extra"))
        try acquire(f).validate()
    }

    @Test("Replacement of a leased file is detected", arguments: ["lock", "state.sqlite", "state.sqlite-journal"])
    func replacement(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        let archive = try scratch.directory().appendingPathComponent("original")
        try FileManager.default.moveItem(at: f.file(name), to: archive)
        try Data().write(to: f.file(name))
        #expect(chmod(f.file(name).path, 0o600) == 0)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Directory symlinks are refused", arguments: ["root", "stream"])
    func directorySymlink(name: String) throws {
        let f = try fixture()
        let path = name == "root" ? f.root : f.stream
        let saved = try scratch.directory().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: path, to: saved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: saved)
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
    }

    @Test("Directory replacement is detected", arguments: ["root", "stream"])
    func directoryReplacement(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        let path = name == "root" ? f.root : f.stream
        let saved = try scratch.directory().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: path, to: saved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(chmod(path.path, 0o700) == 0)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("FIFO lock is refused without opening it")
    func fifoLock() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.file("lock"))
        #expect(mkfifo(f.file("lock").path, 0o600) == 0)
        let start = ContinuousClock.now
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("Metadata changes during a lease are refused", arguments: ["root", "stream", "lock", "state.sqlite", "state.sqlite-journal"])
    func permissionsAfterAcquisition(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        let path = name == "root" ? f.root : name == "stream" ? f.stream : f.file(name)
        #expect(chmod(path.path, name == "root" || name == "stream" ? 0o750 : 0o640) == 0)
        #expect(throws: Lease.Failure.unsafeState) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Noncanonical paths are refused before opening", arguments: ["relative", "/tmp/../tmp", "/tmp\0ignored", "/tmp/", "/tmp//entry", "/tmp/./entry"])
    func invalidPath(path: String) {
        #expect(throws: Lease.Failure.unsafeState) { try Lease.acquire(root: path, streamID: UUID()) }
    }

    @Test("Directory ACL entries cannot bypass private mode checks", arguments: ["root", "stream"])
    func directoryACL(name: String) throws {
        let f = try fixture()
        let path = name == "root" ? f.root : f.stream
        try addACL(path)
        var metadata = stat()
        try #require(lstat(path.path, &metadata) == 0)
        #expect(metadata.st_mode & 0o7777 == 0o700)
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
    }

    private func addACL(_ path: URL) throws {
        var acl: acl_t? = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let validEntry = try #require(entry)
        try #require(acl_set_tag_type(validEntry, ACL_EXTENDED_ALLOW) == 0)
        var principal = UUID().uuid
        try #require(acl_set_qualifier(validEntry, &principal) == 0)
        try #require(acl_set_permset_mask_np(validEntry, UInt64(ACL_SEARCH.rawValue)) == 0)
        try #require(acl_set_file(path.path, ACL_TYPE_EXTENDED, acl) == 0)
    }

    @Test("Physical absolute paths are accepted without Foundation normalization")
    func physicalPath() throws {
        let f = try fixture()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(f.root.path, &buffer) != nil)
        let physical = String(cString: buffer)
        let lease = try Lease.acquire(root: physical, streamID: f.id)
        try lease.validate()
        withExtendedLifetime(lease) {}
    }

    @Test("A missing retained object is a changed lease", arguments: ["root", "stream", "lock", "state.sqlite", "state.sqlite-journal"])
    func missingAfterAcquisition(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        let path = name == "root" ? f.root : name == "stream" ? f.stream : f.file(name)
        let saved = try scratch.directory().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: path, to: saved)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Unlinked retained files are changed leases", arguments: ["lock", "state.sqlite", "state.sqlite-journal"])
    func unlinkedAfterAcquisition(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        try #require(unlink(f.file(name).path) == 0)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Unlinking and replacing the held lock is a changed lease")
    func unlinkedLockReplacement() throws {
        let f = try fixture()
        let lease = try acquire(f)
        try #require(unlink(f.file("lock").path) == 0)
        try Data().write(to: f.file("lock"))
        try #require(chmod(f.file("lock").path, 0o600) == 0)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Removing the containing fixture is a changed lease", arguments: ["root", "stream"])
    func removedDirectoryAfterAcquisition(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        try FileManager.default.removeItem(at: name == "root" ? f.root : f.stream)
        #expect(throws: Lease.Failure.changed) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Special permission bits are refused", arguments: ["root", "stream", "lock", "state.sqlite", "state.sqlite-journal"])
    func specialModeBits(name: String) throws {
        let f = try fixture()
        let directory = name == "root" || name == "stream"
        let path = name == "root" ? f.root : name == "stream" ? f.stream : f.file(name)
        for mode: mode_t in directory ? [0o1700, 0o2700] : [0o4600] {
            try #require(chmod(path.path, mode) == 0)
            var metadata = stat()
            try #require(lstat(path.path, &metadata) == 0)
            try #require(metadata.st_mode & 0o7777 == mode)
            #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
        }
    }

    @Test("ACLs added to retained directories invalidate the lease", arguments: ["root", "stream"])
    func aclAfterAcquisition(name: String) throws {
        let f = try fixture()
        let lease = try acquire(f)
        try addACL(name == "root" ? f.root : f.stream)
        #expect(throws: Lease.Failure.unsafeState) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("A lock growing during a lease is refused")
    func nonzeroLockAfterAcquisition() throws {
        let f = try fixture()
        let lease = try acquire(f)
        try Data([7]).write(to: f.file("lock"))
        #expect(throws: Lease.Failure.unsafeState) { try lease.validate() }
        withExtendedLifetime(lease) {}
    }

    @Test("Full-length unexpected directory entries are safely refused")
    func longEntry() throws {
        let f = try fixture()
        let name = String(repeating: "x", count: Int(MAXNAMLEN))
        try Data([9]).write(to: f.file(name))
        #expect(throws: Lease.Failure.unsafeState) { try acquire(f) }
    }

    @Test("A short directory record at a guard page needs no full struct read")
    func shortDirectoryRecord() throws {
        let pageSize = Int(getpagesize())
        let mapping = mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANON, -1, 0)
        let memory = try #require(mapping)
        try #require(memory != MAP_FAILED)
        defer { munmap(memory, pageSize * 2) }
        try #require(mprotect(memory.advanced(by: pageSize), pageSize, PROT_NONE) == 0)
        let offset = try #require(MemoryLayout<dirent>.offset(of: \.d_name))
        let lengthOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_namlen))
        let recordOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_reclen))
        let recordSize = (offset + 5 + 7) & ~7
        let record = memory.advanced(by: pageSize - recordSize)
        record.initializeMemory(as: UInt8.self, repeating: 0, count: recordSize)
        record.storeBytes(of: UInt16(recordSize), toByteOffset: recordOffset, as: UInt16.self)
        record.storeBytes(of: UInt16(4), toByteOffset: lengthOffset, as: UInt16.self)
        for (index, byte) in Array("lock".utf8).enumerated() {
            record.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self)
        }
        let entry = UnsafePointer(record.assumingMemoryBound(to: dirent.self))
        #expect(try Lease.directoryEntryName(entry) == "lock")
        record.storeBytes(of: UInt16(recordSize - offset), toByteOffset: lengthOffset, as: UInt16.self)
        #expect(throws: Lease.Failure.unsafeState) { try Lease.directoryEntryName(entry) }
        record.storeBytes(of: UInt16(4), toByteOffset: lengthOffset, as: UInt16.self)
        record.storeBytes(of: UInt8(1), toByteOffset: offset + 4, as: UInt8.self)
        #expect(throws: Lease.Failure.unsafeState) { try Lease.directoryEntryName(entry) }
    }

    @Test("Filesystem policy requires local APFS with ownership enforcement")
    func filesystemPolicy() throws {
        try Lease.requireFilesystem(type: "apfs", flags: UInt32(MNT_LOCAL))
        #expect(throws: Lease.Failure.unsafeState) {
            try Lease.requireFilesystem(type: "apfs", flags: UInt32(MNT_LOCAL | MNT_IGNORE_OWNERSHIP))
        }
        #expect(throws: Lease.Failure.unsafeState) { try Lease.requireFilesystem(type: "apfs", flags: 0) }
        #expect(throws: Lease.Failure.unsafeState) { try Lease.requireFilesystem(type: "hfs", flags: UInt32(MNT_LOCAL)) }
    }

    @Test("A child verifies descriptor closure and last-reference lifetime")
    func descriptorLifetime() throws {
        try runProbe(fixture(), mode: "event-fd-success", expected: 0)
    }

    @Test("A child verifies failed acquisition closes all descriptors", arguments: ["missing-stream", "missing-lock", "missing-main", "root-mode", "stream-mode", "lock-mode", "main-mode", "journal-mode", "root-acl", "stream-acl", "extra"])
    func failedAcquisitionDescriptors(kind: String) throws {
        var f = try fixture()
        switch kind {
        case "missing-stream": f = Fixture(root: f.root, id: UUID())
        case "missing-lock": try FileManager.default.removeItem(at: f.file("lock"))
        case "missing-main": try FileManager.default.removeItem(at: f.file("state.sqlite"))
        case "root-mode": try #require(chmod(f.root.path, 0o750) == 0)
        case "stream-mode": try #require(chmod(f.stream.path, 0o750) == 0)
        case "lock-mode": try #require(chmod(f.file("lock").path, 0o640) == 0)
        case "main-mode": try #require(chmod(f.file("state.sqlite").path, 0o640) == 0)
        case "journal-mode": try #require(chmod(f.file("state.sqlite-journal").path, 0o640) == 0)
        case "root-acl": try addACL(f.root)
        case "stream-acl": try addACL(f.stream)
        case "extra": try Data().write(to: f.file("extra"))
        default: Issue.record("unknown synthetic fixture")
        }
        try runProbe(f, mode: kind.hasPrefix("missing-") ? "event-fd-unavailable" : "event-fd-unsafe", expected: 0)
    }

    @Test("A separate process is busy until the owner releases the lease")
    func distinctProcess() throws {
        let f = try fixture()
        var lease: Lease? = try acquire(f)
        try runProbe(f, expected: 44)
        try lease?.validate()
        lease = nil
        try runProbe(f, expected: 0)
    }

    private func runProbe(_ fixture: Fixture, mode: String = "event-lock-probe", expected: Int32) throws {
        let bundle = Bundle(for: EventLeaseBundleMarker.self).bundleURL
        let binary = bundle.deletingLastPathComponent().appendingPathComponent("AutomationJournalProbe")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process()
        process.executableURL = binary
        process.arguments = [mode, fixture.stream.path]
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(!process.isRunning, "owned lease probe exceeded deadline")
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == expected)
    }
}
