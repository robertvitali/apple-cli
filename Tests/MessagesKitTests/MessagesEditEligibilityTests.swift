import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditEligibilityTests {
    private let sentSeconds: Int64 = 800_000_000
    private func context(revisions: [String]?, otherRevisions: [String]? = nil, originals: Any? = nil) throws -> ChatDB.ExactNativeEditContext {
        var fields: [String: Any] = [:]
        if let revisions {
            fields["ec"] = ["0": revisions.map { ["d": sentSeconds, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))] as [String: Any] }]
            fields["ep"] = [0]
        }
        if let otherRevisions {
            var history = fields["ec"] as? [String: Any] ?? [:]
            history["1"] = otherRevisions.map { ["d": sentSeconds, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))] as [String: Any] }
            fields["ec"] = history
            fields["ep"] = revisions == nil ? [1] : [0, 1]
        }
        var coordinates: [String: [String: Int]] = [:]
        if let first = revisions?.first { coordinates["0"] = ["lo": 0, "le": first.utf16.count] }
        if let first = otherRevisions?.first { coordinates["1"] = ["lo": 20, "le": first.utf16.count] }
        if !coordinates.isEmpty { fields["otr"] = coordinates }
        if let originals { fields["otr"] = originals }
        var budget = NativeEditContextDecoder.Budget()
        let summary = try NativeEditContextDecoder.decode(PropertyListSerialization.data(fromPropertyList: fields,
            format: .binary, options: 0), budget: &budget, requireExactHistoryText: true)
        return .init(date_edited: NativeMessageStatusDecoder.timestamp(raw: revisions == nil ? 0 : sentSeconds),
            date_retracted: NativeMessageStatusDecoder.timestamp(raw: 0), summary_info: summary)
    }

    private func check(age: Double, revisions: [String]? = nil, raw: Int64? = nil) throws -> MessagesEditEligibility.Assessment {
        MessagesEditEligibility.assess(sentDateRaw: raw ?? sentSeconds * 1_000_000_000,
            partIndex: 0, currentText: "current", context: try context(revisions: revisions),
            now: Date(timeIntervalSince1970: Double(sentSeconds) + MessageTime.appleUnixOffset + age))
    }

    @Test func rejectsExpiryAndFutureDatesAtBoundary() throws {
        #expect(try check(age: 899) == .eligible)
        #expect(try check(age: 900) == .expired)
        #expect(try check(age: 901) == .expired)
        #expect(try check(age: -1) == .invalidTimestamp)
        #expect(try check(age: 0, raw: 0) == .invalidTimestamp)
        #expect(try check(age: 0, raw: sentSeconds) == .invalidTimestamp)
    }

    @Test func fifthEditAllowedButSixthRefused() throws {
        #expect(try check(age: 1, revisions: ["original", "a", "b", "c", "current"]) == .eligible)
        #expect(try check(age: 1, revisions: ["original", "a", "b", "c", "d", "current"]) == .editLimitReached)
    }

    @Test func incompleteHistoryCannotSupplyEditCount() throws {
        #expect(try check(age: 1, revisions: []) == .historyUnavailable)
        #expect(try check(age: 1, revisions: ["current"]) == .historyUnavailable)
        #expect(try check(age: 1, revisions: ["original", "different"]) == .historyUnavailable)
    }

    @Test func originalEditorBudgetUsesUTF8Bytes() throws {
        for (text, eligible) in [(String(repeating: "a", count: 4096), true),
                                 (String(repeating: "a", count: 4097), false),
                                 (String(repeating: "é", count: 2048), true),
                                 (String(repeating: "é", count: 2049), false)] {
            let result = MessagesEditEligibility.assess(sentDateRaw: sentSeconds * 1_000_000_000,
                partIndex: 0, currentText: text, context: try context(revisions: nil),
                now: Date(timeIntervalSince1970: Double(sentSeconds) + MessageTime.appleUnixOffset + 1))
            #expect((result == .eligible) == eligible)
        }
    }

    @Test func malformedOriginalMetadataRefusesEligibility() throws {
        let invalid: [Any] = ["wrong-type", ["00": ["lo": 0, "le": 8]],
            ["0": ["lo": -1, "le": 8]], ["0": ["lo": 0, "le": 999]],
            ["0": ["lo": Int64.max, "le": 8]]]
        for originals in invalid {
            let value = MessagesEditEligibility.assess(sentDateRaw: sentSeconds * 1_000_000_000,
                partIndex: 0, currentText: "current",
                context: try context(revisions: ["original", "current"], originals: originals),
                now: Date(timeIntervalSince1970: Double(sentSeconds) + MessageTime.appleUnixOffset + 1))
            #expect(value == .historyUnavailable)
        }
    }

    @Test func priorEditsToOtherPartsStillConsumeMessageLimit() throws {
        let value = MessagesEditEligibility.assess(sentDateRaw: sentSeconds * 1_000_000_000,
            partIndex: 0, currentText: "current", context: try context(revisions: ["original", "current"],
                otherRevisions: ["original", "a", "b", "c", "other"]),
            now: Date(timeIntervalSince1970: Double(sentSeconds) + MessageTime.appleUnixOffset + 1))
        #expect(value == .editLimitReached)
    }

}
