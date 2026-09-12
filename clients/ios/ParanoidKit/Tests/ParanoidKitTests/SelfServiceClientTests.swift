import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the self-service adapter: the version-4 wrapper, the
/// rules a retained snapshot is opened under, and the one ordering the whole
/// client exists to guarantee — a candidate is durable before it is adopted,
/// announced or dialled about.
///
/// Everything runs against the real core (the macOS slice of
/// `ParanoidCore.xcframework`) over `FakeFileSystem`, the in-memory tree of
/// `SnapshotStoreTests`: no real file, no Keychain, no server, and no account
/// on any server. The two synthetic devices register against a synthetic
/// `server_status_v2`, whose credential digest is computed here exactly as
/// `clients/android/test_voice_v8_compatibility.py:75-79` computes it, so the
/// core accepts it without anything being asked of a real server.
final class SelfServiceClientTests: XCTestCase {
    /// The local stand of a simulator run: an origin and a pin that are not
    /// the hosted alpha's. Nothing in these tests may reach the hosted server.
    private static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))
    /// A second stand, for the trust-disagreement checks.
    private static let otherStand = try! ServiceTrust(realm: "https://127.0.0.3:38443",
                                                     pin: String(repeating: "cd", count: 32))

    private func selfServiceError<Result>(_ body: @autoclosure () throws -> Result,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) -> SelfServiceError? {
        var caught: SelfServiceError?
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            caught = error as? SelfServiceError
            XCTAssertNotNil(caught, "expected SelfServiceError, got \(error)", file: file, line: line)
        }
        return caught
    }

    // MARK: - create -> upgrade -> register -> contact

    func testCreateIdentityUpgradesRegistersAndPreparesAContact() throws {
        let device = try Device(name: "own", trust: Self.stand)

        try device.client.createIdentity()

        // `create_identity` and `upgrade_v2` are two candidates and two
        // commits, both durable before anything is told to a server.
        XCTAssertEqual(device.commits, 2)
        XCTAssertTrue(try device.client.hasIdentity())
        XCTAssertFalse(try device.client.registered())
        XCTAssertNil(try device.client.contactText())

        let credential = try device.client.credential()
        try device.client.registrationResult(status: Self.activeStatus(for: credential))

        XCTAssertEqual(device.commits, 4)
        XCTAssertTrue(try device.client.registered())
        let contact = try XCTUnwrap(try device.client.contactText())
        XCTAssertTrue(contact.hasPrefix("{"), "the contact is the verbatim object of the reply")
        XCTAssertTrue(contact.contains(#""type":"paranoid-contact-v2""#))

        let view = try device.client.publicView()
        XCTAssertEqual(view["configured"] as? Bool, true)
        XCTAssertEqual(view["identity"] as? Bool, true)
        XCTAssertEqual(view["active"] as? Bool, true)
        XCTAssertEqual(view["account"] as? String, credential["account"] as? String)
        XCTAssertNotNil(view["contact"] as? [String: Any])
        XCTAssertEqual((view["contact_fingerprint"] as? String)?.count, 64)
        // A screen never sees the snapshot itself.
        XCTAssertNil(view["state"])
    }

    func testTheStoredWrapperIsTheVersionFourFormatWithTheStateVerbatim() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()

        let stored = try XCTUnwrap(try device.stored())
        let snapshot = try Snapshot.open(stored)

        XCTAssertEqual(Snapshot.version, 4)
        XCTAssertEqual(snapshot.trust, Self.stand)
        XCTAssertEqual(snapshot.token, "")
        XCTAssertEqual(snapshot.stateVersion, 3)
        XCTAssertTrue(stored.hasPrefix(#"{"version":4,"realm":"https://127.0.0.2:38443","tls_pin":"#))
        // Re-writing what was read gives the same bytes: the state is inlined,
        // never re-encoded.
        XCTAssertEqual(snapshot.text, stored)
        XCTAssertEqual(JsonSpan.value(of: "state", in: stored), snapshot.state)
    }

    func testASecondCreateIdentityChangesNothingAndCommitsNothing() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let committed = device.commits
        let stored = try XCTUnwrap(try device.stored())

        try device.client.createIdentity()

        // The core produced the same state text, so there was no candidate to
        // write (`SelfServiceClient.java:75`).
        XCTAssertEqual(device.commits, committed)
        XCTAssertEqual(try device.stored(), stored)
    }

    // MARK: - persist before adopt, persist before dial

    func testAFailedCommitFreezesTheClientAndNothingIsDialled() throws {
        let device = try Device(name: "own", trust: Self.stand)
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: ENOSPC)
        }
        let transport = RecordingTransport()

        XCTAssertEqual(selfServiceError(try device.client.createIdentity()), .commitFailed)

        XCTAssertTrue(device.client.isBroken)
        XCTAssertFalse(device.store.snapshotExists(), "an identity that was not stored does not exist")
        // The gate: a lane asks the state owner where the server is, is
        // refused, and therefore dials nothing at all.
        XCTAssertEqual(selfServiceError(try device.client.updateTrust()), .frozen)
        transport.dial(device.client, "/v2/registration/challenge")
        transport.dial(device.client, "/v2/messages")
        XCTAssertTrue(transport.calls.isEmpty, "a frozen client must not let anything reach the network")
        // And every other door is shut too.
        XCTAssertEqual(selfServiceError(try device.client.createIdentity()), .frozen)
        XCTAssertEqual(selfServiceError(try device.client.publicView()), .frozen)
        XCTAssertEqual(selfServiceError(try device.client.registered()), .frozen)
        XCTAssertEqual(selfServiceError(try device.client.pending()), .frozen)
        XCTAssertEqual(selfServiceError(try device.client.credential()), .frozen)
    }

    func testAHealthyClientHandsALaneTheSavedTrustAndNothingElse() throws {
        let device = try Device(name: "own", trust: Self.stand)
        let transport = RecordingTransport()

        transport.dial(device.client, "/health")

        XCTAssertEqual(transport.calls, ["https://127.0.0.2:38443/health"])
        XCTAssertEqual(try device.client.updateTrust(), Self.stand)
    }

    func testACrashBetweenTheTwoCommitsLeavesASchemaZeroStateTheDryRunAccepts() throws {
        let device = try Device(name: "own", trust: Self.stand)
        var writes = 0
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            writes += 1
            guard writes == 2 else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: EIO)
        }

        // The identity is stored, the schema upgrade is not.
        XCTAssertEqual(selfServiceError(try device.client.createIdentity()), .commitFailed)
        XCTAssertTrue(device.client.isBroken)
        let stored = try XCTUnwrap(try device.stored())
        XCTAssertEqual(try Snapshot.open(stored).stateVersion, 0)

        // The next launch opens that state. `upgrade_v2` runs as a dry run:
        // the candidate is inspected and dropped, so opening commits nothing.
        device.fileSystem.failure = nil
        let sink = device.reopenStore()
        let before = device.commits
        let reopened = try SelfServiceClient(saved: stored, sink: sink, fixture: Self.stand, compiled: nil)
        XCTAssertEqual(device.commits, before, "opening a snapshot must not write")
        XCTAssertEqual(try device.stored(), stored)
        XCTAssertTrue(try reopened.hasIdentity())
        XCTAssertFalse(try reopened.registered())

        // And the upgrade completes for real on the next `createIdentity`.
        try reopened.createIdentity()
        XCTAssertEqual(device.commits, before + 1)
        XCTAssertEqual(try Snapshot.open(try XCTUnwrap(try device.stored())).stateVersion, 3)
    }

    // MARK: - receive and acceptance

    func testAReceivedMessageIsOnTheDeviceBeforeItIsAdopted() throws {
        let (sender, receiver) = try Self.pairedDevices()
        let recipient = try XCTUnwrap(receiver.client.credential()["account"] as? String)
        try sender.client.send(account: recipient, text: "[TEST ONLY] привет 🎈")
        let envelope = try XCTUnwrap(try sender.client.pending().first)
        let committed = receiver.commits

        try receiver.client.received(message: Self.message(envelope,
                                                           from: try sender.account(),
                                                           sequence: 1))

        XCTAssertEqual(receiver.commits, committed + 1)
        XCTAssertEqual(try receiver.client.receiveCursor(), 1)
        // The receipt the core queued inside the same candidate is queued on
        // the device, not only in memory: a second client over the stored
        // bytes sees it.
        let stored = try XCTUnwrap(try receiver.stored())
        let reopened = try SelfServiceClient(saved: stored, sink: receiver.reopenStore(),
                                             fixture: Self.stand, compiled: nil)
        XCTAssertEqual(try reopened.receiveCursor(), 1)
        XCTAssertEqual(try reopened.pending().count, 1, "the queued receipt is durable")
        let dialog = try XCTUnwrap((try reopened.publicView()["dialogs"] as? [[String: Any]])?.first)
        XCTAssertEqual((dialog["messages"] as? [[String: Any]])?.count, 1)
    }

    func testAFailedCommitDuringReceiveLeavesTheDeviceOnTheOlderState() throws {
        let (sender, receiver) = try Self.pairedDevices()
        let recipient = try XCTUnwrap(receiver.client.credential()["account"] as? String)
        try sender.client.send(account: recipient, text: "[TEST ONLY] сообщение")
        let envelope = try XCTUnwrap(try sender.client.pending().first)
        let stored = try XCTUnwrap(try receiver.stored())
        receiver.fileSystem.failure = { call in
            guard case .rename = call else { return nil }
            return FileSystemError(.rename, receiver.store.fileURL, errno: EIO)
        }

        XCTAssertEqual(selfServiceError(try receiver.client.received(
            message: Self.message(envelope, from: try sender.account(), sequence: 1))), .commitFailed)

        XCTAssertTrue(receiver.client.isBroken)
        receiver.fileSystem.failure = nil
        // Nothing of the decrypted message survived: neither the cursor, nor
        // the history, nor the receipt the core wanted to send back.
        XCTAssertEqual(try receiver.stored(), stored)
        let reopened = try SelfServiceClient(saved: try XCTUnwrap(try receiver.stored()),
                                             sink: receiver.reopenStore(),
                                             fixture: Self.stand, compiled: nil)
        XCTAssertEqual(try reopened.receiveCursor(), 0)
        XCTAssertTrue(try reopened.pending().isEmpty)
    }

    func testAnAcceptanceMustNameTheEnvelopeAndCarryASequence() throws {
        let (sender, receiver) = try Self.pairedDevices()
        let recipient = try XCTUnwrap(receiver.client.credential()["account"] as? String)
        try sender.client.send(account: recipient, text: "[TEST ONLY] текст")
        let envelope = try XCTUnwrap(try sender.client.pending().first)
        let identifier = try XCTUnwrap(envelope["id"] as? String)
        var accepted: [String] = []
        sender.client.acceptedListener = { accepted.append($0) }
        let committed = sender.commits

        XCTAssertEqual(selfServiceError(try sender.client.accepted(
            envelope: envelope, response: ["id": identifier, "sequence": 0])), .invalidAcceptance)
        XCTAssertEqual(selfServiceError(try sender.client.accepted(
            envelope: envelope, response: ["id": "00000000-0000-0000-0000-000000000000", "sequence": 4])),
                       .invalidAcceptance)
        XCTAssertEqual(selfServiceError(try sender.client.accepted(
            envelope: envelope, response: ["id": identifier])), .invalidAcceptance)

        XCTAssertEqual(sender.commits, committed, "a refused acceptance writes nothing")
        XCTAssertEqual(try sender.client.pending().count, 1)
        XCTAssertTrue(accepted.isEmpty)

        try sender.client.accepted(envelope: envelope, response: ["id": identifier, "sequence": 4])

        XCTAssertEqual(sender.commits, committed + 1)
        XCTAssertTrue(try sender.client.pending().isEmpty)
        // The listener hears about it only after the commit.
        XCTAssertEqual(accepted, [identifier])
    }

    // MARK: - opening a retained wrapper

    func testAWrapperOfAnotherVersionIsRefusedWithoutTouchingTheBytes() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let stored = try XCTUnwrap(try device.stored())
        let committed = device.commits

        for version in ["3", "5", "\"4\""] {
            let rewritten = stored.replacingOccurrences(of: #"{"version":4,"#,
                                                        with: #"{"version":\#(version),"#)
            XCTAssertEqual(selfServiceError(try SelfServiceClient(saved: rewritten,
                                                                  sink: device.reopenStore(),
                                                                  fixture: Self.stand, compiled: nil)),
                           .unsupportedSnapshot, "version \(version)")
        }
        XCTAssertEqual(selfServiceError(try Snapshot.open("{}")), .unsupportedSnapshot)
        XCTAssertEqual(selfServiceError(try Snapshot.open("not json")), .malformedSnapshot)

        XCTAssertEqual(device.commits, committed, "a refused snapshot is never rewritten")
        XCTAssertEqual(try device.stored(), stored)
    }

    func testAStateSchemaOtherThanZeroOrThreeIsRefused() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let snapshot = try Snapshot.open(try XCTUnwrap(try device.stored()))
        // The core serialises through `serde_json::Value`, so the members are
        // sorted and the schema number is the last one.
        XCTAssertTrue(snapshot.state.hasSuffix(#","version":3}"#))
        let rewritten = snapshot.state.dropLast(#","version":3}"#.count) + #","version":2}"#
        let wrapper = Snapshot(trust: snapshot.trust, token: "",
                               state: String(rewritten), stateVersion: 3).text

        XCTAssertEqual(selfServiceError(try Snapshot.open(wrapper)), .unsupportedSnapshot)
    }

    func testTheLegacyTokenIsEitherEmptyOrSixtyFourHexDigits() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let snapshot = try Snapshot.open(try XCTUnwrap(try device.stored()))
        let token = String(repeating: "9f", count: 32)

        let carried = Snapshot(trust: snapshot.trust, token: token,
                               state: snapshot.state, stateVersion: 3).text
        XCTAssertEqual(try Snapshot.open(carried).token, token)
        let client = try SelfServiceClient(saved: carried, sink: device.reopenStore(),
                                           fixture: Self.stand, compiled: nil)
        XCTAssertTrue(try client.hasIdentity())

        for bad in ["abc", String(repeating: "z", count: 64), String(repeating: "AB", count: 32)] {
            let broken = Snapshot(trust: snapshot.trust, token: bad,
                                  state: snapshot.state, stateVersion: 3).text
            XCTAssertEqual(selfServiceError(try Snapshot.open(broken)), .invalidLegacySnapshot, bad)
        }
    }

    func testASnapshotWhoseRealmIsNotTheCoresIsRefused() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let stored = try XCTUnwrap(try device.stored())
        let snapshot = try Snapshot.open(stored)
        let committed = device.commits

        // Everything else about the wrapper is valid; only the origin differs
        // from the one the identity was created for.
        let foreign = Snapshot(trust: Self.otherStand, token: "",
                               state: snapshot.state, stateVersion: 3).text
        XCTAssertEqual(selfServiceError(try SelfServiceClient(saved: foreign,
                                                              sink: device.reopenStore(),
                                                              fixture: nil, compiled: nil)),
                       .realmMismatch)

        XCTAssertEqual(device.commits, committed)
        XCTAssertEqual(try device.stored(), stored)
    }

    func testSavedTrustWinsOverAFixtureThatDisagreesWithIt() throws {
        let device = try Device(name: "own", trust: Self.stand)
        try device.register()
        let stored = try XCTUnwrap(try device.stored())

        XCTAssertEqual(selfServiceError(try SelfServiceClient(saved: stored,
                                                              sink: device.reopenStore(),
                                                              fixture: Self.otherStand, compiled: nil)),
                       .savedTrustWins)
        // The compiled default never overrides a saved pair either.
        let reopened = try SelfServiceClient(saved: stored, sink: device.reopenStore(),
                                             fixture: nil, compiled: Self.otherStand)
        XCTAssertEqual(try reopened.updateTrust(), Self.stand)
    }

    // MARK: - where the first realm comes from

    func testTheHostedDefaultIsNotSubstitutedInADebugBuild() throws {
        // The host test run and every simulator run are Debug builds; that is
        // what keeps them on the local stand.
        XCTAssertTrue(ServiceTrust.isDebugBuild)
        XCTAssertNil(ServiceTrust.hostedDefault(arguments: [], isDebugBuild: true))
        XCTAssertNil(ServiceTrust.hostedDefault(arguments: ["-paranoid-realm", "https://127.0.0.2:38443"],
                                                isDebugBuild: true))
        XCTAssertEqual(ServiceTrust.hostedDefault(arguments: [ServiceTrust.allowHostedArgument],
                                                  isDebugBuild: true)?.realm,
                       ServiceTrust.hostedRealm)
        // A Release build is the owner's phone build and starts where Android
        // starts (`KeyClient.java:9-10`).
        let release = try XCTUnwrap(ServiceTrust.hostedDefault(arguments: [], isDebugBuild: false))
        XCTAssertEqual(release.realm, "https://157.180.49.125:38443")
        XCTAssertEqual(release.pin,
                       "8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba")

        // So a Debug client with nothing saved and no stand has no trust at
        // all: it cannot create an identity and it cannot dial.
        let device = try Device(name: "own", trust: Self.stand)
        XCTAssertEqual(selfServiceError(try SelfServiceClient(saved: nil, sink: device.reopenStore())),
                       .trustUnavailable)
        XCTAssertEqual(selfServiceError(try SelfServiceClient(saved: nil, sink: device.reopenStore(),
                                                              fixture: nil, compiled: nil)),
                       .trustUnavailable)
    }

    func testAFixtureIsTheTrustOfAContainerWithNothingSaved() throws {
        let device = try Device(name: "own", trust: Self.stand)
        XCTAssertEqual(try device.client.updateTrust(), Self.stand)
        try device.client.createIdentity()
        XCTAssertEqual(try Snapshot.open(try XCTUnwrap(try device.stored())).trust, Self.stand)
    }

    // MARK: - the adapter never dials

    func testTheServiceAdapterContainsNoNetworkCodeAtAll() throws {
        let service = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ParanoidKit/Service", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: service.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("SelfServiceClient.swift"))
        XCTAssertTrue(names.contains("Snapshot.swift"))

        for name in names {
            let source = try String(contentsOf: service.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "NWConnection", "dataTask", "CFSocket"] {
                XCTAssertFalse(source.contains(forbidden),
                               "\(name) must not open a connection (\(forbidden))")
            }
        }
    }

    // MARK: - fixtures

    /// The `server_status_v2` a real server would answer with, computed the
    /// way the core computes the credential fingerprint it checks against
    /// (`key-protocol/src/lib.rs:56-71`,
    /// `clients/android/test_voice_v8_compatibility.py:75-79`).
    static func activeStatus(for credential: [String: Any]) throws -> [String: Any] {
        var transcript = Data()
        for name in ["", "root", "account", "device", "auth", "realm", "pin", "olm"] {
            let field = name.isEmpty ? "paranoid-credential-v1" : try string(credential, name)
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { transcript.append(contentsOf: $0) }
            transcript.append(bytes)
        }
        return ["mode": "active",
                "account": try string(credential, "account"),
                "device": try string(credential, "device"),
                "credential": SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()]
    }

    /// The four members of one delivered envelope (`lib.rs:115-120`): what the
    /// server hands back on `GET /v2/messages`, built here from the sender's
    /// own outbox entry.
    static func message(_ envelope: [String: Any], from sender: String, sequence: Int64) throws -> [String: Any] {
        ["id": try string(envelope, "id"),
         "ciphertext": try string(envelope, "ciphertext"),
         "sender": sender,
         "sequence": sequence]
    }

    /// Two registered devices on the same stand that have verified each other
    /// out of band, which is the only way a message can be sent at all.
    static func pairedDevices() throws -> (Device, Device) {
        let first = try Device(name: "first", trust: stand)
        let second = try Device(name: "second", trust: stand)
        try first.register()
        try second.register()
        guard let firstContact = try first.client.contactText(),
              let secondContact = try second.client.contactText()
        else { throw FixtureError.missing("contact") }
        try first.client.pair(secondContact, verified: true)
        try second.client.pair(firstContact, verified: true)
        return (first, second)
    }

    private static func string(_ object: [String: Any], _ name: String) throws -> String {
        guard let value = object[name] as? String else { throw FixtureError.missing(name) }
        return value
    }

    enum FixtureError: Error, Equatable {
        case missing(String)
    }
}

