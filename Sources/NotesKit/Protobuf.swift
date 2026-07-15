import Foundation
import Compression

/// Minimal protobuf wire-format reader + gzip inflate, ported from
/// `apple-notes-mcp@2.5.12` `src/utils/protobuf.ts`. Apple Notes stores each note's
/// rich text as a gzipped protobuf in `ZICNOTEDATA.ZDATA`; the checklist done-state
/// lives ONLY there (AppleScript's `body` strips it), so decoding this blob is the
/// only way to answer `get-checklist`. This file is pure (no I/O) so it is fully
/// unit-testable against a synthetic gzipped-protobuf fixture.
enum Protobuf {

    /// A decoded wire field. `varint` carries wire-type 0; `bytes` carries wire-type 2
    /// (length-delimited: strings AND embedded messages).
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    struct Field {
        let number: Int
        let value: Value
    }

    /// Decode a length-delimited protobuf message into its top-level fields. Mirrors
    /// `decodeMessage`: varint (0), length-delimited (2), fixed32 (5 → skip 4),
    /// fixed64 (1 → skip 8); any other wire type stops the scan (matches the reference's
    /// defensive `break`, so a truncated/garbage tail can't throw).
    static func decodeMessage(_ buf: [UInt8]) -> [Field] {
        var fields: [Field] = []
        var offset = 0
        while offset < buf.count {
            guard let (tag, next) = decodeVarint(buf, offset) else { break }
            offset = next
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 7)
            switch wireType {
            case 0: // VARINT
                guard let (value, n2) = decodeVarint(buf, offset) else { return fields }
                offset = n2
                fields.append(Field(number: fieldNumber, value: .varint(value)))
            case 2: // LENGTH_DELIMITED
                guard let (length, n2) = decodeVarint(buf, offset) else { return fields }
                offset = n2
                let len = Int(length)
                if offset + len > buf.count { return fields } // reference `break`
                fields.append(Field(number: fieldNumber, value: .bytes(Array(buf[offset..<offset + len]))))
                offset += len
            case 5: // fixed32
                offset += 4
            case 1: // fixed64
                offset += 8
            default:
                return fields
            }
        }
        return fields
    }

    /// Read a base-128 varint at `offset`. Returns the value and the offset past it, or
    /// nil on a truncated/over-long varint (the reference throws; nil keeps us total).
    /// Uses UInt64 accumulation (the reference used 32-bit JS bitwise ops — this is a
    /// strict superset: correct for the rare large varint, identical for the small ones
    /// that actually occur — run lengths, style types, done flags).
    static func decodeVarint(_ buf: [UInt8], _ offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pos = offset
        while pos < buf.count {
            let byte = buf[pos]
            result |= UInt64(byte & 0x7F) << shift
            pos += 1
            if byte & 0x80 == 0 { return (result, pos) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    // MARK: field accessors (mirror getField/getFields/varintValue/stringValue/embeddedMessage)

    static func fields(_ fields: [Field], _ number: Int) -> [Field] {
        fields.filter { $0.number == number }
    }

    static func field(_ fields: [Field], _ number: Int) -> Field? {
        fields.first { $0.number == number }
    }

    static func varintValue(_ field: Field?) -> UInt64? {
        guard let field, case let .varint(v) = field.value else { return nil }
        return v
    }

    static func bytesValue(_ field: Field?) -> [UInt8]? {
        guard let field, case let .bytes(b) = field.value else { return nil }
        return b
    }

    static func stringValue(_ field: Field?) -> String? {
        guard let bytes = bytesValue(field) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func embeddedMessage(_ field: Field?) -> [Field]? {
        guard let bytes = bytesValue(field) else { return nil }
        return decodeMessage(bytes)
    }
}

/// gzip (RFC 1952) inflate using Apple's `Compression` framework. The framework only
/// speaks raw DEFLATE (`COMPRESSION_ZLIB` == raw deflate stream, no wrapper), so we parse
/// the gzip header ourselves, hand the deflate body to `compression_decode_buffer`, and
/// size the output buffer from the gzip trailer's ISIZE. Apple Notes writes standard gzip
/// (magic `1f 8b`, method 08); we still honor the FLG optional-field bits for robustness.
enum Gzip {
    /// Hard ceiling on decompressed output. The gzip trailer's ISIZE (last 4 bytes) is
    /// attacker-controllable and drives the output allocation; without a clamp a tiny crafted
    /// blob could demand a ~4.29 GB allocation (decompression bomb), reachable via
    /// `get-checklist`/`get-markdown` on a synced/shared note. 64 MiB dwarfs any real Notes
    /// body while bounding the blast radius. Also enforced mid-inflate so a body that keeps
    /// producing output past the cap is rejected rather than growing unbounded.
    static let maxDecompressedBytes = 64 * 1024 * 1024

    enum GzipError: Error, CustomStringConvertible {
        case notGzip
        case truncated
        case inflateFailed
        case tooLarge
        var description: String {
            switch self {
            case .notGzip: return "data is not gzip (bad magic or method)"
            case .truncated: return "gzip stream truncated"
            case .inflateFailed: return "gzip inflate failed"
            case .tooLarge: return "gzip output exceeds the \(maxDecompressedBytes)-byte safety cap"
            }
        }
    }

    static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 18 else { throw GzipError.truncated } // 10 header + >=0 body + 8 trailer
        guard data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else { throw GzipError.notGzip }
        let flg = data[3]
        var pos = 10 // fixed header: magic(2) method(1) flg(1) mtime(4) xfl(1) os(1)

        // FEXTRA (bit 2): 2-byte little-endian length + that many bytes.
        if flg & 0x04 != 0 {
            guard pos + 2 <= data.count else { throw GzipError.truncated }
            let xlen = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            pos += 2 + xlen
        }
        // FNAME (bit 3) / FCOMMENT (bit 4): NUL-terminated strings.
        if flg & 0x08 != 0 { pos = try skipCString(data, pos) }
        if flg & 0x10 != 0 { pos = try skipCString(data, pos) }
        // FHCRC (bit 1): 2-byte header CRC.
        if flg & 0x02 != 0 { pos += 2 }

        guard pos + 8 <= data.count else { throw GzipError.truncated }
        let bodyEnd = data.count - 8 // strip 8-byte trailer (CRC32 + ISIZE)
        guard pos <= bodyEnd else { throw GzipError.truncated }

        // ISIZE = uncompressed size mod 2^32 (little-endian) in the last 4 bytes.
        let isize = Int(data[data.count - 4]) | (Int(data[data.count - 3]) << 8)
            | (Int(data[data.count - 2]) << 16) | (Int(data[data.count - 1]) << 24)
        // Clamp the ISIZE-derived allocation to the safety cap (decompression-bomb defense);
        // fall back to a modest estimate for a bogus/zero ISIZE.
        let estimate = isize > 0 ? isize : max(data.count * 8, 64 * 1024)
        let capacity = min(estimate, maxDecompressedBytes)

        let body = Array(data[pos..<bodyEnd])
        guard !body.isEmpty else { throw GzipError.truncated }
        return try rawInflate(body, capacity: capacity)
    }

    private static func skipCString(_ data: [UInt8], _ start: Int) throws -> Int {
        var i = start
        while i < data.count {
            if data[i] == 0 { return i + 1 }
            i += 1
        }
        throw GzipError.truncated
    }

    /// Decode a raw DEFLATE stream into a `capacity`-sized buffer (sized from the clamped gzip
    /// ISIZE). `capacity` is already bounded by `maxDecompressedBytes`, so a single allocation
    /// suffices — if the stream would produce more than the buffer holds, `compression_decode_buffer`
    /// fills it exactly (== capacity) and we reject rather than grow unbounded (bomb defense).
    private static func rawInflate(_ body: [UInt8], capacity: Int) throws -> [UInt8] {
        let dstSize = min(max(capacity, 1), maxDecompressedBytes)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let written = body.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(dst, dstSize, base, src.count, nil, COMPRESSION_ZLIB)
        }
        if written == 0 { throw GzipError.inflateFailed }
        // Exactly filling the cap-sized buffer means the real output is >= the cap — reject.
        if written == dstSize && dstSize == maxDecompressedBytes { throw GzipError.tooLarge }
        return Array(UnsafeBufferPointer(start: dst, count: written))
    }
}
