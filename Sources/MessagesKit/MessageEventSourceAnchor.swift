import Darwin
import Foundation

/// Tracks the source of a WAL-backed event stream without opening another database descriptor.
/// Closing an independently opened descriptor could release SQLite's process-wide file locks.
struct MessageEventSourceAnchor {
    enum Failure: Error { case sourceReset, sourceUnavailable, observationGap }

    private let path: String
    let identity: Data

    init(path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure.sourceUnavailable }
        self.path = path
        identity = try Self.readIdentity(path)
    }

    func verify() throws {
        guard try Self.readIdentity(path) == identity else { throw Failure.sourceReset }
    }

    /// A missing or ambiguous sidecar prevents capture until a fresh observation succeeds.
    func verifyReadReady() throws {
        try verify()
        for suffix in ["-wal", "-shm"] {
            var info = stat()
            guard lstat(path + suffix, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1 else { throw Failure.observationGap }
        }
    }

    private static func readIdentity(_ path: String) throws -> Data {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR, ELOOP: throw Failure.sourceReset
            default: throw Failure.sourceUnavailable
            }
        }
        // Multiple names can attach different WALs to the same physical main file.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_ino > 0, info.st_nlink == 1 else {
            throw Failure.sourceReset
        }
        let birth = info.st_birthtimespec
        guard birth.tv_sec > 0, (0..<1_000_000_000).contains(birth.tv_nsec) else {
            throw Failure.sourceUnavailable
        }
        var bytes = Data([1])
        func append<T: FixedWidthInteger>(_ number: T) {
            withUnsafeBytes(of: number.bigEndian) { bytes.append(contentsOf: $0) }
        }
        append(UInt64(UInt32(bitPattern: info.st_dev)))
        append(UInt64(info.st_ino))
        append(Int64(birth.tv_sec))
        append(UInt32(birth.tv_nsec))
        return bytes
    }

    /// The persisted v1 fields are device, inode, birth seconds and birth nanoseconds in network order.
    static func isValidStoredIdentity(_ bytes: Data) -> Bool {
        guard bytes.count == 29, bytes.first == 1 else { return false }
        return bytes.withUnsafeBytes { raw in
            let device = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
            let inode = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 9, as: UInt64.self))
            let seconds = Int64(bigEndian: raw.loadUnaligned(fromByteOffset: 17, as: Int64.self))
            let nanos = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 25, as: UInt32.self))
            return device <= UInt32.max && inode > 0 && seconds > 0 && nanos < 1_000_000_000
        }
    }
}