/// One synthetic device: an in-memory file system, its own wrapping key, the
/// store over them and the client over that.
final class Device {
    let fileSystem: FakeFileSystem
    let directory: URL
    let store: SnapshotStore
    let client: SelfServiceClient

    private let key: SymmetricKey

    init(name: String, trust: ServiceTrust) throws {
        fileSystem = FakeFileSystem()
        directory = URL(fileURLWithPath: "/fake/\(name)/Application Support/paranoid", isDirectory: true)
        key = SymmetricKey(size: .bits256)
        store = SnapshotStore(directory: directory, key: key, fileSystem: fileSystem)
        client = try SelfServiceClient(saved: nil, sink: store, fixture: trust, compiled: nil)
    }

    /// How many candidates reached the device: one `rename(2)` per commit.
    var commits: Int {
        fileSystem.log.filter { if case .rename = $0 { return true } else { return false } }.count
    }

    /// A second store over the same bytes and the same key. It is how these
    /// tests read what is on the device after the client's own store froze,
    /// and it is also what the next launch would do.
    func reopenStore() -> SnapshotStore {
        SnapshotStore(directory: directory, key: key, fileSystem: fileSystem)
    }

    func stored() throws -> String? {
        try reopenStore().load()
    }

    func account() throws -> String {
        guard let account = try client.credential()["account"] as? String else {
            throw SelfServiceClientTests.FixtureError.missing("account")
        }
        return account
    }

    /// `create_identity` -> `upgrade_v2` -> a synthetic active enrollment ->
    /// `prepare_contact_v2`, the whole of registration without a server.
    func register() throws {
        try client.createIdentity()
        try client.registrationResult(status: SelfServiceClientTests.activeStatus(for: try client.credential()))
    }
}

/// A stand-in for a realtime lane.
///
/// Nothing in `ParanoidKit` dials anything by itself: a lane must first ask the
/// state owner where the server is and which key to pin, and a frozen owner
/// refuses. Counting what this type recorded is therefore the outside view of
/// "no request is made about a candidate that is not on the device".
final class RecordingTransport {
    private(set) var calls: [String] = []

    func dial(_ client: SelfServiceClient, _ path: String) {
        guard let trust = try? client.updateTrust() else { return }
        calls.append(trust.realm + path)
    }
}
