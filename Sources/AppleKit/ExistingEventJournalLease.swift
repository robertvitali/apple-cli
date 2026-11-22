import Darwin
import Foundation

/// Holds an existing private event journal without provisioning or repairing it.
package final class ExistingEventJournalLease {
    package enum Failure: Error, Equatable {
        case unavailable
        case unsafeState
        case busy
        case changed
        case systemCall(String, Int32)
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
        }
    }

    private let root: String
    private let streamName: String
    private let rootFD: Int32
    private let streamFD: Int32
    private let lockFD: Int32
    private let rootIdentity: Identity
    private let streamIdentity: Identity
    private let lockIdentity: Identity
    private let mainIdentity: Identity
    private let journalIdentity: Identity?

    private init(root: String, streamName: String, rootFD: Int32, streamFD: Int32,
                 lockFD: Int32, rootIdentity: Identity, streamIdentity: Identity,
                 lockIdentity: Identity, mainIdentity: Identity, journalIdentity: Identity?) {
        self.root = root
        self.streamName = streamName
        self.rootFD = rootFD
        self.streamFD = streamFD
        self.lockFD = lockFD
        self.rootIdentity = rootIdentity
        self.streamIdentity = streamIdentity
        self.lockIdentity = lockIdentity
        self.mainIdentity = mainIdentity
        self.journalIdentity = journalIdentity
    }

    deinit {
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        close(streamFD)
        close(rootFD)
    }

    /// Does not create paths, repair permissions, open SQLite, or wait for a lock.
    /// Ancestors of root are trusted host paths; its final component is no-follow.
    package static func acquire(root: String, streamID: UUID) throws -> ExistingEventJournalLease {
        guard isAbsoluteDirectoryPath(root, allowRoot: false) else { throw Failure.unsafeState }
        let rootStat = try pathStat(parent: AT_FDCWD, name: root)
        try requireDirectory(rootStat)
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw pathFailure("open-root") }
        var transferred = false
        defer { if !transferred { close(rootFD) } }
        try validateDirectory(rootFD, matching: Identity(rootStat))

        let streamName = streamID.uuidString.lowercased()
        let streamStat = try pathStat(parent: rootFD, name: streamName)
        try requireDirectory(streamStat)
        guard streamStat.st_dev == rootStat.st_dev else { throw Failure.unsafeState }
        let streamFD = openat(rootFD, streamName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard streamFD >= 0 else { throw pathFailure("open-stream") }
        defer { if !transferred { close(streamFD) } }
        try validateDirectory(streamFD, matching: Identity(streamStat))

        let lockStat = try pathStat(parent: streamFD, name: "lock")
        try requireFile(lockStat, empty: true)
        let lockFD = openat(streamFD, "lock", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard lockFD >= 0 else { throw pathFailure("open-lock") }
        defer { if !transferred { close(lockFD) } }
        try validateLock(lockFD, matching: Identity(lockStat))
        try lockStream(lockFD)
        defer { if !transferred { _ = flock(lockFD, LOCK_UN) } }

        // No state-file inspection occurs before the exclusive lease.
        try validatePaths(root: root, streamName: streamName, rootFD: rootFD,
                          streamFD: streamFD, lockFD: lockFD,
                          rootIdentity: Identity(rootStat), streamIdentity: Identity(streamStat),
                          lockIdentity: Identity(lockStat))
        let files = try inspectFiles(streamFD)
        guard files["lock"] == Identity(lockStat) else { throw Failure.changed }
        guard let mainIdentity = files["state.sqlite"] else { throw Failure.unavailable }
        let result = ExistingEventJournalLease(
            root: root, streamName: streamName, rootFD: rootFD, streamFD: streamFD,
            lockFD: lockFD, rootIdentity: Identity(rootStat), streamIdentity: Identity(streamStat),
            lockIdentity: Identity(lockStat), mainIdentity: mainIdentity,
            journalIdentity: files["state.sqlite-journal"]
        )
        transferred = true
        return result
    }

    /// Detects ordinary replacement and metadata drift, not hostile same-UID races.
    /// Journal creation/deletion transitions are intentionally not part of this API.
    package func validate() throws {
        guard try validatedJournalIdentity() == journalIdentity else { throw Failure.changed }
    }

    private func validatedJournalIdentity() throws -> Identity? {
        do {
            try Self.validatePaths(root: root, streamName: streamName, rootFD: rootFD,
                                   streamFD: streamFD, lockFD: lockFD,
                                   rootIdentity: rootIdentity, streamIdentity: streamIdentity,
                                   lockIdentity: lockIdentity)
            let files = try Self.inspectFiles(streamFD)
            guard files["lock"] == lockIdentity, files["state.sqlite"] == mainIdentity else { throw Failure.changed }
            return files["state.sqlite-journal"]
        } catch Failure.unavailable {
            // Acquisition distinguishes unprovisioned state; a retained object disappearing is drift.
            throw Failure.changed
        }
    }

    private static func validatePaths(root: String, streamName: String, rootFD: Int32,
                                      streamFD: Int32, lockFD: Int32, rootIdentity: Identity,
                                      streamIdentity: Identity, lockIdentity: Identity) throws {
        try validateDirectory(rootFD, matching: rootIdentity)
        try validateDirectory(streamFD, matching: streamIdentity)
        let rootNow = try pathStat(parent: AT_FDCWD, name: root)
        let streamNow = try pathStat(parent: rootFD, name: streamName)
        let lockNow = try pathStat(parent: streamFD, name: "lock")
        try requireDirectory(rootNow)
        try requireDirectory(streamNow)
        try requireFile(lockNow, empty: true)
        guard Identity(rootNow) == rootIdentity, Identity(streamNow) == streamIdentity,
              Identity(lockNow) == lockIdentity else { throw Failure.changed }
        // An unlinked held lock has zero links. Classify its missing/replaced
        // pathname first, then validate metadata on the still-retained descriptor.
        try validateLock(lockFD, matching: lockIdentity)
    }

    private static func inspectFiles(_ directoryFD: Int32, complete: Bool = true, empty: Bool = false) throws -> [String: Identity] {
        try readFiles(directoryFD, complete: complete, empty: empty, record: Identity.init)
    }

    private static func readFiles<T>(_ directoryFD: Int32, complete: Bool, empty: Bool,
                                     record: (stat) -> T) throws -> [String: T] {
        var result: [String: T] = [:]
        try forEachEntry(in: directoryFD) { name in
            guard name == "lock" || name == "state.sqlite" || name == "state.sqlite-journal",
                  result[name] == nil else { throw Failure.unsafeState }
            let value = try pathStat(parent: directoryFD, name: name)
            try requireFile(value, empty: empty || name == "lock")
            result[name] = record(value)
        }
        if complete && (result["lock"] == nil || result["state.sqlite"] == nil) { throw Failure.unavailable }
        return result
    }

    private static func forEachEntry(in directoryFD: Int32, _ body: (String) throws -> Void) throws {
        // dup would share the directory position and make repeated checks incomplete.
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scanFD >= 0 else { throw Failure.systemCall("open-inventory", errno) }
        guard let directory = fdopendir(scanFD) else {
            let code = errno
            close(scanFD)
            throw Failure.systemCall("fdopendir", code)
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Failure.systemCall("readdir", errno) }
                break
            }
            let name = try directoryEntryName(UnsafePointer(entry))
            if name == "." || name == ".." { continue }
            try body(name)
        }
    }

    /// readdir returns variable-sized records, not a full Swift dirent value.
    /// Read only the name bytes belonging to this record; never copy d_name.
    static func directoryEntryName(_ entry: UnsafePointer<dirent>) throws -> String {
        guard let offset = MemoryLayout<dirent>.offset(of: \.d_name) else {
            throw Failure.unsafeState
        }
        let length = Int(entry.pointee.d_namlen)
        let recordLength = Int(entry.pointee.d_reclen)
        guard offset < recordLength, length < recordLength - offset else {
            throw Failure.unsafeState
        }
        let start = UnsafeRawPointer(entry).advanced(by: offset)
        guard start.load(fromByteOffset: length, as: UInt8.self) == 0 else {
            throw Failure.unsafeState
        }
        return String(decoding: UnsafeRawBufferPointer(start: start, count: length), as: UTF8.self)
    }

    private static func pathStat(parent: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw pathFailure("fstatat")
        }
        return value
    }

    private static func pathFailure(_ operation: String) -> Failure {
        let code = errno
        if code == ENOENT { return .unavailable }
        if code == ELOOP || code == ENOTDIR { return .unsafeState }
        return .systemCall(operation, code)
    }

    private static func requireDirectory(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid(),
              value.st_mode & 0o7777 == 0o700 else { throw Failure.unsafeState }
    }

    private static func requireFile(_ value: stat, empty: Bool) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_mode & 0o7777 == 0o600, value.st_nlink == 1,
              !empty || value.st_size == 0 else { throw Failure.unsafeState }
    }

    private static func validateDirectory(_ fd: Int32, matching identity: Identity) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw Failure.systemCall("fstat-directory", errno) }
        try requireDirectory(value)
        guard Identity(value) == identity else { throw Failure.changed }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw Failure.systemCall("fstatfs", errno) }
        let name = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        try requireFilesystem(type: name, flags: filesystem.f_flags)
        // Mode bits alone do not exclude access granted by an extended ACL.
        let maybeACL: acl_t? = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        guard let acl = maybeACL else {
            let code = errno
            // On Darwin an existing descriptor without an extended ACL returns ENOENT.
            // Check that this is still the owned directory, not a missing object.
            guard code == ENOENT else { throw Failure.systemCall("acl_get_fd_np", code) }
            var current = stat()
            guard fstat(fd, &current) == 0 else { throw Failure.systemCall("fstat-directory", errno) }
            try requireDirectory(current)
            guard Identity(current) == identity else { throw Failure.changed }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw Failure.unsafeState }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        // Darwin returns -1/EINVAL for the first entry of a valid empty ACL.
        guard result == -1, errno == EINVAL else { throw Failure.unsafeState }
    }

    private static func validateLock(_ fd: Int32, matching identity: Identity) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw Failure.systemCall("fstat-lock", errno) }
        try requireFile(value, empty: true)
        guard Identity(value) == identity else { throw Failure.changed }
    }

    static func requireFilesystem(type: String, flags: UInt32) throws {
        guard type == "apfs", flags & UInt32(MNT_LOCAL) != 0,
              flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            throw Failure.unsafeState
        }
    }
}

