import Foundation

/// Decoder for the `message.attributedBody` column — an Apple typedstream
/// (NSArchiver serialization of `NSMutableAttributedString`). On modern macOS the
/// plain `text` column is frequently NULL and the body lives ONLY here, so this is
/// load-bearing for `recent`/`search` parity (the overwhelming majority of rows on the
/// measured live store had NULL text + non-NULL attributedBody).
///
/// Port of `mac_messages_mcp.extract_body_from_attributed`: locate the first
/// `NSString` class marker, skip a 5-byte header, read a variable-length integer
/// length, then decode that many UTF-8 bytes.
public enum AttributedBody {

    /// Returns the decoded message text, or nil if the blob has no NSString payload.
    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        return decode(bytes: bytes)
    }

    static func decode(bytes: [UInt8]) -> String? {
        guard let marker = find(bytes, pattern: Array("NSString".utf8)) else { return nil }

        // Skip: "NSString" (8) + \x01 + <byte> + \x84 + \x01 + '+' = 5 trailing bytes.
        var pos = marker + 8 + 5
        guard pos < bytes.count else { return nil }

        // Variable-length integer for the UTF-8 byte length.
        let lengthByte = Int(bytes[pos]); pos += 1
        let textLength: Int
        if lengthByte < 0x80 {
            textLength = lengthByte
        } else if lengthByte == 0x81 {
            guard pos + 2 <= bytes.count else { return nil }
            textLength = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2
        } else if lengthByte == 0x82 {
            guard pos + 3 <= bytes.count else { return nil }
            textLength = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16)
            pos += 3
        } else if lengthByte == 0x83 {
            guard pos + 4 <= bytes.count else { return nil }
            textLength = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
                | (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
            pos += 4
        } else {
            return nil
        }

        guard textLength >= 0, pos + textLength <= bytes.count else { return nil }
        let slice = bytes[pos..<(pos + textLength)]
        // Python decodes with errors="replace"; String(decoding:as:) does the same
        // (invalid sequences → U+FFFD).
        return String(decoding: slice, as: UTF8.self)
    }

    /// First index of `pattern` in `haystack`, or nil. Simple scan (patterns are
    /// tiny and blobs are short — no need for KMP).
    private static func find(_ haystack: [UInt8], pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
        let last = haystack.count - pattern.count
        var i = 0
        while i <= last {
            var j = 0
            while j < pattern.count && haystack[i + j] == pattern[j] { j += 1 }
            if j == pattern.count { return i }
            i += 1
        }
        return nil
    }
}
