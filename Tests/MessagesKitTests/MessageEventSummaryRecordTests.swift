import Foundation
import Testing
@testable import MessagesKit

struct MessageEventSummaryRecordTests {
    private typealias Record = MessageEventSummaryRecord
    private let projection = Data(#"{"version":1,"date_edited":"//////////k=","date_retracted":null,"association":{"target_status":"unresolved","target_message_guid":null,"target_part":null,"native_type":null,"actor_kind":"unknown","supported":false}}"#.utf8)
    private let availability = Data([0, 0, 2, 2, 0, 0, 0, 0])

    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    private var evidence: [Record.Observation] {
        [.init(status: "available", bytes: bytes("ede9ce0853f5887df0bcd2b760b01c111dc54fcc19e6be1a1272204b0737da94")),
         .init(status: "missing-key", bytes: Data()),
         .init(status: "available", bytes: bytes("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))]
    }

    // Independent length-framed SHA-256 vectors for both on-disk formats.
    private var current: Data {
        bytes("81f2958673168dbbb32b6304bb629c191369aa3f85d0178cadcff71d84208dd3" +
              "ff582e57f31838d8b971b06b2749755a08dda5ba450252e9dd080707059f2037")
    }
    private var legacy: Data {
        bytes("8d99f47ac2be2b889ee8b9997b87d1875d4a15654e4c38c54dedf3d41fe8dbce" +
              "f4a5e260f2beeca01544f8adff7d423678b975ce918771a9c88df281645acac5")
    }
    private func hashes(_ components: Data) -> Data {
        Data(count: 32) + bytes("4cc782e455504aa9e614fc6f38b0879f757d539822eb2d456a038b9ad0c641c9")
            + components + Data(count: 128)
    }

    @Test func currentRecordAndLegacyUpgradeAgreeWithIndependentDigests() throws {
        let record = try Record.encode(evidence, sourceStatus: 0)
        let expected = bytes("02000700a168260d57d9326e8369d8e8b33a0426fa4f53a3cbc8588ac907a66989ec9670" +
                             "a0c043086cdde8e064c9971039752a0d25543f9f4ed2c61c11aa570fba0ed564" +
                             "f1f36311b348b7ae82d4a612fb4bbc121d398b4cb89018c3ea6259081ee3fb3a")
        #expect(record == expected)
        var validator = Record.Validator()
        func slice(_ data: Data) -> Data { (Data([255, 255]) + data).dropFirst(2) }
        try validator.validate(projection: slice(projection), hashes: slice(hashes(current)),
                               availability: slice(availability), record: slice(record))
        let old = Data([1]) + record.dropFirst()
        #expect(throws: Record.Failure.witnessUnavailable) {
            try validator.validate(projection: projection, hashes: hashes(legacy), availability: availability, record: old)
        }
        #expect(try Record.convertedLegacyComponents(projection: projection, hashes: hashes(legacy),
            availability: availability, record: old, evidence: evidence) == current)
        #expect(throws: Record.Failure.witnessUnavailable) {
            try Record.convertedLegacyComponents(projection: projection, hashes: hashes(legacy),
                availability: availability, record: old, evidence: Array(evidence.reversed()))
        }
        var maintenance = Record.Validator(allowMissingWitness: true)
        try maintenance.validate(projection: projection, hashes: hashes(legacy), availability: availability, record: old)
        var corrupt = hashes(legacy)
        corrupt[96] ^= 1
        #expect(throws: Record.Failure.invalidRecord) {
            try maintenance.validate(projection: projection, hashes: corrupt, availability: availability, record: old)
        }
    }

    @Test(arguments: [1, 2, 3]) func checksUnavailableSourceDigestOnEveryRow(status: Int) throws {
        let name = ["", "missing-schema", "null", "wrong-type"][status]
        let absent = Record.Observation(status: name, bytes: Data())
        let record = try Record.encode(Array(repeating: absent, count: 3), sourceStatus: UInt8(status))
        let date = Record.Observation(status: "available", bytes: bytes("fffffffffffffff9"))
        let nullDate = Record.Observation(status: "null", bytes: Data())
        let edit = try Record.component(.edit, date: date, record: record)
        let undo = try Record.component(.retraction, date: nullDate, record: record)
        let avail = Data([0, UInt8(status), edit.availability, undo.availability, 0, 0, 0, 0])
        var stored = Data(count: 32) + absent.fingerprint + edit.digest + undo.digest + Data(count: 128)
        var validator = Record.Validator()
        try validator.validate(projection: projection, hashes: stored, availability: avail, record: record)
        stored[32] ^= 1
        #expect(throws: Record.Failure.invalidRecord) {
            try validator.validate(projection: projection, hashes: stored, availability: avail, record: record)
        }
    }

    @Test func refusesMalformedFacetAndComponentFields() throws {
        let record = try Record.encode(evidence, sourceStatus: 0)
        var validator = Record.Validator()
        for (offset, value): (Int, UInt8) in [(0, 0), (0, 3), (1, 4), (2, 1), (2, 255), (36, 0)] {
            var corrupt = record
            corrupt[offset] = value
            #expect(throws: Record.Failure.invalidRecord) {
                try validator.validate(projection: projection, hashes: hashes(current), availability: availability, record: corrupt)
            }
        }
        #expect(throws: Record.Failure.invalidRecord) {
            try validator.validate(projection: projection, hashes: Data(count: 255), availability: availability, record: record)
        }
        #expect(throws: Record.Failure.invalidRecord) { try Record.encode([], sourceStatus: 0) }
        #expect(throws: Record.Failure.invalidRecord) { try Record.encode(evidence, sourceStatus: 1) }
    }
}
