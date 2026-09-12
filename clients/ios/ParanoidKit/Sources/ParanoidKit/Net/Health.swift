import Foundation

/// What `GET /health` says about the server this client is pinned to.
///
/// The port of the discovery step of `RealtimeLoop.java:178-181`, and of the
/// rule it implements (`docs/protocol/realtime-v1.md:159-162`): `/health`
/// keeps its status and protocol members and *may* advertise
/// `realtime: "signed-long-poll-v1"`. The flag is capability discovery only —
/// it grants no authority, says nothing about the database and never relaxes
/// trust. A v2 server without it is not broken: the client stays on the
/// retained challenge-message transport.
public struct Health: Sendable, Equatable {
    /// The only `protocol` this client talks (`RealtimeLoop.java:179`).
    public static let protocolName = "paranoid-self-service-v2"
    /// The `realtime` flag of the long-poll extension
    /// (`RealtimeLoop.java:180`).
    public static let realtimeName = "signed-long-poll-v1"

    /// True only for the exact string `signed-long-poll-v1`; a missing member,
    /// a different string or a non-string all mean "no long poll here".
    public let realtime: Bool

    public init(realtime: Bool) {
        self.realtime = realtime
    }

    /// Reads one `/health` body.
    ///
    /// - Throws: `TransportError.invalidReply` when the text is not one JSON
    ///   object, `TransportError.protocolMismatch` when `status` is not `ok`
    ///   or `protocol` is not `paranoid-self-service-v2`. Android's
    ///   `optString` answers `""` for a missing or non-string member and the
    ///   comparison then fails, which is what the `as? String ?? ""` below
    ///   reproduces.
    public static func parse(_ text: String) throws -> Health {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw TransportError.invalidReply
        }
        return try parse(object)
    }

    /// The same rule over an already decoded body.
    public static func parse(_ object: [String: Any]) throws -> Health {
        let status = object["status"] as? String ?? ""
        let name = object["protocol"] as? String ?? ""
        guard status == "ok", name == Self.protocolName else {
            throw TransportError.protocolMismatch
        }
        return Health(realtime: (object["realtime"] as? String ?? "") == Self.realtimeName)
    }
}
