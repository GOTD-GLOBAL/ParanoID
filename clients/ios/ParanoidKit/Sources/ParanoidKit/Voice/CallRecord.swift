import Foundation

/// One finished call, as this phone saw it.
///
/// The protocol keeps no call history: a call is a set of authenticated
/// controls and nothing about it is ever written to the sealed snapshot or to
/// the server (`docs/protocol/voice-v1.md:27-31`, `docs/clients/core/voice-calls.md:31-33`).
/// That rule is unchanged here. This is bookkeeping the device does for itself
/// out of the terminal transition it already went through, the way a phone
/// keeps its own recents: nothing new is sent, nothing new is stored on the
/// server, and the peer is told nothing it was not told before.
public struct CallRecord: Equatable, Sendable, Codable, Identifiable {
    /// What the chat says happened.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Answered, placed from this device.
        case outgoing
        /// Answered, placed by the peer.
        case incoming
        /// The peer called and this device never answered.
        case missed
        /// This device refused the ring.
        case declined
        /// The peer refused the ring.
        case rejected
        /// This device gave up before the peer answered.
        case cancelled
        /// The peer never picked up.
        case unanswered
        /// The peer was already in a call.
        case busy
        /// The call could not be established at all.
        case failed

        /// Whether this is the outcome a missed-call notice is raised for.
        public var isMissed: Bool { self == .missed }
    }

    /// The call identifier, which is also this record's identity: one call
    /// leaves exactly one row however many times the view is republished.
    public let id: String
    /// The peer.
    public let account: String
    public let kind: Kind
    /// Whether either side had a camera on.
    public let video: Bool
    /// How long the call was actually connected. Zero for every outcome that
    /// never reached media.
    public let durationSeconds: Int64
    /// The message this row stands after, so the chat keeps one order without
    /// inventing a clock: the core stores no time for a message, so a call is
    /// anchored to the last message that existed when it ended. `nil` means the
    /// conversation had no messages yet; "unavailable" means its history was
    /// unavailable and keeps the row in the trailing fallback on both clients.
    public let afterMessageId: String?

    public init(id: String,
                account: String,
                kind: Kind,
                video: Bool,
                durationSeconds: Int64,
                afterMessageId: String?) {
        self.id = id
        self.account = account
        self.kind = kind
        self.video = video
        self.durationSeconds = durationSeconds
        self.afterMessageId = afterMessageId
    }

    /// What one terminal transition means for the chat.
    ///
    /// The seven wire reasons are the closed set of `voice-v1.md:53`, and the
    /// same reason means different things on the two sides of the same call:
    /// `reject` is «вы отклонили» for the device that pressed «Отклонить» and
    /// «собеседник отклонил» for the one that heard it, and `cancel` is a
    /// caller giving up — which is a missed call for the callee. Direction is
    /// therefore part of the answer, not a detail.
    public static func kind(outgoing: Bool,
                            connected: Bool,
                            reason: CallBody.EndReason) -> Kind {
        if connected { return outgoing ? .outgoing : .incoming }
        switch reason {
        case .reject: return outgoing ? .rejected : .declined
        case .cancel: return outgoing ? .cancelled : .missed
        case .hangup: return outgoing ? .cancelled : .missed
        case .timeout: return outgoing ? .unanswered : .missed
        case .busy: return outgoing ? .busy : .missed
        case .failed, .unavailable: return .failed
        }
    }
}

/// The terminal facts of one call, published once by ``CallController`` at the
/// moment it ends.
///
/// It exists because the public view cannot carry them: `CallPresentation`
/// reads its elapsed time off the live call, and by the time a screen sees
/// `state == .ended` there is no live call left to read — the duration of the
/// call that just finished would always be zero (`CallController.finish`,
/// `MainActivity.java:307`).
public struct CallTermination: Equatable, Sendable {
    public let callId: String
    public let account: String
    /// Whether this device placed the call.
    public let outgoing: Bool
    /// Whether media was ever connected.
    public let connected: Bool
    public let video: Bool
    public let durationSeconds: Int64
    public let reason: CallBody.EndReason

    public init(callId: String,
                account: String,
                outgoing: Bool,
                connected: Bool,
                video: Bool,
                durationSeconds: Int64,
                reason: CallBody.EndReason) {
        self.callId = callId
        self.account = account
        self.outgoing = outgoing
        self.connected = connected
        self.video = video
        self.durationSeconds = durationSeconds
        self.reason = reason
    }

    /// The row this termination becomes, anchored to the last message the
    /// conversation had when it ended.
    public func record(afterMessageId: String?) -> CallRecord {
        CallRecord(id: callId,
                   account: account,
                   kind: CallRecord.kind(outgoing: outgoing, connected: connected, reason: reason),
                   video: video,
                   durationSeconds: durationSeconds,
                   afterMessageId: afterMessageId)
    }
}

public extension CallController.Observer {
    /// Most observers only draw the live view; ignoring the terminal facts is
    /// the default so that a call log stays opt-in.
    func finished(_ termination: CallTermination) {}
}
