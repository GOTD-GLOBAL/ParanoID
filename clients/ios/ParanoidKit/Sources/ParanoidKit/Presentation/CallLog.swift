import Foundation

/// The calls this phone has had, and where they stand in a conversation.
///
/// It is the call-shaped sibling of ``ContactNames``: the application's own
/// defaults, keyed by account, never part of the sealed snapshot, never sent to
/// the peer or the server. The core is deliberately not involved — a call
/// creates no history entry and no receipt commitment there
/// (`docs/protocol/voice-v1.md:27-31`), and this does not change that. What it
/// records is what this device itself watched happen.
///
/// Two consequences follow from where it lives, and both are the same ones the
/// local contact names have: container deletion removes it (OS backup restore
/// can restore these non-excluded UserDefaults),
/// and it is this phone's account of the call, not a shared one. The peer keeps
/// its own, derived from its own side of the same controls, and the two can
/// legitimately differ — a caller that gave up before the ring was answered
/// wrote «Вызов отменён» while the callee wrote «Пропущенный звонок».
public struct CallLog: Equatable {
    /// The defaults key the whole log lives under, versioned so a later rule
    /// can be told apart from this one.
    public static let defaultsKey = "paranoid.call-log.v1"

    /// How many rows are kept per conversation. A phone that never stops
    /// calling would otherwise grow this file without end; the bound is on the
    /// local log alone and has nothing to do with the message history, which
    /// has no ceiling.
    public static let perAccountLimit = 500

    /// Match Android: nil input is unavailable history, an empty array is an
    /// observed empty chat. The non-UUID sentinel sorts at the end permanently;
    /// it never invents a message timestamp or a recovered ordering fact.
    public static func anchor(messages: [Message]?) -> String? {
        guard let messages else { return "unavailable" }
        return messages.last?.id
    }

    private var records: [String: [CallRecord]]
    private let defaults: UserDefaults?

    /// - Parameter defaults: the standard suite in the application; the tests
    ///   pass a scratch suite so that a run leaves nothing behind.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([String: [CallRecord]].self, from: data)
        else {
            records = [:]
            return
        }
        // Anything unreadable is dropped on the way in rather than shown: a log
        // is a convenience, and a corrupt one must never stop a chat opening.
        records = stored.filter { !$0.key.isEmpty }
    }

    /// This conversation's rows, oldest first.
    public func records(for account: String) -> [CallRecord] {
        records[account] ?? []
    }

    /// Records one finished call.
    ///
    /// It is keyed by the call identifier, so the same terminal transition
    /// arriving twice — a republished view, a screen that comes back — leaves
    /// one row and not two.
    @discardableResult
    public mutating func record(_ record: CallRecord) -> Bool {
        guard !record.account.isEmpty, !record.id.isEmpty else { return false }
        var rows = records[record.account] ?? []
        guard !rows.contains(where: { $0.id == record.id }) else { return false }
        rows.append(record)
        if rows.count > Self.perAccountLimit {
            rows.removeFirst(rows.count - Self.perAccountLimit)
        }
        records[record.account] = rows
        write()
        return true
    }

    /// Forgets one conversation's calls, for a contact that is being cleared
    /// from this phone.
    public mutating func forget(account: String) {
        guard records.removeValue(forKey: account) != nil else { return }
        write()
    }

    /// Two logs are the same when they hold the same rows; which suite they
    /// were read from is not part of that.
    public static func == (left: CallLog, right: CallLog) -> Bool {
        left.records == right.records
    }

    private func write() {
        guard let defaults else { return }
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// One line of a conversation: a message the core committed, or a call this
/// phone watched happen.
public enum ChatRow: Identifiable, Equatable, Sendable {
    case message(Message)
    case call(CallRecord)

    public var id: String {
        switch self {
        case .message(let message): return "m:" + message.id
        case .call(let record): return "c:" + record.id
        }
    }
}

extension ChatRow {
    /// The conversation as the chat draws it: the core's history in its own
    /// order, with each call standing after the message it followed.
    ///
    /// The core keeps no time for a message (`clients/core/src/lib.rs:70-78`),
    /// so a call cannot be sorted into the history by a clock without inventing
    /// one — which `REQ-CLIENT-004` forbids. Each row therefore carries the
    /// identifier of the last message that existed when the call ended, and it
    /// is drawn there. A call recorded before the conversation had any messages
    /// opens the chat; a call whose anchor is no longer in the history — a
    /// reinstall, a state this build cannot read — stands at the end rather
    /// than disappearing.
    public static func rows(messages: [Message], calls: [CallRecord]) -> [ChatRow] {
        guard !calls.isEmpty else { return messages.map(ChatRow.message) }
        var byAnchor: [String: [CallRecord]] = [:]
        var leading: [CallRecord] = []
        let known = Set(messages.map(\.id))
        var trailing: [CallRecord] = []
        for call in calls {
            guard let anchor = call.afterMessageId else {
                leading.append(call)
                continue
            }
            if known.contains(anchor) {
                byAnchor[anchor, default: []].append(call)
            } else {
                trailing.append(call)
            }
        }
        var rows = leading.map(ChatRow.call)
        for message in messages {
            rows.append(.message(message))
            for call in byAnchor[message.id] ?? [] { rows.append(.call(call)) }
        }
        rows.append(contentsOf: trailing.map(ChatRow.call))
        return rows
    }
}
