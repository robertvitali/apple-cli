import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendMetadataComparisonTests {
    private typealias Value = MessageSummaryPlist.Value

    private func equal(_ a: Value, _ b: Value) throws -> Bool {
        var budget = MessageSummaryPlist.Budget()
        return try MessagesUndoSendMetadataComparison.equal(a, b, budget: &budget, checkpoint: {})
    }

    @Test func comparesCompleteNestedTreesWithoutDictionaryOrder() throws {
        let a: Value = .dictionary(["unknown": .array([.integer(3), .data(Data([0, 255])), .null]),
                                    "label": .string("synthetic")])
        let b: Value = .dictionary(["label": .string("synthetic"),
                                    "unknown": .array([.integer(3), .data(Data([0, 255])), .null])])
        #expect(try equal(a, b))
        #expect(try !equal(a, .dictionary(["label": .string("synthetic")])))
        #expect(try !equal(.array([.integer(1), .integer(2)]), .array([.integer(2), .integer(1)])))
    }

    @Test func stringsAndKeysRequireExactUTF8Bytes() throws {
        let a = "\u{e9}", b = "e\u{301}"
        #expect(a == b)
        #expect(try !equal(.string(a), .string(b)))
        #expect(try !equal(.dictionary([a: .integer(1)]), .dictionary([b: .integer(1)])))
        #expect(try !equal(.dictionary(["key": .string(a)]), .dictionary(["key": .string(b)])))
    }

    @Test func typeTagsAndFloatingBitPatternsRemainDistinct() throws {
        #expect(try !equal(.boolean(true), .integer(1)))
        #expect(try !equal(.real(1), .integer(1)))
        #expect(try !equal(.date(1), .real(1)))
        #expect(try !equal(.real(0.0), .real(-0.0)))
        #expect(try !equal(.date(0.0), .date(-0.0)))
        #expect(try !equal(.real(.nan), .real(.nan)))
        #expect(try !equal(.date(.infinity), .date(.infinity)))
        #expect(try equal(.date(1.25), .date(1.25)))
    }

    @Test func exhaustedVisitBudgetFailsWithoutRefund() throws {
        var budget = MessageSummaryPlist.Budget()
        budget.remainingVisits = 1
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) {
            try MessagesUndoSendMetadataComparison.equal(.array([.integer(1)]), .array([.integer(1)]),
                budget: &budget, checkpoint: {})
        }
        #expect(budget.remainingVisits == 0)
    }

    @Test func byteBudgetIsSharedAcrossComparisons() throws {
        var budget = MessageSummaryPlist.Budget()
        budget.remainingBytes = 4
        #expect(try MessagesUndoSendMetadataComparison.equal(.string("ab"), .string("ab"), budget: &budget, checkpoint: {}))
        #expect(budget.remainingBytes == 0)
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) {
            try MessagesUndoSendMetadataComparison.equal(.data(Data([1])), .data(Data([1])), budget: &budget, checkpoint: {})
        }
    }

    @Test func nestedDepthAndContainerLimitsFailClosed() throws {
        var deep: Value = .integer(1)
        for _ in 0..<32 { deep = .array([deep]) }
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try equal(deep, deep) }
        let wide: Value = .array(Array(repeating: .integer(1), count: 4097))
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try equal(wide, wide) }
    }

    @Test func cancellationPropagatesBeforeComparison() throws {
        enum Cancelled: Error { case stopped }
        var budget = MessageSummaryPlist.Budget()
        #expect(throws: Cancelled.self) {
            try MessagesUndoSendMetadataComparison.equal(.integer(1), .integer(1), budget: &budget,
                                                        checkpoint: { throw Cancelled.stopped })
        }
        #expect(budget.remainingVisits == 65536)
    }
}
