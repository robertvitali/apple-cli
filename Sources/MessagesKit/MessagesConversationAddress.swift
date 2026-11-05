/// Strict address identity for conversation creation. This is deliberately separate
/// from legacy send normalization and from sandbox allowlist equivalence.
struct MessagesConversationAddress: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case phone, email }

    enum ParseError: Error, CustomStringConvertible {
        case unsupportedAddress, rawAddressTooLong

        var description: String {
            switch self {
            case .unsupportedAddress: "Unsupported conversation recipient address"
            case .rawAddressTooLong: "Conversation recipient address exceeds the byte limit"
            }
        }
    }

    let kind: Kind
    let canonical: String

    private init(kind: Kind, canonical: String) {
        self.kind = kind
        self.canonical = canonical
    }

    /// No contact aliases, country-code guessing, Unicode folding or local-part
    /// case folding. Call this on original address evidence, before normalization.
    static func parse(_ raw: String) throws -> Self {
        let bytes = Array(raw.utf8.prefix(513))
        guard bytes.count <= 512 else { throw ParseError.rawAddressTooLong }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else {
            throw ParseError.unsupportedAddress
        }
        var start = 0, end = bytes.count
        while start < end, bytes[start] == 32 { start += 1 }
        while end > start, bytes[end - 1] == 32 { end -= 1 }
        let value = bytes[start..<end]
        guard !value.isEmpty else { throw ParseError.unsupportedAddress }
        return value.first == 43 && !value.contains(64) ? try phone(value) : try email(value)
    }

    private static func phone(_ value: ArraySlice<UInt8>) throws -> Self {
        var digits: [UInt8] = []
        var parenthesisOpen = false
        for byte in value.dropFirst() {
            switch byte {
            case 48...57:
                guard digits.count < 15 else { throw ParseError.unsupportedAddress }
                digits.append(byte)
            case 32, 45, 46: break
            case 40:
                guard !parenthesisOpen else { throw ParseError.unsupportedAddress }
                parenthesisOpen = true
            case 41:
                guard parenthesisOpen else { throw ParseError.unsupportedAddress }
                parenthesisOpen = false
            default: throw ParseError.unsupportedAddress
            }
        }
        guard !parenthesisOpen, digits.count >= 2, digits.first != 48 else {
            throw ParseError.unsupportedAddress
        }
        return Self(kind: .phone, canonical: "+" + String(decoding: digits, as: UTF8.self))
    }

    private static func email(_ value: ArraySlice<UInt8>) throws -> Self {
        guard value.count <= 254 else { throw ParseError.unsupportedAddress }
        let parts = value.split(separator: 64, omittingEmptySubsequences: false)
        guard parts.count == 2, (1...64).contains(parts[0].count) else {
            throw ParseError.unsupportedAddress
        }
        let atoms = parts[0].split(separator: 46, omittingEmptySubsequences: false)
        let punctuation = Set("!#$%&'*+-/=?^_`{|}~".utf8)
        guard atoms.allSatisfy({ atom in
            !atom.isEmpty && atom.allSatisfy { isAlphanumeric($0) || punctuation.contains($0) }
        }) else { throw ParseError.unsupportedAddress }
        let labels = parts[1].split(separator: 46, omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != 45 && label.last != 45
                && label.allSatisfy { isAlphanumeric($0) || $0 == 45 }
        }) else { throw ParseError.unsupportedAddress }
        let domain = parts[1].map { byte in (65...90).contains(byte) ? byte + 32 : byte }
        return Self(kind: .email, canonical: String(decoding: parts[0], as: UTF8.self)
                    + "@" + String(decoding: domain, as: UTF8.self))
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