extension ExistingEventJournalLease {
    package enum RegistryAccess { case existing, provision }

    /// Borrow the private registry directory under its nonblocking exclusive mutex.
    /// Call the witness immediately before each namespace change and after any wait.
    /// Only provisioning creates the directory or initializes a mutex in an empty directory.
    package static func withRegistryLock<T>(
        parent: String, directory: String, access: RegistryAccess = .existing,
        _ body: (Int32, () throws -> Void) throws -> T
    ) throws -> T {
        guard isAbsoluteDirectoryPath(parent, allowRoot: true),
              !directory.isEmpty, directory != ".", directory != "..",
              !directory.utf8.contains(47), !directory.utf8.contains(0) else { throw Failure.unsafeState }

        let flags = O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let parentFD = open(parent, flags)
        guard parentFD >= 0 else { throw pathFailure("open-registry-parent") }
        defer { close(parentFD) }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0 else { throw pathFailure("fstat-registry-parent") }
        let parentID = Identity(parentStat)
        func checkParent() throws {
            // A relative lookup alone would continue to succeed in a renamed parent.
            do {
                let named = try pathStat(parent: AT_FDCWD, name: parent)
                guard named.st_mode & S_IFMT == S_IFDIR, Identity(named) == parentID else { throw Failure.changed }
            } catch Failure.unavailable { throw Failure.changed }
        }
        try checkParent()
        if access == .provision, mkdirat(parentFD, directory, 0o700) != 0, errno != EEXIST {
            throw pathFailure("create-registry")
        }
        let root = try pathStat(parent: parentFD, name: directory)
        try requireDirectory(root)
        let rootID = Identity(root)
        let rootFD = openat(parentFD, directory, flags)
        guard rootFD >= 0 else { throw pathFailure("open-registry") }
        defer { close(rootFD) }
        func checkDirectory() throws {
            try checkParent()
            try validateDirectory(rootFD, matching: rootID)
            do {
                let named = try pathStat(parent: parentFD, name: directory)
                try requireDirectory(named)
                guard Identity(named) == rootID else { throw Failure.changed }
            } catch Failure.unavailable { throw Failure.changed }
        }
        try checkDirectory()
        if access == .provision, fsync(parentFD) != 0 { throw pathFailure("sync-registry-parent") }
        let lockFD = try registryMutex(in: rootFD, access: access, checkDirectory: checkDirectory)
        defer { close(lockFD) }
        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0 else { throw pathFailure("fstat-registry-lock") }
        let lockID = Identity(lockStat)
        try validateLock(lockFD, matching: lockID)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Failure.systemCall("flock-registry", code)
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        func check() throws {
            try checkDirectory()
            do {
                guard Identity(try pathStat(parent: rootFD, name: "registry.lock")) == lockID else {
                    throw Failure.changed
                }
            } catch Failure.unavailable { throw Failure.changed }
            try validateLock(lockFD, matching: lockID)
        }
        try check()
        let result = try body(rootFD, check)
        try check()
        return result
    }

