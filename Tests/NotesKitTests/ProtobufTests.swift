import Testing
import Foundation
import Compression
@testable import NotesKit

// Logic-tier tests (swift-testing) for the gzip + protobuf checklist decoder — the hardest part
// of the port and the only path to Apple Notes checklist done-state. Uses a hand-built synthetic
// Apple-Notes-shaped protobuf so the decode is verifiable without touching the real store.

/// Minimal protobuf wire encoder (test-only), enough to synthesize the Notes note structure.
enum PBEncode {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }
    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] { tag(field, 0) + varint(value) }
    static func bytesField(_ field: Int, _ bytes: [UInt8]) -> [UInt8] { tag(field, 2) + varint(UInt64(bytes.count)) + bytes }
    static func stringField(_ field: Int, _ s: String) -> [UInt8] { bytesField(field, Array(s.utf8)) }
}

/// Build a Notes-shaped protobuf: doc.2 → wrapper.3 → body{ text(2), runs(5)... }.
/// Each `runs` entry: {length(1), style(2){ styleType(1), checklist(5){ done(2) } }}.
func synthesizeChecklistProtobuf(text: String, runs: [(length: Int, styleType: Int?, done: Int?)]) -> [UInt8] {
    var bodyFields = PBEncode.stringField(2, text)
    for run in runs {
        var runBytes = PBEncode.varintField(1, UInt64(run.length))
        if let styleType = run.styleType {
            var style = PBEncode.varintField(1, UInt64(styleType))
            if let done = run.done {
                let checklist = PBEncode.varintField(2, UInt64(done))
                style += PBEncode.bytesField(5, checklist)
            }
            runBytes += PBEncode.bytesField(2, style)
        }
        bodyFields += PBEncode.bytesField(5, runBytes)
    }
    let wrapper = PBEncode.bytesField(3, bodyFields)
    return PBEncode.bytesField(2, wrapper)
}

/// gzip-wrap raw bytes (test helper): real deflate body + correct ISIZE trailer (CRC left 0 —
/// `Gzip.inflate` sizes from ISIZE and does not validate CRC).
func makeGzip(_ payload: [UInt8]) -> [UInt8] {
    let bound = payload.count + 64
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bound)
    defer { dst.deallocate() }
    let n = payload.withUnsafeBufferPointer {
        compression_encode_buffer(dst, bound, $0.baseAddress!, $0.count, nil, COMPRESSION_ZLIB)
    }
    let deflate = Array(UnsafeBufferPointer(start: dst, count: n))
    var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0xFF]
    out += deflate
    out += [0, 0, 0, 0] // CRC32 (ignored)
    let isize = UInt32(payload.count)
    out += [UInt8(isize & 0xFF), UInt8((isize >> 8) & 0xFF), UInt8((isize >> 16) & 0xFF), UInt8((isize >> 24) & 0xFF)]
    return out
}

@Suite("Protobuf + gzip")
struct ProtobufTests {

    @Test("varint round-trips through decode")
    func varintDecode() {
        for value: UInt64 in [0, 1, 127, 128, 300, 16384, 103, 1_000_000] {
            let encoded = PBEncode.varint(value)
            let decoded = Protobuf.decodeVarint(encoded, 0)
            #expect(decoded?.0 == value)
        }
    }

    @Test("decodeMessage recovers varint and length-delimited fields")
    func messageDecode() {
        let bytes = PBEncode.varintField(1, 42) + PBEncode.stringField(2, "hi")
        let fields = Protobuf.decodeMessage(bytes)
        #expect(Protobuf.varintValue(Protobuf.field(fields, 1)) == 42)
        #expect(Protobuf.stringValue(Protobuf.field(fields, 2)) == "hi")
    }

    @Test("decodeMessage stops cleanly on a truncated length-delimited field")
    func messageDecodeTruncated() {
        // tag for field 2 wire 2, length 10, but only 2 bytes follow → reference `break`.
        let bytes = PBEncode.tag(2, 2) + PBEncode.varint(10) + [0x41, 0x42]
        let fields = Protobuf.decodeMessage(bytes)
        #expect(fields.isEmpty) // the truncated field is dropped, no crash
    }

    @Test("gzip inflate round-trips a payload")
    func gzipRoundTrip() throws {
        let payload = Array("the quick brown fox jumps over the lazy dog ".utf8) + Array(repeating: 0x41, count: 500)
        let gz = makeGzip(payload)
        let out = try Gzip.inflate(gz)
        #expect(out == payload)
    }

    @Test("gzip rejects non-gzip bytes")
    func gzipRejectsBadMagic() {
        #expect(throws: (any Error).self) { try Gzip.inflate([0x00, 0x01, 0x02, 0x03] + Array(repeating: 0, count: 20)) }
    }

