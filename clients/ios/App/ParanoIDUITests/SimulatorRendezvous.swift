import XCTest

/// The file rendezvous with the Python harness that drives a simulator run.
///
/// A simulator process writes to this Mac's file system directly —
/// `ParanoIDTests/SdpCompatibilityTests` already writes
/// `out/evidence/sdp-spike.json` that way — so the harness and the test meet
/// in one directory rather than guessing at each other's timing: the test
/// writes `req-<n>`, blocks, and the harness answers `ans-<n>`. That is what
/// makes every `xcrun simctl io … screenshot` a photograph of the screen the
/// assertion was just made about, what lets the test wait for a peer's own
/// core instead of for a wall clock, and — in `test_voice_sim.py`, where two
/// simulators run two processes of this bundle at once — what lets one side
/// wait for the other to arrive.
///
/// Nothing secret crosses it: a screenshot name, a public account, a public
/// contact and the synthetic texts of the run.
///
/// It is shared by `TextFlowUITests` and `VoiceCallUITests` rather than copied
/// into each: the two harnesses answer different verbs, but the protocol
/// between a test and its harness is one protocol.
struct Rendezvous {
    let directory: URL

    enum Problem: Error, CustomStringConvertible {
        case refused(String, String)
        case timedOut(String)

        var description: String {
            switch self {
            case .refused(let verb, let detail): return "the harness refused \(verb): \(detail)"
            case .timedOut(let verb): return "the harness never answered \(verb)"
            }
        }
    }

    /// One request and its answer. `argument` travels as base64, so a text
    /// with a space or a newline in it stays one line.
    @discardableResult
    func ask(_ verb: String, _ argument: String, timeout: TimeInterval) throws -> String {
        let name = String(format: "%04d", Counter.next())
        let line = verb + " " + Data(argument.utf8).base64EncodedString() + "\n"
        let request = directory.appendingPathComponent("req-" + name)
        let staging = directory.appendingPathComponent("req-" + name + ".tmp")
        try Data(line.utf8).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: request)

        let answer = directory.appendingPathComponent("ans-" + name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: answer),
               let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") {
                let reply = String(text.dropLast())
                if reply.hasPrefix("error ") {
                    throw Problem.refused(verb, String(reply.dropFirst("error ".count)))
                }
                return reply.hasPrefix("ok ") ? String(reply.dropFirst("ok ".count))
                    : (reply == "ok" ? "" : reply)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw Problem.timedOut(verb)
    }

    /// The request numbers of this process, in order.
    private enum Counter {
        nonisolated(unsafe) private static var value = 0
        private static let lock = NSLock()

        static func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

// MARK: - failure messages

/// What to say when an element that should be on the screen is not.
///
/// A UI failure with no context costs a whole run to reproduce, so every
/// assertion that waits carries this: the stage the application is on and the
/// text of an alert, if one is standing in the way.
enum Diagnosis {
    @MainActor
    static func of(_ app: XCUIApplication) -> String {
        var parts: [String] = []
        for stage in ["opening", "no-stand", "frozen", "welcome", "chat", "identity", "contacts",
                      "call"]
        where app.descendants(matching: .any)[stage].exists {
            parts.append(stage)
        }
        if app.alerts.firstMatch.exists {
            parts.append("alert «\(app.alerts.firstMatch.label)»")
        }
        if app.staticTexts["status-line"].exists {
            parts.append("status «\(app.staticTexts["status-line"].label)»")
        }
        if app.staticTexts["call-status"].exists {
            parts.append("call «\(app.staticTexts["call-status"].label)»")
        }
        // The bottom banner is where a refused intent says why it was refused
        // — no connection, no microphone, no camera — and it is gone three
        // seconds later, so a failure that waited must still name it.
        if app.staticTexts["notice"].exists {
            parts.append("notice «\(app.staticTexts["notice"].label)»")
        }
        let stage = parts.isEmpty ? "nothing recognisable on the screen" : parts.joined(separator: ", ")
        // The tree costs a whole run to reproduce otherwise, and a failure
        // here is always "the element is not where the test looked".
        return stage + "\n" + app.debugDescription
    }
}
