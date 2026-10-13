import Foundation
import ParanoidCoreFFI

/// A successful reply of the unchanged Rust Devnet command.
/// Replies may contain words or entropy: never log or cache them.
/// Swift-managed copies cannot be guaranteed zeroized.
public struct DevnetReply {
    /// The whole UTF-8 reply, verbatim, copied before the native buffer is freed.
    public let text: String
    /// The decoded top-level JSON object; not a new signing/validation policy.
    public let object: [String: Any]
}

/// Stateless adapter over `paranoid_devnet_command` / `paranoid_devnet_free`.
/// RFC-0030 prerequisite only: no cryptography, network, persistence or owner policy.
/// Requests and replies may contain secrets; never log or cache them. Minimize
/// their lifetime: Swift-managed strings/JSON copies cannot be guaranteed zeroized.
public enum DevnetBridge {
    /// Passes one JSON request unchanged to Rust. Embedded NUL and requests over
    /// 16384 UTF-8 bytes are rejected before allocating the C-string argument.
    /// - Throws: `CoreError.rejected` with Rust's error string (or the local
    ///   `invalid_request` / `input_limit` guard), or `CoreError.nativeFailure`
    ///   for NULL, invalid UTF-8/JSON, a non-object reply or a non-string error.
    public static func command(request: String) throws -> DevnetReply {
        try command(request: request, call: paranoid_devnet_command, free: paranoid_devnet_free)
    }

    // Per-call fault-test seam. Neither closure escapes or changes global state.
    // `call` must return nil or an owned, readable NUL-terminated allocation;
    // `free` must release that same allocation exactly once. Production always
    // supplies the matching Devnet exports, never core_free or the system free.
    static func command(request: String,
                        call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?,
                        free: (UnsafeMutablePointer<CChar>) -> Void) throws -> DevnetReply {
        // Validate before Swift allocates the NUL-terminated native argument.
        guard !request.utf8.contains(0) else {
            throw CoreError.rejected("invalid_request")
        }
        guard request.utf8.count <= 16384 else {
            throw CoreError.rejected("input_limit")
        }
        guard let raw = request.withCString({ call($0) }) else {
            throw CoreError.nativeFailure
        }
        defer { free(raw) }
        guard let text = String(validatingCString: raw) else {
            throw CoreError.nativeFailure
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.nativeFailure
        }
        if let error = object["error"] {
            guard let code = error as? String else { throw CoreError.nativeFailure }
            throw CoreError.rejected(code)
        }
        return DevnetReply(text: text, object: object)
    }
}
