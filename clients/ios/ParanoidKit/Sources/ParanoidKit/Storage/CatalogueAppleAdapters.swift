import CryptoKit
import Foundation

/// Why one Apple catalogue adapter operation failed. Names the operation and
/// the POSIX/Foundation code only: never a path beyond its last component,
/// never file contents or key material.
public struct CatalogueAppleAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Operation: String, Equatable, Sendable {
        case inspect, create, write, protect, sync, rename, read, remove, seal, open
    }
    public let operation: Operation
    public let name: String
    public let code: Int
    public let reason: String

    public init(_ operation: Operation, _ url: URL?, code: Int, reason: String) {
        self.operation = operation
        self.name = url?.lastPathComponent ?? "-"
        self.code = code
        self.reason = reason
    }

    /// A failure reported through `errno`.
    init(_ operation: Operation, _ url: URL?, errno code: Int32) {
        self.init(operation, url, code: Int(code), reason: String(cString: strerror(code)))
    }

    /// A failure reported by Foundation or by a reused `FileSystem` step.
    init(_ operation: Operation, _ url: URL?, underlying error: Error) {
        if let known = error as? FileSystemError {
            self.init(operation, url, code: known.code, reason: known.reason)
        } else {
            let error = error as NSError
            self.init(operation, url, code: error.code, reason: error.domain)
        }
    }

    public var description: String {
        "catalogue \(operation.rawValue) of \(name) failed: \(reason) (\(code))"
    }
}

/// The POSIX calls the adapter drives directly, as one seam so a test can
/// inject a short, interrupted or growing transfer that the real file system
/// does not produce on demand. Production uses `.darwin`; the fault doubles
/// are labelled as such in the tests and never replace the positive native
/// execution of the same paths.
struct CatalogueAppleSyscalls: Sendable {
    var lstat: @Sendable (UnsafePointer<CChar>, UnsafeMutablePointer<stat>) -> Int32
    var open: @Sendable (UnsafePointer<CChar>, Int32, mode_t) -> Int32
    var fstat: @Sendable (Int32, UnsafeMutablePointer<stat>) -> Int32
    var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    var close: @Sendable (Int32) -> Int32
    var unlink: @Sendable (UnsafePointer<CChar>) -> Int32
    var mkdir: @Sendable (UnsafePointer<CChar>, mode_t) -> Int32
    var fchmod: @Sendable (Int32, mode_t) -> Int32

    static let darwin = CatalogueAppleSyscalls(
        lstat: { Darwin.lstat($0, $1) },
        open: { Darwin.open($0, $1, $2) },
        fstat: { Darwin.fstat($0, $1) },
        read: { Darwin.read($0, $1, $2) },
        write: { Darwin.write($0, $1, $2) },
        close: { Darwin.close($0) },
        unlink: { Darwin.unlink($0) },
        mkdir: { Darwin.mkdir($0, $1) },
        fchmod: { Darwin.fchmod($0, $1) })
}

/// `CatalogueFileIO` over the real Apple file system. Proposed, non-adopted
/// (RFC-0030 / draft ADR-0017). The durability steps that `SnapshotStore`
/// already ships — Data Protection, backup exclusion, `F_FULLFSYNC`,
/// `rename(2)` — are reused through the injected `FileSystem`; what is new
/// here is the stricter seam the catalogue transaction needs: throwing
/// no-follow inspection, create-only writes and bounded descriptor reads.
/// Nothing in this type deletes, repairs or recreates anything but the
/// intent marker the transaction asks it to remove.
public struct CatalogueAppleFileIO: CatalogueFileIO {
    private let fileSystem: any FileSystem
    private let syscalls: CatalogueAppleSyscalls

