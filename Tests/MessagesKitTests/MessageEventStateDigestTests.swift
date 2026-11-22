import Foundation
import Testing
@testable import MessagesKit

struct MessageEventStateDigestTests {
    private func metadata(_ rows: inout MessageEventStateDigest.Rows) throws {
        try rows.beginRow()
        for value: Int64 in [1, 1, 1] { try rows.integer(value) }
        for (ascii, size) in [(97, 36), (98, 36)] { try rows.blob(Data(repeating: UInt8(ascii), count: size)) }
        try rows.blob(Data("filter".utf8))
        for (ascii, size) in [(99, 32), (100, 29), (101, 32)] { try rows.blob(Data(repeating: UInt8(ascii), count: size)) }
        try rows.integer(2)
        try rows.integer(2)
    }

    @Test func matchesIndependentTypedFieldVector() throws {
        let result = try MessageEventStateDigest.compute(domain: "test-format-1") { table, rows in
            switch table {
            case .metadata: try metadata(&rows)
            case .baseline:
                try rows.beginRow()
                try rows.integer(1)
                try rows.blob(Data("c".utf8))
                try rows.blob(Data("m".utf8))
                try rows.integer(11)
                try rows.integer(9)
                for (ascii, size) in [(104, 256), (97, 8), (102, 100)] { try rows.blob(Data(repeating: UInt8(ascii), count: size)) }
                try rows.blob(Data("{}".utf8))
            case .events:
                for (i, label) in ["one", "two"].enumerated() {
                    try rows.beginRow()
                    try rows.integer(Int64(i + 1))
                    try rows.blob(Data(label.utf8))
                }
            }
        }
        #expect(result.digest.map { String(format: "%02x", $0) }.joined() == "d30b87c8713977803da09ff5b0caf68b2ab488f7dfc5b0b0cd231bfe07ebd444")
        #expect(result.memberships == 1 && result.events == 2)
    }

    @Test func rejectsIncompleteRowsAndUnexpectedFieldTypes() {
        typealias Rows = MessageEventStateDigest.Rows
        let invalid: [(inout Rows) throws -> Void] = [
            { _ in },
            { rows in try rows.integer(1) },
            { rows in try rows.beginRow() },
            { rows in try rows.beginRow(); try rows.beginRow() },
            { rows in try rows.beginRow(); try rows.blob(Data([1])) },
            { rows in try metadata(&rows); try rows.integer(1) },
            { rows in
                try rows.beginRow()
                for _ in 0..<3 { try rows.integer(1) }
                try rows.blob(Data(repeating: 0, count: 35))
            }
        ]
        for write in invalid {
            #expect(throws: MessageEventStateDigest.Failure.invalidRow) {
                try MessageEventStateDigest.compute(domain: "test-format-1") { table, rows in
                    if table == .metadata { try write(&rows) }
                }
            }
        }
        #expect(throws: MessageEventStateDigest.Failure.limitExceeded) {
            try MessageEventStateDigest.compute(domain: "test-format-1") { table, rows in
                if table == .metadata { try metadata(&rows); try rows.beginRow() }
            }
        }
    }

    @Test func fullBaselineCanFinishAfterRefusingOneMoreMembership() throws {
        let short = Data([1])
        let hashes = Data(repeating: 0, count: 256)
        let availability = Data(repeating: 0, count: 8)
        let facets = Data(repeating: 0, count: 100)
        let result = try MessageEventStateDigest.compute(domain: "test-format-1") { table, rows in
            switch table {
            case .metadata: try metadata(&rows)
            case .baseline:
                for id: Int64 in 1...250_000 {
                    try rows.beginRow()
                    try rows.integer(id)
                    try rows.blob(short)
                    try rows.blob(short)
                    try rows.integer(id)
                    try rows.integer(1)
                    try rows.blob(hashes)
                    try rows.blob(availability)
                    try rows.blob(facets)
                    try rows.blob(short)
                }
                #expect(throws: MessageEventStateDigest.Failure.limitExceeded) { try rows.beginRow() }
            case .events: break
            }
        }
        #expect(result.memberships == 250_000 && result.events == 0)
    }
}