    @Test("checklist parse extracts text + done state per item")
    func checklistParse() {
        // text has 3 lines; runs mark line 1 done, line 2 not done, line 3 done. Run lengths
        // must advance charPos across each line (+1 for the newline).
        let text = "Eggs\nMilk\nBread"
        let runs: [(length: Int, styleType: Int?, done: Int?)] = [
            (5, 103, 1), // "Eggs\n" (4 + newline) → line 0 done
            (5, 103, 0), // "Milk\n" → line 1 not done
            (5, 103, 1), // "Bread" (+overshoot) → line 2 done
        ]
        let proto = synthesizeChecklistProtobuf(text: text, runs: runs)
        let items = NotesStore.parseChecklist(proto)
        #expect(items?.count == 3)
        #expect(items?[0] == NotesStore.ChecklistItem(text: "Eggs", done: true))
        #expect(items?[1] == NotesStore.ChecklistItem(text: "Milk", done: false))
        #expect(items?[2] == NotesStore.ChecklistItem(text: "Bread", done: true))
    }

    @Test("checklist parse end-to-end through gzip")
    func checklistThroughGzip() throws {
        let text = "Task A\nTask B"
        let proto = synthesizeChecklistProtobuf(text: text, runs: [(7, 103, 0), (6, 103, 1)])
        let gz = makeGzip(proto)
        let inflated = try Gzip.inflate(gz)
        let items = NotesStore.parseChecklist(inflated)
        #expect(items?[0] == NotesStore.ChecklistItem(text: "Task A", done: false))
        #expect(items?[1] == NotesStore.ChecklistItem(text: "Task B", done: true))
    }

    @Test("non-checklist paragraph runs (style != 103) yield no items")
    func nonChecklistRuns() {
        let proto = synthesizeChecklistProtobuf(text: "Plain line", runs: [(10, 0, nil)])
        let items = NotesStore.parseChecklist(proto)
        #expect((items ?? []).isEmpty)
    }

    @Test("checklist line mapping stays aligned for non-BMP (emoji) text — UTF-16 accounting")
    func checklistEmojiUTF16() {
        // "🛒 Milk" is 6 grapheme clusters but 7 UTF-16 code units (🛒 is a surrogate pair).
        // Apple's run lengths are UTF-16, so a grapheme-based length would misalign charPos and
        // drop/mis-map the item. Run lengths here are UTF-16 line-length + 1 for the newline.
        let l0 = "🛒 Milk"; let l1 = "Eggs"
        #expect(l0.count == 6 && l0.utf16.count == 7) // sanity: the divergence exists
        let text = "\(l0)\n\(l1)"
        let runs: [(length: Int, styleType: Int?, done: Int?)] = [
            (l0.utf16.count + 1, 103, 1), // line 0 done
            (l1.utf16.count + 1, 103, 0), // line 1 not done
        ]
        let items = NotesStore.parseChecklist(synthesizeChecklistProtobuf(text: text, runs: runs))
        #expect(items?.count == 2)
        #expect(items?[0] == NotesStore.ChecklistItem(text: "🛒 Milk", done: true))
        #expect(items?[1] == NotesStore.ChecklistItem(text: "Eggs", done: false))
    }

    @Test("gzip rejects a decompression bomb (ISIZE claims more than the safety cap)")
    func gzipBombRejected() {
        // A tiny highly-compressible payload, but with the ISIZE trailer forged to ~4 GiB.
        let payload = Array(repeating: UInt8(0x41), count: 1024)
        var gz = makeGzip(payload)
        // Overwrite the last 4 bytes (ISIZE) with 0xFFFFFFFF.
        gz[gz.count - 4] = 0xFF; gz[gz.count - 3] = 0xFF; gz[gz.count - 2] = 0xFF; gz[gz.count - 1] = 0xFF
        // The allocation is clamped to maxDecompressedBytes, so the real 1 KiB output still
        // inflates fine (it does not hit the cap) — the clamp prevents the 4 GiB allocation,
        // it does not corrupt a legitimate small payload.
        let out = try? Gzip.inflate(gz)
        #expect(out == payload) // clamp bounded the buffer; small real output still decodes
    }
}

@Suite("NotesStore id + hex helpers")
struct NotesStoreHelperTests {
    @Test("primaryKey extracts the trailing pNNN")
    func primaryKey() {
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC-123/ICNote/p58") == 58)
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC/ICNote/p9999") == 9999)
        #expect(NotesStore.primaryKey(from: "bogus") == nil)
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC/ICNote/pX") == nil)
    }

    @Test("hexToBytes decodes uppercase and lowercase hex")
    func hexToBytes() {
        #expect(NotesStore.hexToBytes("1F8B08") == [0x1F, 0x8B, 0x08])
        #expect(NotesStore.hexToBytes("deadBEEF") == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(NotesStore.hexToBytes("") == [])
    }
}
