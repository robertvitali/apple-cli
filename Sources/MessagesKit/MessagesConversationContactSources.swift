import AppleKit
import Foundation

/// Complete, bounded enumeration for creation's strict reader. Legacy AddressBook
/// discovery is best effort and cannot establish absence after an enumeration error.
enum MessagesConversationContactSources {
    enum Failure: Error { case unavailable, limitExceeded }

    /// Observed symlinks and unexpected types refuse. This is not a filesystem lock:
    /// accounts/files may change after discovery, and each subsequent source read
    /// must still succeed. Call again for authoritative resolution under the worker lease.
    /// Synchronous filesystem calls cannot be preempted by the cooperative deadline.
    static func discover(addressBookRoot: String, deadline: WorkerDeadline,
                         isCancelled: @escaping () -> Bool = { false }) throws -> [String] {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || ContinuousClock.now >= end { throw WorkerProtocolError.deadlineExpired }
        }
        let manager = FileManager.default
        func type(at path: String) throws -> FileAttributeType? {
            try checkpoint()
            let bytes = Array(path.utf8.prefix(4097))
            guard bytes.count <= 4096 else { throw Failure.limitExceeded }
            guard bytes.first == 47, !bytes.contains(0) else { throw Failure.unavailable }
            let attributes: [FileAttributeKey: Any]
            do { attributes = try manager.attributesOfItem(atPath: path) }
            catch {
                try checkpoint()
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
                throw Failure.unavailable
            }
            try checkpoint()
            guard let value = attributes[.type] as? FileAttributeType else { throw Failure.unavailable }
            return value
        }
        try checkpoint()
        guard try type(at: addressBookRoot) == .typeDirectory else { throw Failure.unavailable }
        let root = URL(fileURLWithPath: addressBookRoot, isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        var paths: [String] = []
        func appendDatabase(in directory: URL) throws {
            let path = directory.appendingPathComponent("AddressBook-v22.abcddb").path
            if let observed = try type(at: path) {
                guard observed == .typeRegular else { throw Failure.unavailable }
                guard paths.count < 64 else { throw Failure.limitExceeded }
                paths.append(path)
            }
        }
        try appendDatabase(in: root)
        if let observed = try type(at: sources.path) {
            guard observed == .typeDirectory else { throw Failure.unavailable }
            var enumerationFailed = false
            guard let entries = manager.enumerator(at: sources, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }) else { throw Failure.unavailable }
            var count = 0
            while let item = entries.nextObject() {
                try checkpoint()
                guard !enumerationFailed, let entry = item as? URL else { throw Failure.unavailable }
                guard count < 256 else { throw Failure.limitExceeded }
                count += 1
                // Enumeration can canonicalize /var to /private/var. Retain the
                // caller's root spelling consistently for every discovered source.
                let name = entry.lastPathComponent
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                    throw Failure.unavailable
                }
                let child = sources.appendingPathComponent(name)
                guard let observed = try type(at: child.path) else { throw Failure.unavailable }
                if observed == .typeDirectory { try appendDatabase(in: child) }
                else if observed != .typeRegular { throw Failure.unavailable }
            }
            guard !enumerationFailed else { throw Failure.unavailable }
        }
        try checkpoint()
        guard !paths.isEmpty else { throw Failure.unavailable }
        return paths.sorted()
    }
}
