import Foundation

/// One message of one conversation, as the core publishes it in
/// `view.dialogs[].messages[]` (`Entry` in `clients/core/src/lib.rs`).
///
/// It is the decoded form of the members Android reads off the same
/// `JSONObject` (`MainActivity.java:585-592`): who wrote it, what it says and
/// the two acceptance flags behind the marks, and the instant this phone saw
/// it. That instant is this device's own clock, stored by the core verbatim and
/// never transmitted; an entry written before this build has none, and no
/// screen invents one for it.
public struct Message: Identifiable, Equatable, Sendable {
    /// The envelope identifier the core minted for this message.
    public let id: String
    /// The account that wrote it; compared against the dialog's `own`.
    public let author: String
    /// The plaintext, exactly as the core holds it.
    public let text: String
    /// The server stored the envelope (`✓`).
    public let isAccepted: Bool
    /// The peer acknowledged it (two marks).
    public let isDelivered: Bool
    /// When the phone that wrote or received this message saw it, in
    /// milliseconds since the epoch, or `0` for an entry written by a build
    /// that kept no time. Nothing invents one for those (REQ-CLIENT-004).
    public let localMilliseconds: UInt64

    public init(id: String, author: String, text: String, isAccepted: Bool,
                isDelivered: Bool, localMilliseconds: UInt64 = 0) {
        self.id = id
        self.author = author
        self.text = text
        self.isAccepted = isAccepted
        self.isDelivered = isDelivered
        self.localMilliseconds = localMilliseconds
    }

    /// Reads one history entry; `nil` when it is not one.
    public static func decode(_ raw: [String: Any]) -> Message? {
        guard let id = raw["id"] as? String,
              let author = raw["author"] as? String,
              let text = raw["text"] as? String
        else { return nil }
        return Message(id: id,
                       author: author,
                       text: text,
                       isAccepted: raw["accepted"] as? Bool ?? false,
                       isDelivered: raw["delivered"] as? Bool ?? false,
                       localMilliseconds: (raw["local_ms"] as? NSNumber)?.uint64Value ?? 0)
    }
}

/// One conversation, as the core publishes it in `view.dialogs[]`
/// (`clients/core/src/clean_service.rs:315-320`).
///
/// The trust value is kept as the string the core wrote, because that string
/// is the whole product rule: `out_of_band_verified` is the only value that
/// means a fingerprint was compared somewhere else
/// (`docs/protocol/first-contact-v1.md:90-91`), and every other value —
/// today only `network_unverified` — is "not verified". Comparing the text
/// rather than mapping it to a Boolean is what keeps a future third value from
/// silently becoming "verified" here.
public struct Dialog: Identifiable, Equatable, Sendable {
    /// The value of `trust` that means the fingerprint was compared out of
    /// band (`Trust::OutOfBandVerified`, serialized snake_case).
    public static let verifiedTrust = "out_of_band_verified"

    public var id: String { account }
    /// The peer's account.
    public let account: String
    /// This device's own account, so that an author can be told apart.
    public let own: String
    /// The `trust` member, verbatim.
    public let trust: String
    /// Whether this contact is blocked (`block_contact_v2`).
    public let isBlocked: Bool
    /// The history, oldest first.
    public let messages: [Message]

    public init(account: String, own: String, trust: String, isBlocked: Bool, messages: [Message]) {
        self.account = account
        self.own = own
        self.trust = trust
        self.isBlocked = isBlocked
        self.messages = messages
    }

    /// Whether the fingerprint was compared out of band.
    public var isVerified: Bool { trust == Self.verifiedTrust }

    /// The last message, or `nil` for a conversation with no history.
    public var last: Message? { messages.last }

    /// Whether `message` was written on this device.
    public func isOwn(_ message: Message) -> Bool { message.author == own }

    /// Reads one dialog; `nil` when the value is not one.
    public static func decode(_ raw: [String: Any]) -> Dialog? {
        guard let account = raw["account"] as? String, !account.isEmpty else { return nil }
        let messages = (raw["messages"] as? [[String: Any]] ?? []).compactMap(Message.decode)
        return Dialog(account: account,
                      own: raw["own"] as? String ?? "",
                      trust: raw["trust"] as? String ?? "",
                      isBlocked: raw["blocked"] as? Bool ?? false,
                      messages: messages)
    }
}

