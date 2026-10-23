import Foundation
import AppleKit

extension ChatDB {
    public struct ExactNativeMentions: Encodable {
        public let status: String
        public let reason: String?
        public let text: String?
        public let entries: [Entry]?

        public struct Entry: Encodable {
            public let identifier: String
            public let utf16_range: NativeMessageParts.UTF16Range
        }

        enum CodingKeys: String, CodingKey { case status, reason, text, range_encoding, entries }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try encodeOrNull(&c, reason, .reason)
            try encodeOrNull(&c, text, .text)
            try c.encode("utf-16", forKey: .range_encoding)
            try encodeOrNull(&c, entries, .entries)
        }

        static func unavailable(_ status: String, reason: String) -> Self {
            .init(status: status, reason: reason, text: nil, entries: nil)
        }
    }
}

/// Output-content limits for optional mention metadata, separate from native
/// part parsing and edit-history budgets. These observations never target writes.
enum NativeMentionsRead {
    typealias Context = ChatDB.ExactNativeMentions

    struct Budget {
        var remainingEntries = 2_048
        var remainingBytes = 4_194_304
        var exhausted = false
    }

    static func shouldCollect(requested: Bool, budget: Budget) -> Bool {
        requested && !budget.exhausted
    }

    static func context(_ value: SQLiteReader.Row.Value?, storageType: String? = nil,
                        decoded: NativeMessageParts.Decoded,
                        requested: Bool, budget: inout Budget) -> Context {
        guard requested else { return .unavailable("not-requested", reason: "not-requested") }
        guard !budget.exhausted else { return requestLimit(&budget) }
        switch value {
        case nil, .null?:
            // SQLiteReader preserves legacy behavior by materializing an empty
            // BLOB as null. SQL type evidence keeps this additive observation
            // distinct without changing the shared reader or native parts.
            if storageType == "blob" { return .unavailable("corrupt", reason: "native-parse-failed") }
            return .unavailable("absent-blob", reason: "absent-blob")
        case .blob?: break
        default: return .unavailable("wrong-type", reason: "wrong-storage-type")
        }
        switch decoded.status {
        case .unsupported: return .unavailable("unsupported", reason: "unsupported-typedstream")
        case .decoded, .noNativeKeys: break
        default: return .unavailable("corrupt", reason: "native-parse-failed")
        }
        guard let observation = decoded.mentions else {
            return .unavailable("corrupt", reason: "native-parse-failed")
        }
        if let reason = observation.reason {
            let status = ["mention-identifier-limit", "mention-count-limit"].contains(reason)
                ? "resource-limit" : "corrupt"
            return .unavailable(status, reason: reason)
        }
        guard let entries = observation.entries else {
            return .unavailable("corrupt", reason: "native-parse-failed")
        }
        guard !entries.isEmpty else { return .init(status: "available", reason: nil, text: nil, entries: []) }
        guard let text = decoded.text else { return .unavailable("corrupt", reason: "native-parse-failed") }
        guard entries.count <= budget.remainingEntries else { return requestLimit(&budget) }
        var bytes = text.utf8.count
        guard bytes <= budget.remainingBytes else { return requestLimit(&budget) }
        for entry in entries {
            let next = entry.identifier.utf8.count
            guard next <= budget.remainingBytes - bytes else { return requestLimit(&budget) }
            bytes += next
        }
        // Admit the whole message before retaining any public entries. Prior
        // successful charges stay spent; failed observations consume no output.
        budget.remainingEntries -= entries.count
        budget.remainingBytes -= bytes
        return .init(status: "available", reason: nil, text: text,
                     entries: entries.map { .init(identifier: $0.identifier, utf16_range: $0.utf16Range) })
    }

    private static func requestLimit(_ budget: inout Budget) -> Context {
        budget.exhausted = true
        return .unavailable("request-limit", reason: "request-budget-exhausted")
    }
}
