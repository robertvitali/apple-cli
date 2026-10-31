import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendPreconditionsTests {
    private let sent: Int64 = 800_000_000_000_000_000

    private func snapshot(fromMe: MessagesUndoSendObservation.Field<Int64> = .value(1),
                          sentFlag: MessagesUndoSendObservation.Field<Int64> = .value(1),
                          error: MessagesUndoSendObservation.Field<Int64> = .value(0),
                          service: MessagesUndoSendObservation.Field<Data> = .value(Data("iMessage".utf8)))
        -> MessagesUndoSendObservation.Snapshot {
        .init(identity: .init(chatRowid: 3, chatGUID: "synthetic-chat", chatStyle: 45,
            messageRowid: 2, messageGUID: "synthetic-message", sentDateRaw: sent,
            participantHandles: ["alice@example.com"]),
            isFromMe: fromMe, isSent: sentFlag, error: error,
            dateEdited: .null, dateRetracted: .null, serviceUTF8: service,
            textUTF8: .null, attributedBody: .null, summaryInfo: .null)
    }

    @Test func satisfiedDoesNotClaimPartOrRetractionQualification() {
        // All body and retraction fields remain unavailable. This predicate
        // checks ownership, transport and time only, never execution eligibility.
        #expect(MessagesUndoSendPreconditions.assess(snapshot(),
            now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .satisfied)
    }

    @Test(arguments: [0, -1, 2, Int64.max])
    func receivedOrNonBooleanOwnershipRefused(_ flag: Int64) {
        #expect(MessagesUndoSendPreconditions.assess(snapshot(fromMe: .value(flag)),
            now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .notOwnSentMessage)
    }

    @Test func unknownOwnershipAndSentStateRefused() {
        for value: MessagesUndoSendObservation.Field<Int64> in [.null, .wrongType] {
            #expect(MessagesUndoSendPreconditions.assess(snapshot(fromMe: value),
                now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .notOwnSentMessage)
            #expect(MessagesUndoSendPreconditions.assess(snapshot(sentFlag: value),
                now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .notOwnSentMessage)
        }
    }

    @Test(arguments: [0, -1, 2, Int64.max])
    func unsentOrNonBooleanSentRefused(_ flag: Int64) {
        #expect(MessagesUndoSendPreconditions.assess(snapshot(sentFlag: .value(flag)),
            now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .notOwnSentMessage)
    }

    @Test func failedOrUnknownDeliveryRefused() {
        for value: MessagesUndoSendObservation.Field<Int64> in [.value(1), .value(-1), .null, .wrongType] {
            #expect(MessagesUndoSendPreconditions.assess(snapshot(error: value),
                now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .deliveryStateUnavailable)
        }
    }

    @Test(arguments: ["SMS", "MMS", "RCS", "imessage", "iMessage ", "iMessage\0", ""])
    func otherTransportsAndNonExactServiceRefused(_ service: String) {
        #expect(MessagesUndoSendPreconditions.assess(snapshot(service: .value(Data(service.utf8))),
            now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .unsupportedService)
    }

    @Test func absentMalformedOrInvalidUTF8ServiceRefused() {
        for value: MessagesUndoSendObservation.Field<Data> in [.null, .wrongType, .value(Data([255]))] {
            #expect(MessagesUndoSendPreconditions.assess(snapshot(service: value),
                now: Date(timeIntervalSinceReferenceDate: 800_000_010)) == .unsupportedService)
        }
    }

    @Test func timeIsReassessedAtEachCall() {
        let value = snapshot()
        #expect(MessagesUndoSendPreconditions.assess(value,
            now: Date(timeIntervalSinceReferenceDate: 800_000_119)) == .satisfied)
        #expect(MessagesUndoSendPreconditions.assess(value,
            now: Date(timeIntervalSinceReferenceDate: 800_000_120)) == .expired)
        #expect(MessagesUndoSendPreconditions.assess(value,
            now: Date(timeIntervalSinceReferenceDate: 799_999_999)) == .invalidTimestamp)
    }
}