/// Everything a screen may see, in one `Sendable` value.
///
/// `SelfServiceClient.publicView()` answers an `org.json`-shaped dictionary
/// (`SelfServiceClient.java:155-168`), which is neither `Sendable` nor
/// something a SwiftUI view should dig through. This is that answer decoded on
/// the state owner, so what crosses to the main actor is a value: no core
/// reply, no state text, no private key.
///
/// `contact` is the one member that is **not** taken from the dictionary. It
/// is `SelfServiceClient.contactText()` — the `contact` member sliced out of
/// the core's reply byte for byte — because that string is what the QR carries
/// and what the peer's core verifies; re-serializing the decoded object would
/// be a different string with the same meaning, and only one of the two is the
/// one that was signed.
public struct ClientView: Equatable, Sendable {
    /// An identity exists on this device (`view.request != null`).
    public let hasIdentity: Bool
    /// The enrollment is active: this device is registered and may talk.
    public let isActive: Bool
    /// There is a state file behind this view.
    public let isConfigured: Bool
    /// This device's account, empty before `create_identity`.
    public let account: String
    /// The contact fingerprint, empty before registration.
    public let fingerprint: String
    /// The contact text, verbatim; `nil` before `prepare_contact_v2`.
    public let contact: String?
    /// How many incoming events the core refused.
    public let rejectedCount: Int64
    /// The conversations, in the order the core published them.
    public let dialogs: [Dialog]

    public init(hasIdentity: Bool = false,
                isActive: Bool = false,
                isConfigured: Bool = false,
                account: String = "",
                fingerprint: String = "",
                contact: String? = nil,
                rejectedCount: Int64 = 0,
                dialogs: [Dialog] = []) {
        self.hasIdentity = hasIdentity
        self.isActive = isActive
        self.isConfigured = isConfigured
        self.account = account
        self.fingerprint = fingerprint
        self.contact = contact
        self.rejectedCount = rejectedCount
        self.dialogs = dialogs
    }

    /// The dialog of `account`, or `nil` when there is none — Android's
    /// `selectedDialog()` (`MainActivity.java:336-340`).
    public func dialog(_ account: String) -> Dialog? {
        dialogs.first { $0.account == account }
    }

    /// Decodes one `publicView()` answer.
    public static func decode(_ raw: [String: Any], contact: String? = nil) -> ClientView {
        ClientView(hasIdentity: raw["identity"] as? Bool ?? false,
                   isActive: raw["active"] as? Bool ?? false,
                   isConfigured: raw["configured"] as? Bool ?? false,
                   account: raw["account"] as? String ?? "",
                   fingerprint: raw["contact_fingerprint"] as? String ?? "",
                   contact: contact,
                   rejectedCount: (raw["rejected_count"] as? NSNumber)?.int64Value ?? 0,
                   dialogs: (raw["dialogs"] as? [[String: Any]] ?? []).compactMap(Dialog.decode))
    }

    /// Reads the whole view off the client, on the state owner.
    ///
    /// Both calls happen inside one `StateOwner.perform`, so the dialogs and
    /// the contact text describe the same committed state.
    ///
    /// - Throws: `SelfServiceError`, `CoreError`.
    public static func read(_ client: SelfServiceClient) throws -> ClientView {
        decode(try client.publicView(), contact: try client.contactText())
    }
}

/// Product state shown by the native UI; trust never gates incoming replies.
///
/// It is `clients/android/src/org/paranoid/text/DialogPolicy.java` with the
/// same two rules and the same two strings. The first rule is a label, not a
/// gate: an unverified contact is shown as unverified and is answered all the
/// same, because refusing to reply to an unverified peer would be a second,
/// silent trust model on top of the one the protocol describes
/// (`docs/protocol/first-contact-v1.md:90-91`).
public enum DialogPolicy {
    /// `DialogPolicy.java:10`.
    public static let verified = "Личность проверена"
    /// `DialogPolicy.java:10`, and the label a chat with no dialog shows.
    public static let unverified = "Личность не проверена"

    /// The trust line of a conversation (`DialogPolicy.java:8-11`).
    public static func trustLabel(_ dialog: Dialog?) -> String {
        dialog?.isVerified == true ? verified : unverified
    }

    /// Whether the composer may send into `dialog` right now
    /// (`DialogPolicy.java:12-14`).
    ///
    /// Five conditions, all of them necessary: there is a dialog with an
    /// account, this device is registered, the local state is not frozen, no
    /// send of this user's is already in flight — the double-tap guard — and
    /// the contact is not blocked.
    public static func canReply(_ dialog: Dialog?,
                                active: Bool,
                                broken: Bool,
                                sending: Bool) -> Bool {
        guard let dialog, !dialog.account.isEmpty else { return false }
        return active && !broken && !sending && !dialog.isBlocked
    }
}
