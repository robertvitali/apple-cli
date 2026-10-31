import Foundation

/// Necessary ownership, delivery, transport and timing checks only. A satisfied
/// result does not qualify a native part, retraction markers or a UI route, and
/// never authorizes execution. Call again with fresh observations and time
/// immediately before any separately qualified native action.
enum MessagesUndoSendPreconditions {
    enum Assessment: Equatable {
        case satisfied, notOwnSentMessage, deliveryStateUnavailable
        case unsupportedService, expired, invalidTimestamp
    }

    static func assess(_ observation: MessagesUndoSendObservation.Snapshot,
                       now: Date) -> Assessment {
        guard observation.isFromMe == .value(1), observation.isSent == .value(1) else {
            return .notOwnSentMessage
        }
        guard observation.error == .value(0) else { return .deliveryStateUnavailable }
        guard observation.serviceUTF8 == .value(Data("iMessage".utf8)) else {
            return .unsupportedService
        }
        switch MessagesUndoSendTimeWindow.assess(sentDateRaw: observation.identity.sentDateRaw, now: now) {
        case .withinWindow: return .satisfied
        case .expired: return .expired
        case .invalidTimestamp: return .invalidTimestamp
        }
    }
}
