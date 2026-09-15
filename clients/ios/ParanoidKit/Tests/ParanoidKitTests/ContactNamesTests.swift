import Foundation
import ParanoidKit
import XCTest

/// The local display name of a contact (Android v22, `ContactNames.java`).
///
/// Two rules are the point of this file, and they are the two the owner asked
/// for: **an empty value restores the default label**, and **the name is only
/// local** — it lives in this installation's own defaults, it is invisible to
/// any other container, and it changes nothing the core published. The rest is
/// the normalizer, transcribed from
/// `clients/android/test/ContactNamesSmoke.java` so that the same text typed
/// on either phone is kept the same way.
final class ContactNamesTests: XCTestCase {
    /// A 64-character account, as the core publishes one.
    private let account = String(repeating: "0123456789abcdef", count: 4)
    /// What every screen shows for that account with no local name.
    private var defaultTitle: String { MessagePresentation.title(account) }

    /// The container these cases write names into. One fixed name for every
    /// case and every run, emptied around each of them: a removed domain still
    /// leaves its file behind in the host's preferences, so a name minted per
    /// case left one more of them there on every execution. `defaults` has no
    /// value until `setUpWithError` gives it one, because the standard suite
    /// is not a safe stand-in for a scratch one even as an unread placeholder.
    private let suite = "global.paranoid.messenger.tests.names"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suite)
    }

    // MARK: - the empty value restores the default

    func testAnEmptyNameRestoresTheDefaultTitle() {
        var names = ContactNames(defaults: defaults)
        XCTAssertEqual(names.name(for: account), "")
        XCTAssertEqual(names.title(for: account), defaultTitle)

        XCTAssertEqual(names.rename("Серёга", for: account), "Серёга")
        XCTAssertEqual(names.name(for: account), "Серёга")
        XCTAssertEqual(names.title(for: account), "Серёга")

        // «Оставьте пустым, чтобы вернуть имя по умолчанию.»
        XCTAssertEqual(names.rename("", for: account), "")
        XCTAssertEqual(names.name(for: account), "")
        XCTAssertEqual(names.title(for: account), defaultTitle)
        // And nothing is left behind for the next launch to read.
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey))
        XCTAssertEqual(ContactNames(defaults: defaults).title(for: account), defaultTitle)
    }

    func testABlankOrUnprintableNameClearsItJustAsAnEmptyOneDoes() {
        var names = ContactNames(defaults: defaults)
        for blank in ["   ", "\n\t", "\u{00A0}", "\u{200E}\u{202E}", "\u{0000}"] {
            names.rename("Мама", for: account)
            XCTAssertEqual(names.title(for: account), "Мама")
            XCTAssertEqual(names.rename(blank, for: account), "",
                           "a name of \(blank.unicodeScalars.count) unprintable scalars is not a name")
            XCTAssertEqual(names.title(for: account), defaultTitle)
        }
    }

    func testClearingOneContactLeavesTheOthersNamed() {
        let other = String(repeating: "f", count: 64)
        var names = ContactNames(defaults: defaults)
        names.rename("Мама", for: account)
        names.rename("Папа", for: other)

        names.rename("", for: account)
        XCTAssertEqual(names.title(for: account), defaultTitle)
        XCTAssertEqual(names.title(for: other), "Папа")
        XCTAssertEqual(ContactNames(defaults: defaults).title(for: other), "Папа")
    }

    // MARK: - the name is only local

    func testALocalNameNeverLeavesThisInstallation() throws {
        var names = ContactNames(defaults: defaults)
        names.rename("Серёга", for: account)

        // 1. It is stored in this container's own defaults, under the one
        //    versioned key, and it is the only thing this client wrote there.
        let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Array(stored.keys), [ContactNames.defaultsKey])
        XCTAssertEqual(stored[ContactNames.defaultsKey] as? [String: String],
                       [account: "Серёга"])

        // 2. Another container — another installation, another phone — sees
        //    the default label. There is no transport for this name: nothing
        //    puts it on the wire and nothing puts it in the snapshot, so the
        //    only way a second store could know it is a shared file, and it
        //    has none.
        let otherSuite = "global.paranoid.messenger.tests.names.elsewhere"
        let elsewhere = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        elsewhere.removePersistentDomain(forName: otherSuite)
        defer { elsewhere.removePersistentDomain(forName: otherSuite) }
        XCTAssertEqual(ContactNames(defaults: elsewhere).title(for: account), defaultTitle)

        // 3. Nothing the core published moved: the account is the account, and
        //    the default label is still derived from it alone.
        XCTAssertEqual(MessagePresentation.title(account), defaultTitle)
        XCTAssertEqual(names.title(for: String(repeating: "b", count: 64)),
                       MessagePresentation.title(String(repeating: "b", count: 64)))

        // 4. The name dies with the container, as the defaults do.
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(ContactNames(defaults: defaults).title(for: account), defaultTitle)
    }

    func testATableWithNoDefaultsWritesNothingAnywhere() {
        var memory = ContactNames(defaults: nil)
        memory.rename("Серёга", for: account)
        XCTAssertEqual(memory.title(for: account), "Серёга")
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: ContactNames.defaultsKey))
    }

    func testAStoredNameIsReadBackAndAnEmptyAccountIsNeverNamed() {
        var names = ContactNames(defaults: defaults)
        XCTAssertEqual(names.rename("Серёга", for: ""), "", "an empty account has no name")
        XCTAssertEqual(names.name(for: ""), "")
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey))

        names.rename("  Серёга  ", for: account)
        XCTAssertEqual(ContactNames(defaults: defaults).name(for: account), "Серёга",
                       "the next launch reads the name back, normalized")
        XCTAssertEqual(ContactNames.defaultsKey, "paranoid.contact-names.v1")
        XCTAssertEqual(ContactNames.maxLength, 40)
    }

    func testAStoredValueThatIsNotANameIsIgnoredRatherThanShown() {
        defaults.set([account: 17, String(repeating: "c", count: 64): "  Папа  ", "": "x"],
                     forKey: ContactNames.defaultsKey)
        let names = ContactNames(defaults: defaults)
        XCTAssertEqual(names.title(for: account), defaultTitle)
        XCTAssertEqual(names.name(for: String(repeating: "c", count: 64)), "Папа")
        XCTAssertEqual(names.name(for: ""), "")
    }

    // MARK: - the normalizer (`ContactNamesSmoke.java`)

    func testNormalizeIsTheAndroidNormalizerCharacterForCharacter() {
        XCTAssertEqual(ContactNames.normalize(""), "")
        XCTAssertEqual(ContactNames.normalize("   "), "")
        XCTAssertEqual(ContactNames.normalize("  Серёга  "), "Серёга")
        XCTAssertEqual(ContactNames.normalize("Мама\nпапа\tдом"), "Мама папа дом")
        XCTAssertEqual(ContactNames.normalize("a\u{0000}b\u{200E}c\u{202E}d"), "abcd")
        XCTAssertEqual(ContactNames.normalize("x   y"), "x y")
        // `isSpaceChar` is wider than `\s`: a non-breaking space collapses
        // here, unlike in a message preview.
        XCTAssertEqual(ContactNames.normalize("x\u{00A0}\u{00A0}y"), "x y")

        let long = String(repeating: "ж", count: 100)
        XCTAssertEqual(ContactNames.normalize(long).unicodeScalars.count, ContactNames.maxLength)
        // A cut never splits a surrogate pair: Java counts code points and so
        // does this, so 40 emoji survive as 40 emoji.
        let emoji = String(repeating: "😀", count: 50)
        XCTAssertEqual(ContactNames.normalize(emoji).unicodeScalars.count, ContactNames.maxLength)
        XCTAssertEqual(ContactNames.normalize(emoji), String(repeating: "😀", count: 40))
        // The cut is trimmed again, so a name never ends in the space the cut
        // exposed.
        XCTAssertEqual(ContactNames.normalize(String(repeating: "ж", count: 40) + " хвост"),
                       String(repeating: "ж", count: 40))
    }

    func testALongNameIsStoredBoundedRatherThanRefused() {
        var names = ContactNames(defaults: defaults)
        let kept = names.rename(String(repeating: "ж", count: 100), for: account)
        XCTAssertEqual(kept.unicodeScalars.count, ContactNames.maxLength)
        XCTAssertEqual(names.title(for: account), kept)
    }
}
