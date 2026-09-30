import Foundation
import ParanoidKit
import XCTest

/// The order of «Контакты» (`ContactOrder.alphabetical`): the named contacts
/// first, in Russian alphabetical order of their names, then the unnamed by
/// account; and the grouped fingerprint (`MessagePresentation.groupedFingerprint`).
final class ContactOrderTests: XCTestCase {
    func testNamedContactsComeFirstInRussianAlphabeticalOrder() {
        let names = ["a1": "Сергей", "b2": "", "c3": "Аня", "d4": "Юра", "e5": "борис"]
        let ordered = ContactOrder.alphabetical(["a1", "b2", "c3", "d4", "e5"].map(dialog),
                                                name: { names[$0] ?? "" })
        XCTAssertEqual(ordered.map(\.account), ["c3", "e5", "a1", "d4", "b2"])
    }

    func testCaseAndDiacriticsDoNotSeparateNamesAndLatinFollowsCyrillic() {
        let names = ["a1": "ёж", "b2": "Ежи", "c3": "Alice", "d4": "Ярослав"]
        let ordered = ContactOrder.alphabetical(["a1", "b2", "c3", "d4"].map(dialog),
                                                name: { names[$0] ?? "" })
        // «ёж» reads as «еж», which stands before «Ежи» as its prefix; the
        // Latin name comes after the Cyrillic ones.
        XCTAssertEqual(ordered.map(\.account), ["a1", "b2", "d4", "c3"])
    }

    /// Each option of the collation, on a pair the others do not decide.
    func testCaseDiacriticsAndNumbersAreEachHandled() {
        // Case: «аня» and «Аня» are one name, so the account decides.
        var names = ["z9": "аня", "a1": "Аня"]
        XCTAssertEqual(ContactOrder.alphabetical(["z9", "a1"].map(dialog), name: { names[$0] ?? "" })
                        .map(\.account), ["a1", "z9"])
        // Diacritics: «еж» and «ёж» are one name.
        names = ["z9": "еж", "a1": "ёж"]
        XCTAssertEqual(ContactOrder.alphabetical(["z9", "a1"].map(dialog), name: { names[$0] ?? "" })
                        .map(\.account), ["a1", "z9"])
        // «ё» files as «е»: «Ёлка» between «Ежи» and «Жук».
        names = ["a1": "Жук", "b2": "Ёлка", "c3": "Ежи"]
        XCTAssertEqual(ContactOrder.alphabetical(["a1", "b2", "c3"].map(dialog), name: { names[$0] ?? "" })
                        .map(\.account), ["c3", "b2", "a1"])
        // Numbers by value: «Сергей 2» before «Сергей 10».
        names = ["a1": "Сергей 10", "b2": "Сергей 2"]
        XCTAssertEqual(ContactOrder.alphabetical(["a1", "b2"].map(dialog), name: { names[$0] ?? "" })
                        .map(\.account), ["b2", "a1"])
    }

    func testEqualNamesAndTheUnnamedKeepTheAccountOrder() {
        let names = ["z9": "Сергей", "a1": "Сергей", "m5": "", "b2": ""]
        let ordered = ContactOrder.alphabetical(["z9", "a1", "m5", "b2"].map(dialog),
                                                name: { names[$0] ?? "" })
        XCTAssertEqual(ordered.map(\.account), ["a1", "z9", "b2", "m5"])
    }

    func testNothingToSortIsLeftAlone() {
        XCTAssertEqual(ContactOrder.alphabetical([], name: { _ in "" }), [])
        let one = [dialog("only")]
        XCTAssertEqual(ContactOrder.alphabetical(one, name: { _ in "Имя" }), one)
    }

    // MARK: - the grouped fingerprint

    func testTheFingerprintIsGroupedByEightFourToALineAndLosesNothing() {
        let fingerprint = String(repeating: "0123456789abcdef", count: 4)
        let grouped = MessagePresentation.groupedFingerprint(fingerprint)
        XCTAssertEqual(grouped, "01234567 89abcdef 01234567 89abcdef\n01234567 89abcdef 01234567 89abcdef")
        XCTAssertEqual(grouped.filter { $0 != " " && $0 != "\n" }, fingerprint)
        XCTAssertEqual(MessagePresentation.groupedFingerprint(""), "")
        XCTAssertEqual(MessagePresentation.groupedFingerprint("0123456789"), "01234567 89")
    }

    func testADialogCarriesTheFingerprintTheCorePublished() {
        let raw: [String: Any] = ["account": "b41d079a5c", "own": "me", "trust": "network_unverified",
                                  "blocked": false, "messages": [],
                                  "fingerprint": String(repeating: "ab", count: 32)]
        XCTAssertEqual(Dialog.decode(raw)?.fingerprint, String(repeating: "ab", count: 32))
        XCTAssertEqual(Dialog.decode(["account": "b41d079a5c"])?.fingerprint, "")
    }

    private func dialog(_ account: String) -> Dialog {
        Dialog(account: account, own: "me", trust: "network_unverified", isBlocked: false, messages: [])
    }
}
