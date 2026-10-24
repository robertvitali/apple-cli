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

    private struct Identity: Equatable {
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
        let components = root.split(separator: "/", omittingEmptySubsequences: false)
        guard root.hasPrefix("/"), !root.utf8.contains(0),
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.unsafeState
        }
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
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Failure.systemCall("flock", code)
        }
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
        do {
            try Self.validatePaths(root: root, streamName: streamName, rootFD: rootFD,
                                   streamFD: streamFD, lockFD: lockFD,
                                   rootIdentity: rootIdentity, streamIdentity: streamIdentity,
                                   lockIdentity: lockIdentity)
            let files = try Self.inspectFiles(streamFD)
            guard files["lock"] == lockIdentity, files["state.sqlite"] == mainIdentity,
                  files["state.sqlite-journal"] == journalIdentity else { throw Failure.changed }
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

    private static func inspectFiles(_ directoryFD: Int32) throws -> [String: Identity] {
        // dup would share the directory position and make repeated checks incomplete.
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scanFD >= 0 else { throw Failure.systemCall("open-inventory", errno) }
        guard let directory = fdopendir(scanFD) else {
            let code = errno
            close(scanFD)
            throw Failure.systemCall("fdopendir", code)
        }
        defer { closedir(directory) }
        var result: [String: Identity] = [:]
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Failure.systemCall("readdir", errno) }
                break
            }
            let name = try directoryEntryName(UnsafePointer(entry))
            if name == "." || name == ".." { continue }
            guard name == "lock" || name == "state.sqlite" || name == "state.sqlite-journal",
                  result[name] == nil else { throw Failure.unsafeState }
            let value = try pathStat(parent: directoryFD, name: name)
            try requireFile(value, empty: name == "lock")
            result[name] = Identity(value)
        }
        guard result["lock"] != nil, result["state.sqlite"] != nil else { throw Failure.unavailable }
        return result
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
