import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the snapshot codec, the Swift counterpart of
/// `StorageSmoke.java:9-18`: round trip, fresh nonce per seal, tampering,
/// a wrong key and an unknown version byte. Everything runs in memory — no
/// Keychain, no file, no network — and the checks the Java smoke has no room
/// for are added here: the explicit `[0x01][nonce][ciphertext‖tag]` layout
/// with `[0x01]` as associated data, the 29-byte floor and the 8 MiB ceiling.
///
/// The cross-implementation vector (a snapshot sealed by the Java codec and
/// opened here, and the reverse) arrives with `JavaCodecVector`; this file
/// pins the format on its own by decrypting the codec's output with plain
/// CryptoKit and by feeding the codec a box CryptoKit assembled.
final class SnapshotCodecTests: XCTestCase {
    /// The plaintext of `StorageSmoke.java:10`, Cyrillic and an emoji.
    private static let text = "[TEST ONLY] секрет и сообщение 🎈"
    /// The version byte, which is also the associated data of every box.
    private static let associatedData = Data([SnapshotCodec.version])

    private func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func rejection(_ body: @autoclosure () throws -> Any,
                           file: StaticString = #filePath, line: UInt = #line) -> SnapshotCodecError? {
        var caught: SnapshotCodecError?
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            caught = error as? SnapshotCodecError
            XCTAssertNotNil(caught, "expected SnapshotCodecError, got \(error)", file: file, line: line)
        }
        return caught
    }

    // MARK: round trip and nonce freshness (StorageSmoke.java:11-13)

    func testRoundTripKeepsUtf8ExactlyIncludingTheEmoji() throws {
        let key = newKey()
        for value in [Self.text, "", "a", "{\"version\":3,\"s\":\"\\\"\\\\\"}", "строка\nи ещё 🎈🇷🇺\u{0}хвост"] {
            let sealed = try SnapshotCodec.seal(key: key, value: value)
            let opened = try SnapshotCodec.open(key: key, value: sealed)
            XCTAssertEqual(opened, value)
            XCTAssertEqual(Array(opened.utf8), Array(value.utf8), "byte-exact round trip")
            XCTAssertEqual(sealed.count, SnapshotCodec.minimumSnapshotBytes + value.utf8.count)
        }
    }

    func testTwoSealsOfTheSameTextDifferAndBothOpen() throws {
        let key = newKey()
        let first = try SnapshotCodec.seal(key: key, value: Self.text)
        let second = try SnapshotCodec.seal(key: key, value: Self.text)
        XCTAssertNotEqual(first, second, "nonce reused")
        // Only the nonce and the box differ; the version byte and the length
        // are the same.
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.first, SnapshotCodec.version)
        XCTAssertEqual(second.first, SnapshotCodec.version)
        XCTAssertNotEqual(first[1..<SnapshotCodec.headerBytes], second[1..<SnapshotCodec.headerBytes])
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: first), Self.text)
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: second), Self.text)
    }

    func testOpenAcceptsASliceThatDoesNotStartAtZero() throws {
        let key = newKey()
        let sealed = try SnapshotCodec.seal(key: key, value: Self.text)
        let slice = (Data([0xFF]) + sealed).dropFirst()
        XCTAssertEqual(slice.startIndex, 1, "the slice must keep a non-zero start index")
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: slice), Self.text)
    }

    // MARK: tampering, wrong key, unknown version (StorageSmoke.java:14-18)

    func testTamperingWithAnyPartOfTheSnapshotIsRejected() throws {
        let key = newKey()
        let sealed = try SnapshotCodec.seal(key: key, value: Self.text)
        // The tag (the last byte, as in `StorageSmoke.java:14`), the nonce and
        // the ciphertext are all covered by the same authentication.
        for position in [sealed.count - 1, 1, SnapshotCodec.headerBytes] {
            var tampered = sealed
            tampered[position] ^= 1
            XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: tampered)),
                           .authenticationFailure, "byte \(position) accepted")
        }
        // Truncating the tag by one byte shortens the snapshot but keeps it
        // above the floor: the box no longer authenticates.
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: sealed.dropLast())),
                       .authenticationFailure)
    }

    func testWrongKeyIsRejected() throws {
        let sealed = try SnapshotCodec.seal(key: newKey(), value: Self.text)
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: newKey(), value: sealed)),
                       .authenticationFailure)
        // A 128-bit key is a wrong key too, not a different format.
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: SymmetricKey(size: .bits128), value: sealed)),
                       .authenticationFailure)
    }

    func testUnknownVersionByteIsRejectedBeforeAnyCrypto() throws {
        let key = newKey()
        let sealed = try SnapshotCodec.seal(key: key, value: Self.text)
        for version in [UInt8(0), 2, 0xFF] {
            var tampered = sealed
            tampered[0] = version
            XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: tampered)),
                           .invalidSnapshot, "version \(version) accepted")
        }
    }

    // MARK: length bounds

    func testSnapshotsShorterThanTwentyNineBytesAreRejected() throws {
        let key = newKey()
        let sealed = try SnapshotCodec.seal(key: key, value: "")
        XCTAssertEqual(SnapshotCodec.minimumSnapshotBytes, 29)
        XCTAssertEqual(sealed.count, 29, "an empty plaintext is exactly the floor")
        for length in 0..<SnapshotCodec.minimumSnapshotBytes {
            XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: sealed.prefix(length))),
                           .invalidSnapshot, "length \(length) accepted")
        }
        // 29 bytes of the right shape but the wrong content reach the cipher.
        var junk = Data(repeating: 0, count: SnapshotCodec.minimumSnapshotBytes)
        junk[0] = SnapshotCodec.version
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: junk)), .authenticationFailure)
    }

    func testEightMebibytesSealsAndOneByteMoreIsRejected() throws {
        let key = newKey()
        XCTAssertEqual(SnapshotCodec.maximumPlaintextBytes, 8 * 1024 * 1024)
        XCTAssertEqual(SnapshotCodec.maximumSnapshotBytes, 8 * 1024 * 1024 + 29)

        let atLimit = String(repeating: "a", count: SnapshotCodec.maximumPlaintextBytes)
        let sealed = try SnapshotCodec.seal(key: key, value: atLimit)
        XCTAssertEqual(sealed.count, SnapshotCodec.maximumSnapshotBytes)
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: sealed), atLimit)

        let overLimit = atLimit + "a"
        XCTAssertEqual(rejection(try SnapshotCodec.seal(key: key, value: overLimit)), .snapshotLimit)

        // The limit counts UTF-8 bytes, not characters: 2 097 152 balloons are
        // exactly 8 MiB and one more balloon is four bytes too many.
        let balloons = String(repeating: "🎈", count: SnapshotCodec.maximumPlaintextBytes / 4)
        XCTAssertEqual(balloons.utf8.count, SnapshotCodec.maximumPlaintextBytes)
        XCTAssertEqual(try SnapshotCodec.seal(key: key, value: balloons).count,
                       SnapshotCodec.maximumSnapshotBytes)
        XCTAssertEqual(rejection(try SnapshotCodec.seal(key: key, value: balloons + "🎈")), .snapshotLimit)

        // `open` mirrors the ceiling: 8 MiB + 30 bytes is not a snapshot.
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: sealed + Data([0]))),
                       .invalidSnapshot)
    }

    // MARK: explicit layout — [0x01][12 nonce][ciphertext‖16 tag], AAD [0x01]

    func testSealedLayoutDecryptsWithPlainCryptoKitAndTheVersionByteAsAssociatedData() throws {
        let key = newKey()
        let plaintext = Data(Self.text.utf8)
        let sealed = try SnapshotCodec.seal(key: key, value: Self.text)

        XCTAssertEqual(SnapshotCodec.headerBytes, 13)
        XCTAssertEqual(SnapshotCodec.tagBytes, 16)
        XCTAssertEqual(sealed.count, 1 + 12 + plaintext.count + 16)
        XCTAssertEqual(sealed[0], 0x01)

        let nonce = sealed[1..<13]
        let tag = sealed.suffix(16)
        let ciphertext = sealed[13..<(sealed.count - 16)]
        XCTAssertEqual(nonce.count, 12)
        XCTAssertEqual(ciphertext.count, plaintext.count, "GCM is a stream cipher: no padding")
        XCTAssertNotEqual(Data(ciphertext), plaintext)

        // Decrypt the parsed pieces without going through the codec.
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: ciphertext,
                                        tag: tag)
        XCTAssertEqual(try AES.GCM.open(box, using: key, authenticating: Self.associatedData), plaintext)
        // The associated data is exactly `[0x01]`: nothing else authenticates.
        XCTAssertThrowsError(try AES.GCM.open(box, using: key, authenticating: Data()))
        XCTAssertThrowsError(try AES.GCM.open(box, using: key, authenticating: Data([0x02])))
        XCTAssertThrowsError(try AES.GCM.open(box, using: key, authenticating: Data([0x01, 0x01])))
        XCTAssertThrowsError(try AES.GCM.open(box, using: key))
    }

    func testOpenAcceptsASnapshotAssembledByPlainCryptoKitInThatLayout() throws {
        let key = newKey()
        let plaintext = Data(Self.text.utf8)
        let nonce = try AES.GCM.Nonce(data: Data((0..<12).map { UInt8($0) }))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Self.associatedData)

        var snapshot = Data([0x01])
        snapshot.append(contentsOf: nonce)
        snapshot.append(box.ciphertext)
        snapshot.append(box.tag)
        XCTAssertEqual(snapshot.count, 29 + plaintext.count)
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: snapshot), Self.text)

        // The same box sealed under different associated data is not a
        // snapshot this codec opens, which is what makes the version byte a
        // real part of the format rather than a decoration.
        let foreign = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data([0x02]))
        var mismatched = Data([0x01])
        mismatched.append(contentsOf: nonce)
        mismatched.append(foreign.ciphertext)
        mismatched.append(foreign.tag)
        XCTAssertEqual(rejection(try SnapshotCodec.open(key: key, value: mismatched)),
                       .authenticationFailure)
    }
}
