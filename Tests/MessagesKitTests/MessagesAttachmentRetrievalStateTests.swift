import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentRetrievalStateTests {
    private typealias State = MessagesAttachmentRetrievalState

    private func identity(_ rowid: Int64, _ guid: String) throws -> State.Identity {
        try #require(State.Identity(rowid: rowid, guid: guid))
    }

    private func observed(_ identity: State.Identity, raw: Int64?, file: State.FileObservation = .readableRegularFile) -> State.Observation {
        let value = raw.map { SQLiteReader.Row.Value.integer($0) } ?? .null
        return .init(identity: identity,
                     transfer: NativeAttachmentTransferDecoder.decode(storageType: .text(raw == nil ? "null" : "integer"), value: value),
                     file: file)
    }

    @Test func nativeStatesRequireIndependentFileEvidence() throws {
        let id = try identity(1, "synthetic-attachment")
        for raw in Int64(0)...9 {
            let expected: State.Outcome = raw == 5 ? .downloaded : ((6...8).contains(raw) ? .failed : .pending)
            #expect(State.evaluate(expected: [id], observed: [observed(id, raw: raw)], completeJoin: true) == expected)
            #expect(State.evaluate(expected: [id], observed: [observed(id, raw: raw, file: .unavailable)], completeJoin: true) == .unavailable)
        }
        #expect(State.evaluate(expected: [id], observed: [observed(id, raw: 5, file: .missing)], completeJoin: true) == .missing)
        #expect(State.evaluate(expected: [id], observed: [observed(id, raw: 3, file: .missing)], completeJoin: true) == .pending)
    }

    @Test func incompleteChangedAndDuplicateMembershipNeverSucceeds() throws {
        let a = try identity(1, "synthetic-a"), b = try identity(2, "synthetic-b")
        let done = [observed(a, raw: 5), observed(b, raw: 5)]
        #expect(State.evaluate(expected: [a,b], observed: Array(done.reversed()), completeJoin: true) == .downloaded)
        #expect(State.evaluate(expected: [a,b], observed: done, completeJoin: false) == .unavailable)
        #expect(State.evaluate(expected: [a,b], observed: [done[0]], completeJoin: true) == .unavailable)
        #expect(State.evaluate(expected: [a], observed: [done[1]], completeJoin: true) == .unavailable)
        #expect(State.evaluate(expected: [a,b], observed: [done[0],done[0]], completeJoin: true) == .unavailable)
        #expect(State.evaluate(expected: [a,a], observed: [done[0],done[0]], completeJoin: true) == .unavailable)
        #expect(State.evaluate(expected: [], observed: [], completeJoin: true) == .unavailable)
        #expect(State.evaluate(expected: [a], observed: [], completeJoin: true) == .unavailable)
        let duplicateGUID = try identity(3, "synthetic-a")
        #expect(State.evaluate(expected: [a,duplicateGUID], observed: [done[0],observed(duplicateGUID,raw:5)], completeJoin: true) == .unavailable)
        let duplicateRow = try identity(1, "synthetic-c")
        #expect(State.evaluate(expected: [a,duplicateRow], observed: [done[0],observed(duplicateRow,raw:5)], completeJoin: true) == .unavailable)
    }

    @Test func mixedUnknownAndFailureStatesDoNotDisappear() throws {
        let a = try identity(1, "synthetic-a"), b = try identity(2, "synthetic-b")
        for raw: Int64? in [nil, -1, 10, Int64.max] {
            #expect(State.evaluate(expected: [a,b], observed: [observed(a,raw:5),observed(b,raw:raw)], completeJoin:true) == .unavailable)
        }
        for raw in Int64(6)...8 {
            #expect(State.evaluate(expected: [a,b], observed: [observed(a,raw:3),observed(b,raw:raw)], completeJoin:true) == .failed)
        }
        let missingInspection = State.Observation(identity:b, transfer:nil, file:.readableRegularFile)
        #expect(State.evaluate(expected:[a,b], observed:[observed(a,raw:5),missingInspection], completeJoin:true) == .unavailable)
    }

    @Test func identitiesAreBoundedAndByteExact() throws {
        for guid in ["", "invalid\0guid", "invalid\nguid", String(repeating:"x",count:4_097)] {
            #expect(State.Identity(rowid:1,guid:guid) == nil)
        }
        #expect(State.Identity(rowid:0,guid:"synthetic") == nil)
        #expect(State.Identity(rowid:-1,guid:"synthetic") == nil)
        let composed = try identity(1,"\u{e9}"), decomposed = try identity(1,"e\u{301}")
        #expect(composed != decomposed)
        #expect(State.evaluate(expected:[composed], observed:[observed(decomposed,raw:5)], completeJoin:true) == .unavailable)
        let ids = try (1...1_025).map { try identity(Int64($0), "synthetic-\($0)") }
        #expect(State.evaluate(expected:ids, observed:ids.map { observed($0,raw:5) }, completeJoin:true) == .unavailable)
        let bounded = Array(ids.prefix(1_024))
        #expect(State.evaluate(expected:bounded, observed:bounded.map { observed($0,raw:5) }, completeJoin:true) == .downloaded)
    }
}
