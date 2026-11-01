import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendTransitionTests {
    private typealias Run = (Int, Int, Int, String?)
    private let sent: Int64 = 800_000_000_000_000_000

    private func archive(_ text: String, _ runs: [Run], link: String? = nil) -> Data {
        let value = NSMutableAttributedString(string: text)
        for (location, length, index, guid) in runs {
            let range = NSRange(location: location, length: length)
            value.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: index), range: range)
            if let guid { value.addAttribute(.init("__kIMFileTransferGUIDAttributeName"), value: guid, range: range) }
            if index == 1, let link { value.addAttribute(.init("NSLink"), value: URL(string: link)!, range: range) }
        }
        return NSArchiver.archivedData(withRootObject: value)
    }

    private func observation(_ body: String?, runs: [Run] = [], summary: [String: Any]? = [:],
                             edited: Int64 = 0, retracted: Int64 = 0,
                             text: MessagesUndoSendObservation.Field<Data> = .null,
                             summaryOverride: MessagesUndoSendObservation.Field<Data>? = nil,
                             guid: String = "synthetic-message", isSent: MessagesUndoSendObservation.Field<Int64> = .value(1),
                             link: String? = nil,
                             bodyOverride: MessagesUndoSendObservation.Field<Data>? = nil) throws -> MessagesUndoSendObservation.Snapshot {
        let metadata: MessagesUndoSendObservation.Field<Data>
        if let summaryOverride { metadata = summaryOverride }
        else if let summary { metadata = .value(try PropertyListSerialization.data(fromPropertyList: summary, format: .binary, options: 0)) }
        else { metadata = .null }
        return .init(identity: .init(chatRowid: 3, chatGUID: "synthetic-chat", chatStyle: 45,
            messageRowid: 2, messageGUID: guid, sentDateRaw: sent, participantHandles: ["alice@example.com"]),
            isFromMe: .value(1), isSent: isSent, error: .value(0), dateEdited: .value(edited),
            dateRetracted: .value(retracted), serviceUTF8: .value(Data("iMessage".utf8)), textUTF8: text,
            attributedBody: bodyOverride ?? (body.map { .value(archive($0, runs, link: link)) } ?? .null), summaryInfo: metadata)
    }

    private func target(_ observation: MessagesUndoSendObservation.Snapshot, selected: Int = 0,
                        members: [MessagesAttachmentRetrievalState.Identity] = []) throws -> MessagesUndoSendTargetSnapshot.Snapshot {
        let part = try MessagesUndoSendPart.resolve(observation, partIndex: selected, deadline: .millisecondsFromNow(5000))
        let attachment = try MessagesUndoSendAttachmentBinding.bind(nativeParts: part.nativeParts, selectedIndex: selected, members: members)
        return .init(part: part, attachments: members, selectedAttachment: attachment)
    }

    private func assess(_ before: MessagesUndoSendTargetSnapshot.Snapshot,
                        _ after: MessagesUndoSendObservation.Snapshot,
                        members: [MessagesAttachmentRetrievalState.Identity] = []) throws -> MessagesUndoSendTransition.Assessment {
        try MessagesUndoSendTransition.assess(before: before, after: .init(observation: after, attachments: members),
                                              deadline: .millisecondsFromNow(5000))
    }

    private var one: [String: Any] { ["0": ["lo": 0, "le": 1]] }
    private var two: [String: Any] { ["0": ["lo": 0, "le": 1], "1": ["lo": 1, "le": 1]] }
    private var terminal: [String: Any] { ["rp": [0], "otr": one] }

    @Test func pristineTextAndSQLNullSummaryHavePositiveTransition() throws {
        for summary: [String: Any]? in [[:], nil] {
            let pre = try target(observation("A", runs: [(0, 1, 0, nil)], summary: summary))
            #expect(try assess(pre, observation(nil, summary: terminal, edited: sent + 1)) == .verified)
        }
    }

    @Test func staleSnapshotNeverVerifies() throws {
        let obs = try observation("A", runs: [(0, 1, 0, nil)])
        #expect(try assess(target(obs), obs) == .unverified(.unchanged))
    }

    @Test func shiftedSurvivorAndBothMultipartOrdersVerify() throws {
        let pre = try observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)])
        #expect(try assess(target(pre), observation("B", runs: [(0, 1, 1, nil)],
            summary: ["rp": [0], "otr": two], edited: sent + 1)) == .verified)
        #expect(try assess(target(pre, selected: 1), observation("A", runs: [(0, 1, 0, nil)],
            summary: ["rp": [1], "otr": two], edited: sent + 1)) == .verified)
    }

    @Test func finalRemainingPartPreservesPriorMarkersRegardlessOfOrder() throws {
        let pre = try target(observation("B", runs: [(0, 1, 1, nil)],
            summary: ["rp": [0], "otr": two], edited: sent + 1), selected: 1)
        #expect(try assess(pre, observation(nil, summary: ["rp": [1, 0], "otr": two], edited: sent + 1)) == .verified)
    }

    @Test func mixedAttachmentProjectionAndExactMembershipDeltaVerify() throws {
        let member = try #require(MessagesAttachmentRetrievalState.Identity(rowid: 10, guid: "synthetic-file"))
        let obs = try observation("\u{fffc}B", runs: [(0, 1, 0, "synthetic-file"), (1, 1, 1, nil)], text: .value(Data("B".utf8)))
        let pre = try target(obs, members: [member])
        let post = try observation("B", runs: [(0, 1, 1, nil)], summary: ["rp": [0], "otr": two], edited: sent + 1)
        #expect(try assess(pre, post) == .verified)
        #expect(try assess(pre, post, members: [member]) == .unverified(.membership))
        let textPre = try target(obs, selected: 1, members: [member])
        #expect(try assess(textPre, observation("\u{fffc}", runs: [(0, 1, 0, "synthetic-file")],
            summary: ["rp": [1], "otr": two], edited: sent + 1), members: [member]) == .verified)
    }

    @Test func editedHistoryCanDisappearOrRemainExactlyUnchanged() throws {
        let history: [String: Any] = ["0": [["d": 800_000_000, "t": archive("A", [(0, 1, 0, nil)]), "unknown": Data([3])]]]
        let pre = try target(observation("longer", runs: [(0, 6, 0, nil)],
            summary: ["ep": [0], "otr": one, "ec": history], edited: sent + 1))
        #expect(try assess(pre, observation(nil, summary: ["ep": [0], "rp": [0], "otr": one], edited: sent + 1)) == .verified)
        #expect(try assess(pre, observation(nil, summary: ["ep": [0], "rp": [0], "otr": one, "ec": history], edited: sent + 1)) == .verified)
        let changed: [String: Any] = ["0": [["d": 800_000_000, "t": archive("X", [(0, 1, 0, nil)])]]]
        #expect(try assess(pre, observation(nil, summary: ["ep": [0], "rp": [0], "otr": one, "ec": changed], edited: sent + 1)) == .unverified(.metadata))
    }

    @Test func malformedRemovedHistoryStillRefuses() throws {
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)],
            summary: ["ep": [0], "otr": one, "ec": ["0": [["d": 800_000_000, "t": Data([0, 1])]]]], edited: sent + 1))
        #expect(try assess(pre, observation(nil, summary: ["ep": [0], "rp": [0], "otr": one], edited: sent + 2)) == .unverified(.metadata))
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func malformedOrWrongRetractionMarkersNeverVerify(_ shape: Int) throws {
        let variants: [[Any]] = [[true], [-1], [Int64(Int32.max) + 1], [0, 0], [], [1]]
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)]))
        #expect(try assess(pre, observation(nil, summary: ["rp": variants[shape], "otr": one], edited: sent + 1)) == .unverified(.metadata))
    }

    @Test func unknownMetadataMustRemainByteExact() throws {
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)], summary: ["unknown": ["value": "\u{e9}"]]))
        var good = terminal; good["unknown"] = ["value": "\u{e9}"]
        #expect(try assess(pre, observation(nil, summary: good, edited: sent + 1)) == .verified)
        var bad = terminal; bad["unknown"] = ["value": "e\u{301}"]
        #expect(try assess(pre, observation(nil, summary: bad, edited: sent + 1)) == .unverified(.metadata))
        #expect(try assess(pre, observation(nil, summary: terminal, edited: sent + 1)) == .unverified(.metadata))
    }

    @Test func existingPristineOriginalMapMustAgreeWithBody() throws {
        for originals in [two, ["0": ["lo": 1, "le": 1], "1": ["lo": 0, "le": 1]]] {
            let pre = try target(observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)], summary: ["otr": originals]))
            let result = try assess(pre, observation("B", runs: [(0, 1, 1, nil)], summary: ["rp": [0], "otr": originals], edited: sent + 1))
            let first = originals["0"] as? [String: Int]
            #expect(result == (first?["lo"] == 0 ? .verified : .unverified(.metadata)))
        }
    }

    @Test func priorRetractionCannotInventMissingOriginalCoordinates() throws {
        let pre = try target(observation("B", runs: [(0, 1, 1, nil)], summary: ["rp": [0]], edited: sent + 1), selected: 1)
        #expect(try assess(pre, observation(nil, summary: ["rp": [0, 1], "otr": two], edited: sent + 2)) == .unverified(.metadata))
    }

    @Test func liveRetractedContradictionAndEditedMarkerPresenceDriftRefuse() throws {
        let pre = try target(observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)], summary: ["rp": [1], "otr": two]))
        #expect(try assess(pre, observation("B", runs: [(0, 1, 1, nil)], summary: ["rp": [0, 1], "otr": two], edited: sent + 1)) == .unverified(.metadata))
        let plain = try target(observation("A", runs: [(0, 1, 0, nil)]))
        #expect(try assess(plain, observation(nil, summary: ["ep": [], "rp": [0], "otr": one], edited: sent + 1)) == .unverified(.metadata))
    }

    @Test func retainedUnindexedPayloadAndLinkRetargetingRefuse() throws {
        let pre = try target(observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)], link: "https://example.com/original"))
        #expect(try assess(pre, observation("AB", runs: [(1, 1, 1, nil)], summary: ["rp": [0], "otr": two],
            edited: sent + 1, link: "https://example.com/original")) == .unverified(.body))
        #expect(try assess(pre, observation("B", runs: [(0, 1, 1, nil)], summary: ["rp": [0], "otr": two],
            edited: sent + 1, link: "https://example.org/changed")) == .unverified(.attributes))
    }

    @Test func identityStorageAndTimestampChangesRefuse() throws {
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)]))
        #expect(try assess(pre, observation(nil, summary: terminal, edited: sent + 1, guid: "different")) == .unverified(.identity))
        #expect(try assess(pre, observation(nil, summary: terminal, edited: sent + 1, isSent: .wrongType)) == .unverified(.storage))
        for edited in [Int64(-1), 0, 800_000_001, sent - 1] {
            #expect(try assess(pre, observation(nil, summary: terminal, edited: edited)) == .unverified(.timestamp))
        }
        #expect(try assess(pre, observation(nil, summary: terminal, edited: sent + 1, retracted: 1)) == .unverified(.timestamp))
    }

    @Test func missingCorruptAndOversizedMetadataCannotVerify() throws {
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)]))
        for field: MessagesUndoSendObservation.Field<Data> in [.null, .wrongType, .value(Data())] {
            #expect(try assess(pre, observation(nil, edited: sent + 1, summaryOverride: field)) == .unverified(.metadata))
        }
        #expect(try assess(pre, observation(nil, edited: sent + 1,
            summaryOverride: .value(Data(repeating: 0, count: 1_048_577)))) == .unverified(.resources))
    }

    @Test func cancellationAndDeadlinePropagate() throws {
        let pre = try target(observation("A", runs: [(0, 1, 0, nil)]))
        let post = try MessagesUndoSendPostSnapshot.Snapshot(observation: observation(nil, summary: terminal, edited: sent + 1), attachments: [])
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendTransition.assess(before: pre, after: post, deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            try MessagesUndoSendTransition.assess(before: pre, after: post, deadline: .millisecondsFromNow(0))
        }
    }

    @Test func twoAttachmentsRequireExactlySelectedMembershipRemovalInBothOrders() throws {
        let first = try #require(MessagesAttachmentRetrievalState.Identity(rowid: 10, guid: "synthetic-first"))
        let second = try #require(MessagesAttachmentRetrievalState.Identity(rowid: 11, guid: "synthetic-second"))
        let source = try observation("\u{fffc}\u{fffc}", runs: [(0, 1, 0, "synthetic-first"), (1, 1, 1, "synthetic-second")])
        for selected in [0, 1] {
            let survivor = selected == 0 ? second : first
            let removed = selected == 0 ? first : second
            let pre = try target(source, selected: selected, members: [first, second])
            let post = try observation("\u{fffc}", runs: [(0, 1, 1 - selected, String(decoding: survivor.guid, as: UTF8.self))],
                summary: ["rp": [selected], "otr": two], edited: sent + 1)
            #expect(try assess(pre, post, members: [survivor]) == .verified)
            #expect(try assess(pre, post, members: [removed]) == .unverified(.membership))
            #expect(try assess(pre, post, members: []) == .unverified(.membership))
            #expect(try assess(pre, post, members: [survivor, survivor]) == .unverified(.membership))
        }
    }

    @Test func survivorHistoryAndUnknownOriginalFieldsMustBePreserved() throws {
        let history: [String: Any] = ["1": [["d": 800_000_000, "t": archive("B", [(0, 1, 1, nil)]),
            "unknown": ["opaque": Data([1, 2])]]]]
        let originals: [String: Any] = ["0": ["lo": 0, "le": 1, "extra": Data([3])],
                                      "1": ["lo": 1, "le": 1]]
        let pre = try target(observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)],
            summary: ["ep": [1], "otr": originals, "ec": history], edited: sent + 1))
        let good: [String: Any] = ["ep": [1], "rp": [0], "otr": originals, "ec": history]
        #expect(try assess(pre, observation("B", runs: [(0, 1, 1, nil)], summary: good, edited: sent + 2)) == .verified)
        var lostHistory = good; lostHistory.removeValue(forKey: "ec")
        var lostOriginalField = good; lostOriginalField["otr"] = two
        var changedHistory = good
        changedHistory["ec"] = ["1": [["d": 800_000_000, "t": archive("B", [(0, 1, 1, nil)]),
            "unknown": ["opaque": Data([1, 3])]]]]
        for summary in [lostHistory, lostOriginalField, changedHistory] {
            #expect(try assess(pre, observation("B", runs: [(0, 1, 1, nil)], summary: summary, edited: sent + 2)) == .unverified(.metadata))
        }
    }

    @Test func priorMarkersCannotDisappearAndUnrelatedMarkersCannotAppear() throws {
        let pre = try target(observation("B", runs: [(0, 1, 1, nil)],
            summary: ["rp": [0], "otr": two], edited: sent + 1), selected: 1)
        for markers in [[1], [0, 1, 2]] {
            #expect(try assess(pre, observation(nil, summary: ["rp": markers, "otr": two], edited: sent + 2)) == .unverified(.metadata))
        }
    }

    @Test(arguments: [false, true])
    func duplicateUnknownAttributesCannotVerifyEvenWhenSelectedBodyDisappears(nested: Bool) throws {
        let value = NSMutableAttributedString(string: "A")
        value.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: .init(location: 0, length: 1))
        let fields: [NSAttributedString.Key: Any] = nested
            ? [.init("nested"): ["synthetic-opaque-a": "first", "synthetic-opaque-b": "second"] as NSDictionary]
            : [.init("synthetic-opaque-a"): "first", .init("synthetic-opaque-b"): "second"]
        value.addAttributes(fields, range: .init(location: 0, length: 1))
        var data = NSArchiver.archivedData(withRootObject: value)
        let range = try #require(data.range(of: Data("synthetic-opaque-b".utf8)))
        data.replaceSubrange(range, with: Data("synthetic-opaque-a".utf8))
        #expect(NativeMessageParts.decode(data, requireExactText: true).status == .decoded)
        let before = try target(observation("A", runs: [(0, 1, 0, nil)], bodyOverride: .value(data)))
        #expect(try assess(before, observation(nil, summary: terminal, edited: sent + 1)) == .unverified(.attributes))
    }

    @Test(arguments: [false, true])
    func duplicateUnknownPostAttributesCannotVerify(nested: Bool) throws {
        let extras: [NSAttributedString.Key: Any] = nested
            ? [.init("nested"): ["synthetic-opaque-a": "first", "synthetic-opaque-b": "second"] as NSDictionary]
            : [.init("synthetic-opaque-a"): "first", .init("synthetic-opaque-b"): "second"]
        let preBody = NSMutableAttributedString(string: "AB")
        preBody.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: .init(location: 0, length: 1))
        preBody.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 1), range: .init(location: 1, length: 1))
        preBody.addAttributes(extras, range: .init(location: 1, length: 1))
        let before = try target(observation("AB", runs: [], bodyOverride: .value(NSArchiver.archivedData(withRootObject: preBody))))
        let postBody = NSMutableAttributedString(string: "B")
        postBody.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 1), range: .init(location: 0, length: 1))
        postBody.addAttributes(extras, range: .init(location: 0, length: 1))
        var data = NSArchiver.archivedData(withRootObject: postBody)
        #expect(try assess(before, observation("B", summary: ["rp": [0], "otr": two], edited: sent + 1,
            bodyOverride: .value(data))) == .verified)
        let range = try #require(data.range(of: Data("synthetic-opaque-b".utf8)))
        data.replaceSubrange(range, with: Data("synthetic-opaque-a".utf8))
        #expect(NativeMessageParts.decode(data, requireExactText: true).status == .decoded)
        #expect(try assess(before, observation("B", summary: ["rp": [0], "otr": two], edited: sent + 1,
            bodyOverride: .value(data))) == .unverified(.attributes))
    }

    @Test func removedHistoryStillRequiresFiniteUnknownValues() throws {
        let values: [Any] = [Double.infinity, -Double.infinity, Double.nan,
            Date(timeIntervalSinceReferenceDate: Double.infinity),
            Date(timeIntervalSinceReferenceDate: Double.nan)]
        for value in values {
            let history: [String: Any] = ["0": [["d": 800_000_000,
                "t": archive("A", [(0, 1, 0, nil)]), "unknown": ["nested": [value]]]]]
            let before = try target(observation("A", runs: [(0, 1, 0, nil)],
                summary: ["ep": [0], "otr": one, "ec": history], edited: sent + 1))
            for keepEmpty in [false, true] {
                var summary: [String: Any] = ["ep": [0], "rp": [0], "otr": one]
                if keepEmpty { summary["ec"] = [String: Any]() }
                #expect(try assess(before, observation(nil, summary: summary, edited: sent + 2)) == .unverified(.metadata))
            }
            let retained: [String: Any] = ["1": [["d": 800_000_000, "t": archive("B", [(0, 1, 1, nil)])]]]
            var combined = history; combined["1"] = retained["1"]
            let multipart = try target(observation("AB", runs: [(0, 1, 0, nil), (1, 1, 1, nil)],
                summary: ["ep": [0, 1], "otr": two, "ec": combined], edited: sent + 1))
            #expect(try assess(multipart, observation("B", runs: [(0, 1, 1, nil)],
                summary: ["ep": [0, 1], "rp": [0], "otr": two, "ec": retained], edited: sent + 2)) == .unverified(.metadata))
        }
        let finite: [String: Any] = ["0": [["d": 800_000_000,
            "t": archive("A", [(0, 1, 0, nil)]), "unknown": ["nested": [Double(1.5), Date(timeIntervalSinceReferenceDate: 1)]]]]]
        let before = try target(observation("A", runs: [(0, 1, 0, nil)],
            summary: ["ep": [0], "otr": one, "ec": finite], edited: sent + 1))
        #expect(try assess(before, observation(nil, summary: ["ep": [0], "rp": [0], "otr": one],
            edited: sent + 2)) == .verified)
    }
}