    /// `fileSystem` supplies the already shipped Data Protection, backup
    /// exclusion, `F_FULLFSYNC` and `rename(2)` steps. No default argument:
    /// the caller names the backend, as it names the directory.
    public init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, syscalls: .darwin)
    }

    init(fileSystem: any FileSystem, syscalls: CatalogueAppleSyscalls) {
        self.fileSystem = fileSystem
        self.syscalls = syscalls
    }

    // MARK: Inspection

    /// `lstat(2)`: never follows a symbolic link. Only `ENOENT` is absence;
    /// `ENOTDIR`, permission and protection errors are thrown, because the
    /// transaction must not mistake an unreadable path for an empty one.
    public func inspect(_ url: URL) throws -> CataloguePathKind {
        var information = stat()
        let (result, code) = withPath(url) { path in (syscalls.lstat(path, &information), errno) }
        guard result == 0 else {
            if code == ENOENT { return .absent }
            throw CatalogueAppleAdapterError(.inspect, url, errno: code)
        }
        return Self.kind(of: information)
    }

    private static func kind(of information: stat) -> CataloguePathKind {
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    // MARK: Writing

    /// `open(O_CREAT | O_EXCL | O_NOFOLLOW)`, owner-only: an existing name of
    /// any kind is refused, never truncated or replaced. A failed or short
    /// transfer leaves whatever reached the inode in place as evidence; this
    /// adapter never unlinks as compensation.
    public func writeExclusive(_ bytes: Data, to url: URL) throws {
        let descriptor = try openDescriptor(url, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                            mode: 0o600, operation: .create)
        var open = true
        defer { if open { _ = syscalls.close(descriptor) } }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = syscalls.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw CatalogueAppleAdapterError(.write, url, errno: code)
                }
                guard written > 0 else {
                    throw CatalogueAppleAdapterError(.write, url, code: Int(EIO), reason: "zero-length write")
                }
                offset += written
            }
        }
        open = false
        let closed = syscalls.close(descriptor)
        // On Darwin the descriptor is gone even when close reports EINTR.
        guard closed == 0 || errno == EINTR else {
            throw CatalogueAppleAdapterError(.write, url, errno: errno)
        }
    }

    /// Data Protection class of the state file (iOS only; the macOS host has
    /// no such attribute) and the backup exclusion flag, set on this inode
    /// and read back, so the flag travels with the later rename.
    public func protectAndExclude(_ url: URL) throws {
        #if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch {
            throw CatalogueAppleAdapterError(.protect, url, underlying: error)
        }
        #endif
        do {
            try fileSystem.excludeFromBackup(at: url)
            guard try fileSystem.isExcludedFromBackup(at: url) else {
                throw CatalogueAppleAdapterError(.protect, url, code: Int(EIO), reason: "backup exclusion did not stick")
            }
        } catch let error as CatalogueAppleAdapterError {
            throw error
        } catch {
            throw CatalogueAppleAdapterError(.protect, url, underlying: error)
        }
    }

    /// The shipped `fcntl(F_FULLFSYNC)` step, with its own inode-type check.
    public func fullSync(_ url: URL, directory: Bool) throws {
        do { try fileSystem.fullSync(at: url, directory: directory) }
        catch { throw CatalogueAppleAdapterError(.sync, url, underlying: error) }
    }

    /// The shipped `rename(2)` step: atomic replacement of `destination`.
    public func rename(_ source: URL, to destination: URL) throws {
        do { try fileSystem.rename(from: source, to: destination) }
        catch { throw CatalogueAppleAdapterError(.rename, destination, underlying: error) }
    }

    // MARK: Reading

    /// Inspect without following, require a regular file, open `O_NOFOLLOW`,
    /// confirm the opened inode is the inspected one, then read through the
    /// descriptor into a buffer of the inspected size plus one byte. A file
    /// that is larger, or that grows while being read, is refused; nothing is
    /// decoded on the way. The three stages are separate internal steps so the
    /// owner adapter can classify a failure by the exact stage it came from.
    public func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let inspected = try inspectRegular(url, maximumBytes: maximumBytes)
        let descriptor = try openRegular(url, inspected: inspected)
        defer { _ = syscalls.close(descriptor) }
        return try readBounded(descriptor, url: url, inspected: inspected, maximumBytes: maximumBytes)
    }

    /// Stage 1: no-follow inspection. The limit is validated first because the
    /// buffer below needs room for one byte past it (follow-up of the first
    /// receipt: an unchecked `maximumBytes + 1` trapped on `Int.max`). Only a
    /// regular file may be read; a FIFO is refused here, before any `open(2)`
    /// could block on it.
    func inspectRegular(_ url: URL, maximumBytes: Int) throws -> stat {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw CatalogueAppleAdapterError(.read, url, code: Int(EINVAL), reason: "read limit out of range")
        }
        var inspected = stat()
        let (result, code) = withPath(url) { path in (syscalls.lstat(path, &inspected), errno) }
        guard result == 0 else { throw CatalogueAppleAdapterError(.read, url, errno: code) }
        guard Self.kind(of: inspected) == .regularFile else {
            throw CatalogueAppleAdapterError(.read, url, code: Int(EFTYPE), reason: "not a regular file")
        }
        return inspected
    }

    /// Stage 2: `open(O_RDONLY|O_NOFOLLOW)` of the inspected inode. The error of
    /// a refused open carries the `errno` of that call and nothing else; the
    /// descriptor is returned open and belongs to the caller.
    func openRegular(_ url: URL, inspected: stat) throws -> Int32 {
        let descriptor = try openDescriptor(url, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC, mode: 0, operation: .read)
        var opened = stat()
        guard syscalls.fstat(descriptor, &opened) == 0 else {
            let code = errno
            _ = syscalls.close(descriptor)
            throw CatalogueAppleAdapterError(.read, url, errno: code)
        }
        guard Self.kind(of: opened) == .regularFile,
              opened.st_dev == inspected.st_dev, opened.st_ino == inspected.st_ino else {
            _ = syscalls.close(descriptor)
            throw CatalogueAppleAdapterError(.read, url, code: Int(EFTYPE), reason: "inode changed between inspection and open")
        }
        return descriptor
    }

    /// Stage 3: bounded descriptor read. Allocate for the inspected size plus
    /// one byte, never for the whole budget: a 1 KiB file under a 9 MiB limit
    /// costs 1 KiB + 1. Filling the buffer means the inode held more than it
    /// reported, which is refused whether or not the total still fits the limit.
    func readBounded(_ descriptor: Int32, url: URL, inspected: stat, maximumBytes: Int) throws -> Data {
        var opened = stat()
        guard syscalls.fstat(descriptor, &opened) == 0 else {
            throw CatalogueAppleAdapterError(.read, url, errno: errno)
        }
        guard opened.st_size >= 0, opened.st_size <= Int64(maximumBytes) else {
            throw CatalogueAppleAdapterError(.read, url, code: Int(EFBIG), reason: "stored bytes above the read limit")
        }
        let capacity = Int(opened.st_size) + 1
        var buffer = Data(count: capacity)
        var total = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < capacity {
                let received = syscalls.read(descriptor, base + total, capacity - total)
                if received < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw CatalogueAppleAdapterError(.read, url, errno: code)
                }
                if received == 0 { break }
                total += received
            }
        }
        guard total < capacity else {
            throw CatalogueAppleAdapterError(.read, url, code: Int(EFBIG), reason: "file grew while being read")
        }
        return buffer.prefix(total)
    }

    /// `unlink(2)` of the intent marker only: the name must be a regular file
    /// (no-follow), and a missing marker is an error, not a no-op, because the
    /// transaction created it moments ago.
    public func removeIntent(_ url: URL) throws {
        var information = stat()
        let (result, code) = withPath(url) { path in (syscalls.lstat(path, &information), errno) }
        guard result == 0 else { throw CatalogueAppleAdapterError(.remove, url, errno: code) }
        guard Self.kind(of: information) == .regularFile else {
            throw CatalogueAppleAdapterError(.remove, url, code: Int(EFTYPE), reason: "intent is not a regular file")
        }
        let (unlinked, unlinkCode) = withPath(url) { path in (syscalls.unlink(path), errno) }
        guard unlinked == 0 else { throw CatalogueAppleAdapterError(.remove, url, errno: unlinkCode) }
    }

    // MARK: Helpers

    private func openDescriptor(_ url: URL, flags: Int32, mode: mode_t,
                                operation: CatalogueAppleAdapterError.Operation) throws -> Int32 {
        let (descriptor, code) = withPath(url) { path in (syscalls.open(path, flags, mode), errno) }
        guard descriptor >= 0 else { throw CatalogueAppleAdapterError(operation, url, errno: code) }
        return descriptor
    }

    /// Runs `body` on the file-system representation of `url`; a URL that has
    /// none is reported as `EINVAL`, never as absence.
    private func withPath<T>(_ url: URL, _ body: (UnsafePointer<CChar>) -> (T, Int32)) -> (T, Int32)
    where T: FixedWidthInteger {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return (T(-1), EINVAL) }
            return body(path)
        }
    }
}

