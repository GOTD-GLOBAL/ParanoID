import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// What the call screen does after the call, and where the call is while
/// the screen is put away.
///
/// The model is the production `AppModel` over a real registered client with
/// one verified contact; the calls are handed to it as the controller would
/// publish them (`callChanged`, `callFinished`), so no media engine, no peer
/// and no server are needed, and the rules under test are the model's own:
/// the screen of an ended call closes itself after the outcome has had its
/// time, «Перезвонить» is offered exactly for a call this device placed that
/// did not go through, a call put away with «К переписке» stands on a line
/// over the screens, and a call the system's audio interruption ended is
/// named for it.
final class CallScreenLifeTests: XCTestCase {
    private final class MemorySink: SnapshotSink {
        func save(_ snapshot: String) throws {}
    }

    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    // MARK: - closing itself

    @MainActor
    func testTheScreenOfAnEndedCallClosesItselfAfterTwoSeconds() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.connected, peer, "c1", elapsed: 12_000))
        XCTAssertTrue(model.showsCall)

        model.callChanged(Self.call(.ended, peer, "c1", reason: .hangup))
        XCTAssertTrue(model.showsCall, "the outcome is shown first")
        try await Self.wait(seconds: 1) { !model.showsCall }
        XCTAssertTrue(model.showsCall, "not before two seconds")
        try await Self.wait(seconds: 3) { !model.showsCall }
        XCTAssertFalse(model.showsCall)
    }

    @MainActor
    func testAnOutcomeWithSomethingToDoStaysFiveSecondsAndOffersCallBack() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.outgoing, peer, "c2"))
        model.callFinished(Self.termination(peer, "c2", outgoing: true, reason: .timeout))
        model.callChanged(Self.call(.ended, peer, "c2", reason: .timeout))

        let offer = try XCTUnwrap(model.callBackOffer)
        XCTAssertEqual(offer.account, peer)
        XCTAssertFalse(offer.video)
        XCTAssertEqual(model.callLabel, Strings.Call.timeout)
        try await Self.wait(seconds: 3) { !model.showsCall }
        XCTAssertTrue(model.showsCall, "five seconds, not two")
        try await Self.wait(seconds: 4) { !model.showsCall }
        XCTAssertFalse(model.showsCall)
    }

    @MainActor
    func testCloseWorksAtOnceAndANewCallCancelsTheCountdown() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.ended, peer, "c3", reason: .cancel))
        model.endCall()
        XCTAssertFalse(model.showsCall, "«Закрыть» does not wait")

        // Only a call that was live raises the screen; an end alone never does.
        model.callChanged(Self.call(.ended, peer, "c4", reason: .hangup))
        XCTAssertFalse(model.showsCall)
        model.callChanged(Self.call(.connected, peer, "c4", elapsed: 1_000))
        model.callChanged(Self.call(.ended, peer, "c4", reason: .hangup))
        XCTAssertTrue(model.showsCall)
        model.callChanged(Self.call(.incoming, peer, "c5"))
        XCTAssertTrue(model.showsCall)
        try await Self.wait(seconds: 3) { !model.showsCall }
        XCTAssertTrue(model.showsCall, "the countdown of c4 must not close the screen on c5")
    }

    @MainActor
    func testARepublishedEndedViewStartsNoSecondCountdown() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.connected, peer, "c6", elapsed: 1_000))
        model.callChanged(Self.call(.ended, peer, "c6", reason: .hangup))
        XCTAssertTrue(model.showsCall)
        try await Self.wait(seconds: 1) { !model.showsCall }
        XCTAssertTrue(model.showsCall)
        // The same ended call again, as the controller republishes its view.
        model.callChanged(Self.call(.ended, peer, "c6", reason: .hangup))
        try await Self.wait(seconds: 1.5) { !model.showsCall }
        XCTAssertFalse(model.showsCall, "two seconds from the first publication, not the last")
    }

    // MARK: - «Перезвонить»

    @MainActor
    func testCallBackOpensTheConfirmationAndStopsTheCountdown() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.outgoing, peer, "c7"))
        model.callFinished(Self.termination(peer, "c7", outgoing: true, reason: .busy))
        model.callChanged(Self.call(.ended, peer, "c7", reason: .busy))

        model.callBack()
        XCTAssertEqual(model.callPrompt, model.callBackOffer)
        XCTAssertEqual(model.callPrompt?.title, Strings.Call.audioPrompt)
        try await Self.wait(seconds: 6) { !model.showsCall }
        XCTAssertTrue(model.showsCall, "a screen with the confirmation open stays")

        model.cancelCallPrompt()
        XCTAssertNil(model.callPrompt)
        model.endCall()
        XCTAssertFalse(model.showsCall)
    }

    @MainActor
    func testCallBackIsOfferedOnlyForAnOwnCallThatDidNotGoThrough() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        let offered: [(Bool, Bool, CallBody.EndReason, Bool)] = [
            // outgoing, connected, reason, offered
            (true, false, .timeout, true),
            (true, false, .busy, true),
            (true, false, .failed, true),
            (true, false, .unavailable, true),
            (true, false, .reject, false),
            (true, false, .cancel, false),
            (true, true, .hangup, false),
            (false, false, .timeout, false),
            (false, false, .busy, false),
            (false, true, .hangup, false),
        ]
        for (index, (outgoing, connected, reason, expected)) in offered.enumerated() {
            let id = "o\(index)"
            model.callFinished(Self.termination(peer, id, outgoing: outgoing, connected: connected,
                                                reason: reason))
            model.callChanged(Self.call(.ended, peer, id, reason: reason))
            XCTAssertEqual(model.callBackOffer != nil, expected,
                           "outgoing=\(outgoing) connected=\(connected) \(reason)")
            model.endCall()
        }
        // The offer belongs to the call on the screen, not to the last one
        // that ended.
        model.callFinished(Self.termination(peer, "x", outgoing: true, reason: .timeout))
        model.callChanged(Self.call(.ended, peer, "y", reason: .timeout))
        XCTAssertNil(model.callBackOffer)
    }

    @MainActor
    func testAVideoCallThatWasNeverAnsweredIsCalledBackAsVideo() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        // The controller opens no camera before media, so the termination of
        // an unanswered video call carries `video: false`; the offer keeps
        // the kind from the termination when it has it.
        model.callFinished(Self.termination(peer, "v1", outgoing: true, video: true, reason: .timeout))
        model.callChanged(Self.call(.ended, peer, "v1", reason: .timeout))
        XCTAssertEqual(model.callBackOffer?.video, true)
        XCTAssertEqual(model.callBackOffer?.title, Strings.Call.videoPrompt)
    }

    // MARK: - the line over the screens

    @MainActor
    func testACallPutAwayStandsOnALineOverTheScreensUntilItEnds() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.connected, peer, "b1", elapsed: 151_000))
        XCTAssertTrue(model.showsCall)
        XCTAssertNil(model.callReturnBar, "no line while the screen itself is up")

        model.closeCallScreen()
        XCTAssertFalse(model.showsCall)
        XCTAssertEqual(model.callReturnBar,
                       "Звонок · \(model.title(for: peer)) · 02:31 · Соединение установлено")

        model.callChanged(Self.call(.connected, peer, "b1", elapsed: 152_000))
        XCTAssertEqual(model.callReturnBar,
                       "Звонок · \(model.title(for: peer)) · 02:32 · Соединение установлено")

        model.returnToCall()
        XCTAssertTrue(model.showsCall)
        XCTAssertNil(model.callReturnBar)

        model.closeCallScreen()
        model.callChanged(Self.call(.ended, peer, "b1", reason: .hangup))
        XCTAssertNil(model.callReturnBar, "an ended call has no line")
        XCTAssertFalse(model.showsCall, "and «К переписке» is not undone by its end")
    }

    @MainActor
    func testARingingCallPutAwayIsOnTheLineToo() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.incoming, peer, "r1"))
        model.closeCallScreen()
        XCTAssertEqual(model.callReturnBar,
                       "Звонок · \(model.title(for: peer)) · Входящий звонок")
        model.returnToCall()
        XCTAssertTrue(model.showsCall)
    }

    // MARK: - the interruption

    @MainActor
    func testACallTheSystemInterruptedIsNamedForItAndNothingElseIs() async throws {
        let (model, peer) = try await Self.modelWithAContact()
        model.callChanged(Self.call(.connected, peer, "i1", elapsed: 5_000))
        model.callInterrupted("i1")
        model.callChanged(Self.call(.ended, peer, "i1", reason: .failed))
        XCTAssertEqual(model.callLabel, Strings.Call.interrupted)
        XCTAssertEqual(model.callLabel, "Звонок прерван другим вызовом или приложением")

        model.callChanged(Self.call(.ended, peer, "i2", reason: .failed))
        XCTAssertEqual(model.callLabel, Strings.Call.failed, "another call's failure keeps Android's words")
    }

    // MARK: - fixture

    /// A running model over a registered client with one verified contact,
    /// so that «Перезвонить» has a conversation it may open a call for.
    @MainActor
    private static func modelWithAContact() async throws -> (AppModel, String) {
        let peerClient = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
        try peerClient.createIdentity()
        try peerClient.registrationResult(status: try activeStatus(peerClient))
        let peerText = try XCTUnwrap(try peerClient.contactText())
        let peer = try XCTUnwrap(try peerClient.credential()["account"] as? String)

        let model = AppModel(openClient: {
            let client = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
            try client.createIdentity()
            try client.registrationResult(status: try activeStatus(client))
            try client.pair(peerText, verified: true)
            return client
        }, loadLocalMetadata: { (ContactNames(store: nil), CallLog(store: nil)) })
        model.start()
        XCTAssertEqual(model.stage, .running)
        model.refresh()
        try await wait(seconds: 20) { model.view.dialog(peer) != nil }
        return (model, peer)
    }

    private static func call(_ state: CallController.State, _ account: String, _ id: String,
                             reason: CallBody.EndReason? = nil,
                             elapsed: Int64 = 0) -> CallPresentation {
        CallPresentation(state: state, account: account, callId: id,
                         generation: CallGeneration(number: 1), reason: reason,
                         mediaActive: state == .connected, elapsedMillis: elapsed)
    }

    private static func termination(_ account: String, _ id: String, outgoing: Bool,
                                    connected: Bool = false, video: Bool = false,
                                    reason: CallBody.EndReason) -> CallTermination {
        CallTermination(callId: id, account: account, outgoing: outgoing, connected: connected,
                        video: video, durationSeconds: connected ? 1 : 0, reason: reason)
    }

    private static func activeStatus(_ client: SelfServiceClient) throws -> [String: Any] {
        let credential = try client.credential()
        let request: [String: Any] = [
            "op": "validate_request",
            "descriptor": ["type": "paranoid-request-v1", "credential": credential],
        ]
        let validated = try CoreBridge.command(
            state: "",
            request: String(decoding: try JSONSerialization.data(withJSONObject: request),
                            as: UTF8.self))
        return ["mode": "active",
                "account": try XCTUnwrap(credential["account"] as? String),
                "device": try XCTUnwrap(credential["device"] as? String),
                "credential": try XCTUnwrap(validated.object["fingerprint"] as? String)]
    }

    /// Waits up to `seconds` for `condition`, and returns either way: the
    /// caller asserts what it expects, because "still true after a second"
    /// is as much a result here as "false by then".
    @MainActor
    private static func wait(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
