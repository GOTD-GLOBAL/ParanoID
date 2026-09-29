import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// «Контакты» as the model hands it to the screen: by the names this phone
/// gave the contacts, the named first, and the blocked ones in their own
/// list — over a real registered client with three verified contacts, named
/// and blocked through the production model.
final class ContactsListTests: XCTestCase {
    private final class MemorySink: SnapshotSink {
        func save(_ snapshot: String) throws {}
    }

    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    @MainActor
    func testNamedContactsStandFirstInAlphabeticalOrderAndTheRestByAccount() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        let byAccount = peers.sorted()
        XCTAssertEqual(model.orderedContacts.map(\.account), byAccount, "no names: the core's order")

        model.rename(account: byAccount[2], to: "Аня")
        model.rename(account: byAccount[0], to: "Сергей")
        XCTAssertEqual(model.orderedContacts.map(\.account), [byAccount[2], byAccount[0], byAccount[1]])

        // An emptied name goes back among the unnamed.
        model.rename(account: byAccount[0], to: "")
        XCTAssertEqual(model.orderedContacts.map(\.account), [byAccount[2], byAccount[0], byAccount[1]])
        model.rename(account: byAccount[1], to: "борис")
        XCTAssertEqual(model.orderedContacts.map(\.account), [byAccount[2], byAccount[1], byAccount[0]])
    }

    @MainActor
    func testABlockedContactLeavesTheListForItsOwnSectionAndComesBack() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        let byAccount = peers.sorted()
        XCTAssertEqual(model.blockedContacts, [])

        model.block(account: byAccount[1], blocked: true)
        try await Self.wait { model.view.dialog(byAccount[1])?.isBlocked == true }
        XCTAssertEqual(model.orderedContacts.map(\.account), [byAccount[0], byAccount[2]])
        XCTAssertEqual(model.blockedContacts.map(\.account), [byAccount[1]])
        // «Чаты» keeps it, with its badge (`DialogsScreen.trailing`).
        XCTAssertTrue(model.orderedDialogs.map(\.account).contains(byAccount[1]))

        model.block(account: byAccount[1], blocked: false)
        try await Self.wait { model.view.dialog(byAccount[1])?.isBlocked == false }
        XCTAssertEqual(model.orderedContacts.map(\.account), byAccount)
        XCTAssertEqual(model.blockedContacts, [])
    }

    @MainActor
    func testEveryContactCarriesTheFingerprintTheCorePublished() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        for peer in peers {
            let fingerprint = try XCTUnwrap(model.view.dialog(peer)?.fingerprint)
            XCTAssertEqual(fingerprint.count, 64)
            XCTAssertNil(fingerprint.range(of: "[^0-9a-f]", options: .regularExpression))
            XCTAssertEqual(MessagePresentation.groupedFingerprint(fingerprint).count, 64 + 7)
        }
    }

    // MARK: - fixture

    @MainActor
    private static func modelWithThreeContacts() async throws -> (AppModel, [String]) {
        var texts: [String] = []
        var accounts: [String] = []
        for _ in 0..<3 {
            let peer = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
            try peer.createIdentity()
            try peer.registrationResult(status: try activeStatus(peer))
            texts.append(try XCTUnwrap(try peer.contactText()))
            accounts.append(try XCTUnwrap(try peer.credential()["account"] as? String))
        }
        let pairTexts = texts
        let model = AppModel(openClient: {
            let client = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
            try client.createIdentity()
            try client.registrationResult(status: try activeStatus(client))
            for text in pairTexts { try client.pair(text, verified: true) }
            return client
        }, loadLocalMetadata: { (ContactNames(store: nil), CallLog(store: nil)) })
        model.start()
        XCTAssertEqual(model.stage, .running)
        model.refresh()
        try await wait { model.view.dialogs.count == 3 }
        return (model, accounts)
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

    private struct TimedOut: Error {}

    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