/// `CatalogueCryptography` over the shipped version-1 AES-GCM framing and the
/// existing opaque Keychain seams. Proposed, non-adopted. Keys stay
/// `SymmetricKey` values the backends own; nothing here exports, compares
/// bytes of, or deletes a key.
public struct CatalogueAppleCryptography: CatalogueCryptography {
    public typealias Key = SymmetricKey

    private let catalogue: any WrappingKeyStore
    private let owner: any RetainedKey
    private let fi: any RetainedKey
    private let ru: any RetainedKey

    /// Explicit key namespaces only; no default account and no key export.
    public init(catalogue: any WrappingKeyStore, owner: any RetainedKey,
                fi: any RetainedKey, ru: any RetainedKey) {
        self.catalogue = catalogue
        self.owner = owner
        self.fi = fi
        self.ru = ru
    }

    /// Version byte, nonce and tag of the shipped framing; not a new format.
    public var framingOverhead: Int { SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }

    /// `load()` never creates; backend errors propagate unchanged and the
    /// transaction treats them as failure, never as absence.
    public func loadKey() throws -> SymmetricKey? { try catalogue.load() }

    /// Create-only: the backend refuses to replace a retained key
    /// (`errSecDuplicateItem` for the Keychain), and so does this adapter.
    public func createKey() throws -> SymmetricKey { try catalogue.create() }

