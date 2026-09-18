import Foundation

/// The name a contact has **on this phone**, and nowhere else.
///
/// It is `clients/android/src/org/paranoid/text/ContactNames.java` (Android
/// v22, owner request 2026-09-12), rule for rule: a purely presentational
/// label, kept in the application's own defaults keyed by account, never sent
/// to the peer or the server and never part of the encrypted snapshot — the
/// state file is not touched by anything here. A contact with no name of its
/// own keeps the default label, which is the account itself
/// (`MessagePresentation.title`).
///
/// Two consequences are worth saying out loud, because they are the reason
/// this is a *local* name and not a profile:
///
/// - **Nothing a peer chose can reach it.** The only writer is the person
///   holding the phone, through «Переименовать»; the core publishes no name
///   and this type reads none.
/// - **Container deletion removes it, and no backup carries it.** The table
///   lives in a `LocalMetadataStore` file beside the state file, excluded
///   from OS backup on its inode, so a restore onto a second device brings no
///   names with it (RFC-0024). A phone updating from a build that kept the
///   names in `UserDefaults` migrates them once, and the old preference is
///   cleared only after the file has been read back and proven excluded.
///
/// The value semantics are what the screens need: the table is held here, a
/// rename mutates it and writes it through in the same call, so a model that
/// stores a `ContactNames` publishes the change by mutating its own property.
/// It is deliberately **not** `Sendable`: the store it writes through is not,
/// and this table belongs to the one actor that shows it — the main actor,
/// where the screens are.
public struct ContactNames: Equatable {
    /// The file the whole table lives in, inside the directory that holds the
    /// state file. Versioned, so a later rule can be told apart from this one
    /// rather than reinterpreting it (`ContactNames.java:14`,
    /// `paranoid-contact-names-v1`).
    public static let fileName = "contact-names.v1.json"

    /// The preference this table used to live in. A phone updating from an
    /// earlier build still has it; it is read once, migrated, and cleared.
    public static let defaultsKey = "paranoid.contact-names.v1"

    /// The longest name kept, in code points (`ContactNames.java:15`).
    public static let maxLength = 40

    /// account -> name. Only non-empty names are ever in it.
    private var names: [String: String]

    /// Where the table is read from and written back to, or `nil` for a table
    /// that only lives in memory.
    private let store: LocalMetadataStore?

    /// The application's table, in the backup-excluded container file.
    public static func applicationStore() -> LocalMetadataStore? {
        LocalMetadataStore.applicationSupport(name: fileName, legacyKey: defaultsKey)
    }

    /// - Parameter store: the application's file; the tests pass one in a
    ///   scratch directory so that a run leaves nothing behind.
    public init(store: LocalMetadataStore? = ContactNames.applicationStore()) {
        self.store = store
        // The store is told what a table looks like, so that a file it can read
        // but this build cannot parse is treated as absent rather than as an
        // empty table: a preference left by an interrupted migration is then
        // still used, and the corrupt file is written over instead of trusted.
        var parsed: [String: String]?
        let data = store?.load(migrating: Self.carriedForward, validate: { bytes in
            parsed = Self.table(from: bytes)
            return parsed != nil
        })
        if let parsed {
            names = Self.sanitize(parsed)
            return
        }
        // Anything that arrives here came from the preference, which the store
        // does not parse.
        guard let data, let carried = Self.table(from: data) else {
            names = [:]
            return
        }
        names = Self.sanitize(carried)
    }

    private static func table(from data: Data) -> [String: String]? {
        try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Anything that is not a name this build would agree to store is dropped
    /// on the way in rather than shown.
    private static func sanitize(_ table: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (account, value) in table {
            guard !account.isEmpty else { continue }
            let name = normalize(value)
            guard !name.isEmpty else { continue }
            clean[account] = name
        }
        return clean
    }

    /// The preference of an earlier build, as the JSON the file now holds. It
    /// was a plist dictionary, so anything in it that is not a string is not a
    /// name and does not survive the move.
    private static func carriedForward(_ defaults: UserDefaults) -> Data? {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return nil }
        var table: [String: String] = [:]
        for (account, value) in stored {
            guard let text = value as? String else { continue }
            table[account] = text
        }
        let clean = sanitize(table)
        guard !clean.isEmpty else { return nil }
        return try? JSONEncoder().encode(clean)
    }

    /// The name typed for this contact, or the empty string
    /// (`ContactNames.java:17-20`).
    public func name(for account: String) -> String {
        guard !account.isEmpty else { return "" }
        return names[account] ?? ""
    }

    /// What every screen shows for this contact: the local name if there is
    /// one, and otherwise the default label (`ContactNames.java:28-31`).
    public func title(for account: String) -> String {
        let custom = name(for: account)
        return custom.isEmpty ? MessagePresentation.title(account) : custom
    }

    /// «Сохранить» in «Имя контакта» (`ContactNames.java:22-27`).
    ///
    /// The text is normalized first; an empty or blank one **clears** the
    /// name, which is how the default label is restored. The stored value is
    /// answered so that a caller can show exactly what was kept.
    @discardableResult
    public mutating func rename(_ name: String, for account: String) -> String {
        guard !account.isEmpty else { return "" }
        let clean = Self.normalize(name)
        if clean.isEmpty {
            names.removeValue(forKey: account)
        } else {
            names[account] = clean
        }
        write()
        return clean
    }

    /// Two tables are the same when they name the same contacts the same way;
    /// which suite they were read from is not part of that.
    public static func == (left: ContactNames, right: ContactNames) -> Bool {
        left.names == right.names
    }

    /// One line, trimmed, bounded; control and format characters removed
    /// (`ContactNames.java:33-45`).
    ///
    /// Java maps every whitespace **and** every space character to `' '`
    /// first — so a non-breaking space collapses here although it is not `\s`
    /// — then drops the ISO controls and the `Cf` formatting characters that
    /// a bidirectional override would arrive as, then collapses the runs,
    /// trims, and cuts at `maxLength` **code points**, which never splits a
    /// surrogate pair.
    public static func normalize(_ name: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if isJavaSpace(scalar) {
                mapped.append(" ")
            } else if isIsoControl(scalar) || scalar.properties.generalCategory == .format {
                continue
            } else {
                mapped.append(scalar)
            }
        }
        var line = trim(collapseSpaces(String(mapped)))
        guard line.unicodeScalars.count > maxLength else { return line }
        line = String(String.UnicodeScalarView(line.unicodeScalars.prefix(maxLength)))
        return trim(line)
    }

    // MARK: - storage

    private func write() {
        guard let store else { return }
        if names.isEmpty {
            store.clear()
        } else if let data = try? JSONEncoder().encode(names) {
            store.save(data)
        }
    }

    // MARK: - the Java string rules

    /// `" {2,}" -> " "`.
    private static func collapseSpaces(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            let isSpace = scalar == " "
            if isSpace && previousWasSpace { continue }
            out.append(scalar)
            previousWasSpace = isSpace
        }
        return String(out)
    }

    /// `String.trim()`: Java trims every character at or below U+0020 from
    /// both ends, not the Unicode whitespace set.
    private static func trim(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `Character.isWhitespace(cp) || Character.isSpaceChar(cp)`: the ASCII
    /// control whitespace and the file/group/record/unit separators, plus
    /// every Unicode separator — the non-breaking spaces included, which is
    /// where `isSpaceChar` is wider than `isWhitespace`.
    private static func isJavaSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\u{0B}", "\u{0C}", "\r",
             "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}":
            return true
        default:
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// `Character.isISOControl(cp)`.
    private static func isIsoControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }
}