    private static func isAbsoluteDirectoryPath(_ path: String, allowRoot: Bool) -> Bool {
        if path == "/" { return allowRoot }
        let parts = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return path.utf8.first == 47 && !path.utf8.contains(0)
            && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func registryMutex(in rootFD: Int32, access: RegistryAccess,
                                      checkDirectory: () throws -> Void) throws -> Int32 {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        func existing() throws -> Int32 {
            let named = try pathStat(parent: rootFD, name: "registry.lock")
            try requireFile(named, empty: true)
            let fd = openat(rootFD, "registry.lock", flags)
            guard fd >= 0 else { throw pathFailure("open-registry-lock") }
            do { try validateLock(fd, matching: Identity(named)) }
            catch { close(fd); throw error }
            return fd
        }
        do { return try existing() }
        catch Failure.unavailable where access == .provision {
            // An occupied registry may be racing a creator. Reopen its mutex but
            // never manufacture a replacement lock alongside existing streams.
            let scan = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0 else { throw pathFailure("scan-registry") }
            guard let entries = fdopendir(scan) else {
                let code = errno
                close(scan)
                throw Failure.systemCall("fdopendir-registry", code)
            }
            defer { closedir(entries) }
            while true {
                errno = 0
                guard let entry = readdir(entries) else {
                    guard errno == 0 else { throw pathFailure("readdir-registry") }
                    break
                }
                let name = try directoryEntryName(UnsafePointer(entry))
                if name != "." && name != ".." { return try existing() }
            }
            try checkDirectory()
            let fd = openat(rootFD, "registry.lock", flags | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 { return fd }
            if errno == EEXIST { return try existing() }
            throw pathFailure("create-registry-lock")
        }
    }
}

extension ExistingEventJournalLease {
    package static let registrySlotLimit = 4

    package struct RegistrySlot: Equatable {
        package enum State: String {
            case active = ""
            case creating = ".creating-"
            case retiring = ".retiring-"
        }

        package let id: UUID
        package var state: State
        package var name: String { state.rawValue + id.uuidString.lowercased() }
        private let device: dev_t
        private let inode: ino_t
        private let owner: uid_t
        private let mode: mode_t

        package init(id: UUID, state: State, metadata: stat) {
            self.id = id
            self.state = state
            device = metadata.st_dev
            inode = metadata.st_ino
            owner = metadata.st_uid
            mode = metadata.st_mode
        }
    }

    /// Call under the registry mutex. Inspection may report a damaged slot as
    /// unavailable. Provisioning requires all existing slots to be private directories.
    package static func registrySlots(in fd: Int32, access: RegistryAccess) throws -> [UUID: RegistrySlot] {
        var root = stat()
        guard fstat(fd, &root) == 0 else { throw pathFailure("fstat-registry") }
        var slots: [UUID: RegistrySlot] = [:]
        try forEachEntry(in: fd) { name in
            if name == "registry.lock" { return }
            let state: RegistrySlot.State
            if name.hasPrefix(".creating-") { state = .creating }
            else if name.hasPrefix(".retiring-") { state = .retiring }
            else { state = .active }
            let suffix = String(name.dropFirst(state.rawValue.count))
            guard slots.count < registrySlotLimit,
                  let id = UUID(uuidString: suffix), id.uuidString.lowercased() == suffix,
                  slots[id] == nil else { throw Failure.unsafeState }
            let metadata = try pathStat(parent: fd, name: name)
            if access == .provision {
                try requireDirectory(metadata)
                guard metadata.st_dev == root.st_dev else { throw Failure.unsafeState }
            }
            slots[id] = RegistrySlot(id: id, state: state, metadata: metadata)
        }
        return slots
    }
}

extension ExistingEventJournalLease {
    /// The single SQLite connection calls this synchronously while holding its
    /// exclusive stream lease. Only its VFS reports successful create and delete.
    package final class Recovery {
        package enum JournalEvent { case check, created, deleted }

        private final class PinnedFile {
            let fd: Int32
            let identity: Identity

            init(directoryFD: Int32, identity: Identity, empty: Bool) throws {
                let fd = openat(directoryFD, "state.sqlite-journal", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else {
                    if errno == ENOENT { throw Failure.changed }
                    throw pathFailure("open-journal")
                }
                do {
                    var metadata = stat()
                    guard fstat(fd, &metadata) == 0 else { throw pathFailure("fstat-journal") }
                    guard Identity(metadata) == identity else { throw Failure.changed }
                    try requireFile(metadata, empty: empty)
                } catch {
                    close(fd)
                    throw error
                }
                self.fd = fd
                self.identity = identity
            }

            func requireEmpty() throws {
                var metadata = stat()
                guard fstat(fd, &metadata) == 0 else { throw pathFailure("fstat-journal") }
                guard metadata.st_size == 0 else { throw Failure.changed }
            }

            deinit { close(fd) }
        }

        private let directoryFD: Int32
        // The closure retains the lease and its borrowed directory descriptor.
        private let namedJournal: () throws -> Identity?
        private var journal: PinnedFile?

        init(directoryFD: Int32, initial: Identity?, namedJournal: @escaping () throws -> Identity?) throws {
            self.directoryFD = directoryFD
            self.namedJournal = namedJournal
            guard try namedJournal() == initial else { throw Failure.changed }
            if let initial { journal = try PinnedFile(directoryFD: directoryFD, identity: initial, empty: false) }
            try validate()
        }

        package static func acquire(root: String, streamID: UUID) throws -> Recovery {
            let lease = try ExistingEventJournalLease.acquire(root: root, streamID: streamID)
            return try Recovery(directoryFD: lease.streamFD, initial: lease.journalIdentity,
                                namedJournal: lease.validatedJournalIdentity)
        }

        package func validate() throws {
            _ = try observe(.check)
        }

        /// Returns whether the journal exists following the reported operation.
        package func observe(_ event: JournalEvent) throws -> Bool {
            let named = try namedJournal()
            switch event {
            case .check:
                guard journal?.identity == named else { throw Failure.changed }
            case .created:
                guard journal == nil, let named else { throw Failure.changed }
                let new = try PinnedFile(directoryFD: directoryFD, identity: named, empty: true)
                guard try namedJournal() == named else { throw Failure.changed }
                try new.requireEmpty()
                journal = new
            case .deleted:
                guard named == nil, let previous = journal else { throw Failure.changed }
                var metadata = stat()
                guard fstat(previous.fd, &metadata) == 0 else { throw pathFailure("fstat-deleted-journal") }
                guard Identity(metadata) == previous.identity, metadata.st_nlink == 0 else { throw Failure.changed }
                journal = nil
            }
            return journal != nil
        }

        package func synchronize() throws {
            try synchronize(syncJournal: { fd in
                guard fcntl(fd, F_FULLFSYNC) == 0 else { throw Failure.systemCall("sync-journal", errno) }
            }, syncDirectory: { fd in
                guard fsync(fd) == 0 else { throw Failure.systemCall("sync-directory", errno) }
            })
        }

        func synchronize(syncJournal: (Int32) throws -> Void, syncDirectory: (Int32) throws -> Void) throws {
            func validateClean() throws {
                try validate()
                try journal?.requireEmpty()
            }
            try validateClean()
            if let journal {
                try syncJournal(journal.fd)
                try validateClean()
            }
            try syncDirectory(directoryFD)
            try validateClean()
        }
    }
}

extension ExistingEventJournalLease {
    package enum ProvisionFailure: Error { case full }
    package enum ProvisionStage {
        case registryLocked, directoryCreated, lockCreated, mainCreated, filesCreated, published
    }

    package final class ProvisionedStream {
        package let id: UUID
        private var lease: ExistingEventJournalLease?

        fileprivate init(id: UUID, lease: ExistingEventJournalLease) {
            self.id = id
            self.lease = lease
        }

        /// Retain the same exclusive lock across publication and the first SQLite open.
        package func initializationLease() throws -> Recovery {
            guard let lease else { throw Failure.changed }
            self.lease = nil
            try lease.validateEmptyStore()
            return try Recovery(directoryFD: lease.streamFD, initial: lease.journalIdentity,
                                namedJournal: lease.validatedJournalIdentity)
        }
    }

    private func validateEmptyStore() throws {
        try validate()
        guard let journalIdentity,
              try Self.inspectFiles(streamFD, empty: true) == [
                "lock": lockIdentity, "state.sqlite": mainIdentity, "state.sqlite-journal": journalIdentity
              ] else { throw Failure.changed }
    }

    /// After assignment, an interrupted start leaves its exact stream available for inspection.
    package static func provision(
        parent: String, registry: String, assigned: (UUID) -> Void,
        checkpoint: (ProvisionStage) throws -> Void = { _ in }
    ) throws -> ProvisionedStream {
        try withRegistryLock(parent: parent, directory: registry, access: .provision) { rootFD, checkRoot in
            var slots = try registrySlots(in: rootFD, access: .provision)
            guard slots.count < registrySlotLimit else { throw ProvisionFailure.full }
            func checkSlots() throws {
                try checkRoot()
                guard try registrySlots(in: rootFD, access: .provision) == slots else { throw Failure.changed }
            }
            try checkpoint(.registryLocked)
            try checkSlots()
            let id = UUID()
            let active = id.uuidString.lowercased()
            let staging = ".creating-" + active
            guard slots[id] == nil else { throw Failure.changed }
            guard mkdirat(rootFD, staging, 0o700) == 0 else { throw pathFailure("create-stream") }
            let directory: stat
            do { directory = try pathStat(parent: rootFD, name: staging) }
            catch { assigned(id); throw error }
            assigned(id)
            try requireDirectory(directory)
            let streamID = Identity(directory)
            slots[id] = RegistrySlot(id: id, state: .creating, metadata: directory)
            let streamFD = openat(rootFD, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard streamFD >= 0 else { throw pathFailure("open-staging") }
            var transferred = false
            defer { if !transferred { close(streamFD) } }
            try validateDirectory(streamFD, matching: streamID)
            try lockStream(streamFD)
            var files = [String: Identity]()
            func checkFiles() throws {
                try checkSlots()
                try validateDirectory(streamFD, matching: streamID)
                guard try inspectFiles(streamFD, complete: false, empty: true) == files else { throw Failure.changed }
            }
            try checkFiles()
            guard fsync(rootFD) == 0 else { throw pathFailure("sync-staging-entry") }
            try checkpoint(.directoryCreated)
            try checkFiles()

            func create(_ name: String) throws -> (fd: Int32, id: Identity) {
                let fd = openat(streamFD, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw pathFailure("create-stream-file") }
                do {
                    var metadata = stat()
                    guard fstat(fd, &metadata) == 0 else { throw pathFailure("stat-stream-file") }
                    try requireFile(metadata, empty: true)
                    let identity = Identity(metadata)
                    guard Identity(try pathStat(parent: streamFD, name: name)) == identity else { throw Failure.changed }
                    files[name] = identity
                    return (fd, identity)
                } catch {
                    close(fd)
                    throw error
                }
            }

            let lock = try create("lock")
            defer { if !transferred { close(lock.fd) } }
            try lockStream(lock.fd)
            try checkpoint(.lockCreated)
            try checkFiles()
            let main = try create("state.sqlite")
            defer { close(main.fd) }
            try checkpoint(.mainCreated)
            try checkFiles()
            let journal = try create("state.sqlite-journal")
            defer { close(journal.fd) }
            try checkpoint(.filesCreated)
            try checkFiles()
            guard fsync(streamFD) == 0 else { throw pathFailure("sync-stream") }
            guard renameatx_np(rootFD, staging, rootFD, active, UInt32(RENAME_EXCL)) == 0 else {
                throw pathFailure("publish-stream")
            }
            slots[id]?.state = .active
            try checkFiles()
            guard fsync(rootFD) == 0 else { throw pathFailure("sync-registry") }
            try checkpoint(.published)
            try checkFiles()
            var root = stat()
            guard fstat(rootFD, &root) == 0 else { throw pathFailure("stat-registry") }
            guard flock(streamFD, LOCK_UN) == 0 else { throw pathFailure("unlock-stream-directory") }
            let retainedRoot = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
            guard retainedRoot >= 0 else { throw pathFailure("retain-registry") }
            let path = parent == "/" ? "/" + registry : parent + "/" + registry
            let lease = ExistingEventJournalLease(root: path, streamName: active, rootFD: retainedRoot,
                                                  streamFD: streamFD, lockFD: lock.fd,
                                                  rootIdentity: Identity(root), streamIdentity: streamID,
                                                  lockIdentity: lock.id, mainIdentity: main.id,
                                                  journalIdentity: journal.id)
            transferred = true
            try lease.validateEmptyStore()
            return ProvisionedStream(id: id, lease: lease)
        }
    }

    private static func lockStream(_ fd: Int32) throws {
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Failure.systemCall("flock", code)
        }
    }
}

extension ExistingEventJournalLease {
    package enum RegistryRequest {
        case list, preview(UUID), retire(UUID)
    }

    package enum StreamInspection<Details> {
        case active(Details), creating, retiring, busy, unavailable
    }

    package struct RegistryRecord<Details> {
        package let id: UUID
        package let status: StreamInspection<Details>
        package let files: [String]
    }

    package enum RetirementStage {
        case inventory, inspectSlot(UUID), beforeDetach, afterDetach, beforeCleanup, removedFile(String)
    }

    // atime can change during read-only inspection. A rewrite at the same inode
    // must still invalidate the observed files before a subsequent removal.
    private struct RetirementFile: Equatable {
        let identity: Identity
        let size: off_t
        let modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int

        init(_ value: stat) {
            identity = Identity(value)
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private static let creationOrder = ["lock", "state.sqlite", "state.sqlite-journal"]

    private static func retirementFiles(_ fd: Int32, phase: RegistrySlot.State) throws -> [String: RetirementFile] {
        let files = try readFiles(fd, complete: phase == .active, empty: phase == .creating,
                                  record: RetirementFile.init)
        // Creation adds these files in order. Retirement removes them in reverse.
        guard Set(files.keys) == Set(creationOrder.prefix(files.count)) else { throw Failure.unsafeState }
        return files
    }

    /// Reads metadata and performs exact requested cleanup under the registry mutex.
    /// Pending directories do not open SQLite. Only retire can rename or remove entries.
    package static func inspectRegistry<Details>(
        parent: String, registry: String, request: RegistryRequest,
        checkpoint: (RetirementStage) throws -> Void = { _ in },
        readActive: (UUID, Recovery) throws -> Details
    ) throws -> [RegistryRecord<Details>] {
        try withRegistryLock(parent: parent, directory: registry) { rootFD, checkRoot in
            var slots = try registrySlots(in: rootFD, access: .existing)
            func checkSlots() throws {
                try checkRoot()
                guard try registrySlots(in: rootFD, access: .existing) == slots else { throw Failure.changed }
            }
            try checkpoint(.inventory)
            try checkSlots()
            var registryMetadata = stat()
            guard fstat(rootFD, &registryMetadata) == 0 else { throw pathFailure("stat-registry") }
            let selected: [RegistrySlot]
            let listing: Bool
            switch request {
            case .list:
                selected = slots.values.sorted { $0.name < $1.name }
                listing = true
            case .preview(let id), .retire(let id):
                guard let slot = slots[id] else { throw Failure.unavailable }
                selected = [slot]
                listing = false
            }
            var rows: [RegistryRecord<Details>] = []
            for slot in selected {
                try checkpoint(.inspectSlot(slot.id))
                try checkSlots()
                func finishRemoval(_ fd: Int32, _ mutex: Int32?, _ state: RegistrySlot.State,
                                   _ files: [String: RetirementFile]) throws {
                    if case .retire = request {
                        try removePending(rootFD: rootFD, slot: slot, state: state, streamFD: fd,
                                          lockFD: mutex, files: files, checkSlots: checkSlots, checkpoint: checkpoint)
                        slots.removeValue(forKey: slot.id)
                    }
                }
                if slot.state == .active {
                    let root = parent == "/" ? "/" + registry : parent + "/" + registry
                    let lease: ExistingEventJournalLease
                    do { lease = try acquire(root: root, streamID: slot.id) }
                    catch {
                        if !listing { throw error }
                        rows.append(unavailableRecord(id: slot.id, error: error))
                        continue
                    }
                    var stream = stat()
                    guard fstat(lease.streamFD, &stream) == 0 else { throw pathFailure("stat-stream") }
                    guard lease.rootIdentity == Identity(registryMetadata),
                          RegistrySlot(id: slot.id, state: .active, metadata: stream) == slot else { throw Failure.changed }
                    let files = try retirementFiles(lease.streamFD, phase: .active)
                    let recovery = try Recovery(directoryFD: lease.streamFD, initial: lease.journalIdentity,
                                                namedJournal: lease.validatedJournalIdentity)
                    let details = try readActive(slot.id, recovery)
                    try lease.validate()
                    guard try retirementFiles(lease.streamFD, phase: .active) == files else { throw Failure.changed }
                    if case .retire = request {
                        try lockStream(lease.streamFD)
                        defer { _ = flock(lease.streamFD, LOCK_UN) }
                        try checkpoint(.beforeDetach)
                        try checkSlots()
                        try lease.validate()
                        guard try retirementFiles(lease.streamFD, phase: .active) == files else { throw Failure.changed }
                        var pending = slot
                        pending.state = .retiring
                        guard renameatx_np(rootFD, slot.name, rootFD, pending.name, UInt32(RENAME_EXCL)) == 0 else {
                            throw pathFailure("detach-stream")
                        }
                        slots[slot.id] = pending
                        try checkSlots()
                        guard fsync(rootFD) == 0 else { throw pathFailure("sync-detached-stream") }
                        try checkpoint(.afterDetach)
                        try finishRemoval(lease.streamFD, lease.lockFD, .retiring, files)
                    }
                    rows.append(RegistryRecord(id: slot.id, status: .active(details), files: files.keys.sorted()))
                } else {
                    do {
                        let names = try withPendingStream(rootFD: rootFD, slot: slot, checkSlots: checkSlots) { fd, mutex in
                            let files = try retirementFiles(fd, phase: slot.state)
                            guard mutex != nil || files.isEmpty else { throw Failure.unsafeState }
                            try finishRemoval(fd, mutex, slot.state, files)
                            return files.keys.sorted()
                        }
                        let status: StreamInspection<Details> = slot.state == .creating ? .creating : .retiring
                        rows.append(RegistryRecord(id: slot.id, status: status, files: names))
                    } catch {
                        if !listing { throw error }
                        rows.append(unavailableRecord(id: slot.id, error: error))
                    }
                }
            }
            try checkSlots()
            return rows
        }
    }

    private static func unavailableRecord<D>(id: UUID, error: Error) -> RegistryRecord<D> {
        RegistryRecord(id: id, status: error as? Failure == .busy ? .busy : .unavailable, files: [])
    }

    private static func withPendingStream<T>(
        rootFD: Int32, slot: RegistrySlot, checkSlots: () throws -> Void,
        body: (Int32, Int32?) throws -> T
    ) throws -> T {
        try checkSlots()
        let named = try pathStat(parent: rootFD, name: slot.name)
        try requireDirectory(named)
        var root = stat()
        guard fstat(rootFD, &root) == 0 else { throw pathFailure("stat-registry") }
        guard named.st_dev == root.st_dev,
              RegistrySlot(id: slot.id, state: slot.state, metadata: named) == slot else { throw Failure.changed }
        let stream = openat(rootFD, slot.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stream >= 0 else { throw pathFailure("open-pending-stream") }
        defer { close(stream) }
        try validateDirectory(stream, matching: Identity(named))
        try lockStream(stream)
        try checkSlots()
        let lock: stat
        do { lock = try pathStat(parent: stream, name: "lock") }
        catch Failure.unavailable { return try body(stream, nil) }
        try requireFile(lock, empty: true)
        let fd = openat(stream, "lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw pathFailure("open-pending-lock") }
        defer { close(fd) }
        try validateLock(fd, matching: Identity(lock))
        try lockStream(fd)
        try validateLock(fd, matching: Identity(try pathStat(parent: stream, name: "lock")))
        return try body(stream, fd)
    }

    private static func removePending(
        rootFD: Int32, slot: RegistrySlot, state: RegistrySlot.State, streamFD: Int32,
        lockFD: Int32?, files: [String: RetirementFile],
        checkSlots: () throws -> Void, checkpoint: (RetirementStage) throws -> Void
    ) throws {
        var pending = slot
        pending.state = state
        var remaining = files
        func check() throws {
            try checkSlots()
            let named = try pathStat(parent: rootFD, name: pending.name)
            guard RegistrySlot(id: pending.id, state: state, metadata: named) == pending else { throw Failure.changed }
            try validateDirectory(streamFD, matching: Identity(named))
            guard try retirementFiles(streamFD, phase: state) == remaining else { throw Failure.changed }
            if let mutex = remaining["lock"] {
                guard let lockFD else { throw Failure.changed }
                try validateLock(lockFD, matching: mutex.identity)
            }
        }
        try checkpoint(.beforeCleanup)
        for name in creationOrder.reversed() where remaining[name] != nil {
            try check()
            guard unlinkat(streamFD, name, 0) == 0 else { throw pathFailure("remove-retired-file") }
            guard fsync(streamFD) == 0 else { throw pathFailure("sync-retired-file") }
            remaining.removeValue(forKey: name)
            try checkpoint(.removedFile(name))
        }
        try check()
        guard unlinkat(rootFD, pending.name, AT_REMOVEDIR) == 0 else { throw pathFailure("remove-retired-stream") }
        guard fsync(rootFD) == 0 else { throw pathFailure("sync-retired-stream") }
    }
}
