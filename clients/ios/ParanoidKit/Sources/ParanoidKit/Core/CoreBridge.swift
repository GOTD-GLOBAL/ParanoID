import Foundation
import ParanoidCoreFFI

/// Why one core command failed.
///
/// Mirrors `SelfServiceClient.nativeCall` on Android
/// (`SelfServiceClient.java:55-61`): a `null` reply is a native failure and a
/// reply carrying an `error` member rejects the operation with that code.
public enum CoreError: Error, Equatable, Sendable {
    /// The bridge returned NULL or something that is not a JSON object. The
    /// bridge contract (`bridge/include/paranoid_core.h`) rules both out, so
    /// this signals a broken native layer, not a rejected operation.
    case nativeFailure
    /// The core answered `{"error":"<code>"}` with this code, for example
    /// `invalid_state`, `invalid_request` or `input_limit`.
    case rejected(String)
}

/// One successful reply of `paranoid_client_core::command`.
///
/// `text` is the reply exactly as the core produced it and `state` is the
/// verbatim top-level `"state"` member (see `JsonSpan`): that text is what the
/// caller persists and feeds into the next command, and comparing it with the
/// current snapshot as a string replaces Android's `org.json` round trip
/// (`SelfServiceClient.java:73-76`). `object` is the decoded reply for member
/// access in the style of `org.json` (`acceptance`, `call_event`, `public`,
/// `dialogs`, ...). Replies contain private keys and plaintext: never log
/// them.
public struct CoreReply {
    /// The whole reply, verbatim.
    public let text: String
    /// The top-level `"state"` value, verbatim; `nil` for replies without a
    /// snapshot.
    public let state: String?
    /// The decoded top-level object of the reply.
    public let object: [String: Any]

    /// `state.version` of the reply, or `nil` when the reply has no state
    /// object with an integer version.
    public var stateVersion: Int? {
        guard let state = object["state"] as? [String: Any] else { return nil }
        return state["version"] as? Int
    }
}

/// Stateless Swift adapter over the C-ABI bridge (`paranoid_core_command` /
/// `paranoid_core_free`), the counterpart of `CoreBridge.java`.
///
/// The core is a pure function of its two arguments and keeps no global
/// state, so calls may come from any thread; every state rule and the input
/// limits (8 MiB state, 65536-byte request) stay inside the core.
public enum CoreBridge {
    /// Runs one core command over `state` (the current snapshot text, `""`
    /// for a fresh identity) and the JSON `request`.
    ///
    /// - Throws: `CoreError.rejected` with the core's code, or
    ///   `CoreError.nativeFailure` when the bridge breaks its contract.
    public static func command(state: String, request: String) throws -> CoreReply {
        // Swift hands a `String` to `const char *` as a NUL-terminated copy; an
        // interior NUL would silently truncate the document, so it is refused
        // with the code the bridge itself uses for unusable arguments.
        guard !state.utf8.contains(0), !request.utf8.contains(0) else {
            throw CoreError.rejected("invalid_request")
        }
        guard let raw = paranoid_core_command(state, request) else {
            throw CoreError.nativeFailure
        }
        defer { paranoid_core_free(raw) }
        let text = String(cString: raw)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.nativeFailure
        }
        if let error = object["error"] {
            guard let code = error as? String else { throw CoreError.nativeFailure }
            throw CoreError.rejected(code)
        }
        return CoreReply(text: text, state: JsonSpan.state(in: text), object: object)
    }
}