    public func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool {
        switch slot {
        case .owner: return try owner.exists()
        case .fi: return try fi.exists()
        case .ru: return try ru.exists()
        }
    }

    /// Seals through `SnapshotCodec.seal`, so the bytes are the shipped
    /// `[0x01][nonce][ciphertext‖tag]` layout the old reader also parses.
    public func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        try AppleFramedBox.seal(plaintext, with: key)
    }

    /// Authenticates the shipped framing and returns the raw plaintext bytes.
    public func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        try AppleFramedBox.open(sealed, with: key)
    }
}

/// The one sealing/opening routine both Apple adapters share, over the shipped
/// version-1 framing. Not a new format: `SnapshotCodec.seal` writes the box
/// and the old reader still parses it.
enum AppleFramedBox {
    /// The codec seals text; the store plaintexts are their own JSON, so exact
    /// UTF-8 is required and checked by re-encoding — never repaired.
    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let text = String(decoding: plaintext, as: UTF8.self)
        guard Data(text.utf8) == plaintext else {
            throw CatalogueAppleAdapterError(.seal, nil, code: Int(EILSEQ), reason: "plaintext is not exact UTF-8")
        }
        do { return try SnapshotCodec.seal(key: key, value: text) }
        catch { throw CatalogueAppleAdapterError(.seal, nil, underlying: error) }
    }

    /// Raw authenticated opening. This deliberately does not go through
    /// `SnapshotCodec.open`, whose String result repairs malformed UTF-8; the
    /// strict store codecs must see the bytes as stored. Works on any `Data`
    /// slice: every bound is taken from the value's own indices.
    static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        guard sealed.count >= SnapshotCodec.minimumSnapshotBytes,
              sealed.count <= SnapshotCodec.maximumSnapshotBytes,
              sealed.first == SnapshotCodec.version else {
            throw CatalogueAppleAdapterError(.open, nil, code: Int(EBADMSG), reason: "not a version-1 box")
        }
        let start = sealed.startIndex
        let nonce = sealed[start + 1..<start + SnapshotCodec.headerBytes]
        let tagStart = sealed.endIndex - SnapshotCodec.tagBytes
        let ciphertext = sealed[start + SnapshotCodec.headerBytes..<tagStart]
        let tag = sealed[tagStart..<sealed.endIndex]
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: Data([SnapshotCodec.version]))
        } catch {
            throw CatalogueAppleAdapterError(.open, nil, code: Int(EBADMSG), reason: "authentication failed")
        }
    }
}
