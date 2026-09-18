import Foundation
import ParanoidKit
import XCTest

/// The local display name of a contact (Android v22, `ContactNames.java`).
///
/// Three rules are the point of this file. Two are the ones the owner asked
/// for: **an empty value restores the default label**, and **the name is only
/// local** — it lives in this installation's own container, it is invisible to
/// any other one, and it changes nothing the core published. The third is
/// newer: **no OS backup carries it**, so a restore onto a second phone brings
/// no names with it, and an installation updating from the build that kept
/// them in preferences moves them across once. The rest is the normalizer,
/// transcribed from `clients/android/test/ContactNamesSmoke.java` so that the
/// same text typed on either phone is kept the same way.
final class ContactNamesTests: XCTestCase {
    /// A 64-character account, as the core publishes one.
    private let account = String(repeating: "0123456789abcdef", count: 4)
    /// What every screen shows for that account with no local name.
    private var defaultTitle: String { MessagePresentation.title(account) }

    /// The container these cases write names into: a directory of this case's
    /// own for the file that holds the table, and a scratch defaults suite for
    /// the preference an older build would have left behind. The suite has one
    /// fixed name for every case and every run, emptied around each of them: a
    /// removed domain still leaves its file behind in the host's preferences,
    /// so a name minted per case left one more of them there on every
    /// execution. `defaults` has no value until `setUpWithError` gives it one,
    /// because the standard suite is not a safe stand-in for a scratch one
    /// even as an unread placeholder.
    private let suite = "global.paranoid.messenger.tests.names"
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-names-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suite)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// The application's store, in this case's own directory.
    private func store() -> LocalMetadataStore {
        LocalMetadataStore(name: ContactNames.fileName, legacyKey: ContactNames.defaultsKey,
                           directory: directory, defaults: defaults)
    }

    /// A table reading that store — a launch, in other words.
    private func table() -> ContactNames { ContactNames(store: store()) }

    // MARK: - the empty value restores the default

    func testAnEmptyNameRestoresTheDefaultTitle() {
        var names = table()
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().fileURL.path))
        XCTAssertEqual(table().title(for: account), defaultTitle)
    }

    func testABlankOrUnprintableNameClearsItJustAsAnEmptyOneDoes() {
        var names = table()
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
        var names = table()
        names.rename("Мама", for: account)
        names.rename("Папа", for: other)

        names.rename("", for: account)
        XCTAssertEqual(names.title(for: account), defaultTitle)
        XCTAssertEqual(names.title(for: other), "Папа")
        XCTAssertEqual(table().title(for: other), "Папа")
    }

    // MARK: - the name is only local, and no backup carries it

    func testALocalNameNeverLeavesThisInstallation() throws {
        var names = table()
        names.rename("Серёга", for: account)

        // 1. It is stored in this container's own file, under the one
        //    versioned name, and it is the only thing this client wrote there.
        let stored = try Data(contentsOf: store().fileURL)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: stored),
                       [account: "Серёга"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       [ContactNames.fileName])
        // 1a. And an OS backup does not carry it, which is what makes the
        //     name local to the *phone* and not only to the messenger.
        XCTAssertTrue(store().isExcludedFromBackup())
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[ContactNames.defaultsKey],
                     "the preference that a backup did carry is not written any more")

        // 2. Another container — another installation, another phone — sees
        //    the default label. There is no transport for this name: nothing
        //    puts it on the wire and nothing puts it in the snapshot, so the
        //    only way a second store could know it is a shared file, and it
        //    has none.
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-names-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let otherStore = LocalMetadataStore(name: ContactNames.fileName,
                                            legacyKey: ContactNames.defaultsKey,
                                            directory: elsewhere, defaults: nil)
        XCTAssertEqual(ContactNames(store: otherStore).title(for: account), defaultTitle)

        // 3. Nothing the core published moved: the account is the account, and
        //    the default label is still derived from it alone.
        XCTAssertEqual(MessagePresentation.title(account), defaultTitle)
        XCTAssertEqual(names.title(for: String(repeating: "b", count: 64)),
                       MessagePresentation.title(String(repeating: "b", count: 64)))

        // 4. The name dies with the container.
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(table().title(for: account), defaultTitle)
    }

    func testATableWithNoStoreWritesNothingAnywhere() {
        var memory = ContactNames(store: nil)
        memory.rename("Серёга", for: account)
        XCTAssertEqual(memory.title(for: account), "Серёга")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: ContactNames.defaultsKey))
    }

    func testAStoredNameIsReadBackAndAnEmptyAccountIsNeverNamed() {
        var names = table()
        XCTAssertEqual(names.rename("Серёга", for: ""), "", "an empty account has no name")
        XCTAssertEqual(names.name(for: ""), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().fileURL.path))

        names.rename("  Серёга  ", for: account)
        XCTAssertEqual(table().name(for: account), "Серёга",
                       "the next launch reads the name back, normalized")
        XCTAssertEqual(ContactNames.fileName, "contact-names.v1.json")
        XCTAssertEqual(ContactNames.defaultsKey, "paranoid.contact-names.v1")
        XCTAssertEqual(ContactNames.maxLength, 40)
    }

    func testAStoredValueThatIsNotANameIsIgnoredRatherThanShown() throws {
        let file = store().fileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"\#(account)":"","\#(String(repeating: "c", count: 64))":"  Папа  ","":"x"}"#.utf8)
            .write(to: file)
        let names = table()
        XCTAssertEqual(names.title(for: account), defaultTitle)
        XCTAssertEqual(names.name(for: String(repeating: "c", count: 64)), "Папа")
        XCTAssertEqual(names.name(for: ""), "")
    }

    // MARK: - the move out of the backup

    func testAnOlderBuildsNamesMoveOutOfTheBackupOnFirstLaunch() {
        // What an installation of the previous build left behind: a plist
        // dictionary in preferences, which an iCloud or encrypted local backup
        // carries to whatever device the owner restores onto.
        let other = String(repeating: "c", count: 64)
        defaults.set([account: "  Серёга  ", other: "Папа"], forKey: ContactNames.defaultsKey)

        let names = table()
        XCTAssertEqual(names.name(for: account), "Серёга", "the names survive the move, normalized")
        XCTAssertEqual(names.name(for: other), "Папа")
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey),
                     "and the copy a backup carried does not stay behind")
        XCTAssertTrue(store().isExcludedFromBackup())
        // The next launch reads the file, and the table is the same one.
        XCTAssertEqual(table(), names)
    }

    func testAPreferenceHoldingNothingNameableIsClearedWithoutWritingAFile() {
        defaults.set([account: 17, "": "x"], forKey: ContactNames.defaultsKey)
        XCTAssertEqual(table().title(for: account), defaultTitle)
        XCTAssertNil(defaults.object(forKey: ContactNames.defaultsKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().fileURL.path))
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
        var names = table()
        let kept = names.rename(String(repeating: "ж", count: 100), for: account)
        XCTAssertEqual(kept.unicodeScalars.count, ContactNames.maxLength)
        XCTAssertEqual(names.title(for: account), kept)
    }
}
