import Foundation

/// Why one file operation failed, with enough detail to diagnose a freeze
/// without ever naming the snapshot contents.
///
/// The path of the state file is not a secret (it is a fixed name inside the
/// application container); the bytes it holds are, and never appear here.
public struct FileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The operation that failed, in the vocabulary of `FileSystem`.
    public enum Operation: String, Equatable, Sendable {
        case createDirectory
        case excludeFromBackup
        case readBackupFlag
        case write
        case fullSync
        case rename
        case read
        case remove
    }

    public let operation: Operation
    /// Last path component only: enough to tell the temporary file from the
    /// committed one and from the directory, without printing the container.
    public let name: String
    /// `errno`, an `OSStatus`, or the code of the underlying `NSError`.
    public let code: Int
    /// A short machine-readable reason, never a file content.
    public let reason: String

    public init(_ operation: Operation, _ url: URL, code: Int, reason: String) {
        self.operation = operation
        self.name = url.lastPathComponent
        self.code = code
        self.reason = reason
    }

    /// A failure reported through `errno`.
    public init(_ operation: Operation, _ url: URL, errno code: Int32) {
        self.init(operation, url, code: Int(code), reason: String(cString: strerror(code)))
    }

    /// A failure reported by Foundation.
    public init(_ operation: Operation, _ url: URL, underlying error: Error) {
        let error = error as NSError
        self.init(operation, url, code: error.code, reason: error.domain)
    }

    public var description: String {
        "file \(operation.rawValue) of \(name) failed: \(reason) (\(code))"
    }
}

/// Every file operation the snapshot commit depends on, as one injectable
/// seam.
///
/// The commit sequence of `docs/protocol/first-contact-v1.md:173-178` ("seals,
/// fsyncs, readback-validates the full candidate before adopting UI or sending
/// any pending frame") only holds if each step really reached the device, so
/// each step is its own method here and the host tests substitute an in-memory
/// implementation that fails exactly one of them. Nothing in this protocol
/// interprets the bytes; encryption is `SnapshotCodec`, the ordering rules are
/// `SnapshotStore`.
///
/// Implementations are synchronous on purpose: a commit must complete before
/// the caller may use the new keys, so there is nothing to overlap with.
public protocol FileSystem {
    /// Whether anything exists at `url` (a file or a directory).
    func fileExists(at url: URL) -> Bool
    /// Creates `url` and any missing parent, owner-only, with the data
    /// protection class the state file needs.
    func createDirectory(at url: URL) throws
    /// Sets `isExcludedFromBackup` on `url`. The flag lives on the inode, so
    /// it must be set on the temporary file **before** the rename, not on the
    /// committed name afterwards.
    func excludeFromBackup(at url: URL) throws
    /// Reads back the flag `excludeFromBackup(at:)` sets.
    func isExcludedFromBackup(at url: URL) throws -> Bool
    /// Creates or truncates `url` and writes `data`, with the data protection
    /// class of the state file.
    func write(_ data: Data, to url: URL) throws
    /// `fcntl(F_FULLFSYNC)` on `url`: not `fsync`, which on Darwin may leave
    /// the bytes in the drive's write cache. `directory` states what the
    /// caller expects the inode to be, the `S_ISDIR` check of
    /// `TextEngine.java:236`.
    func fullSync(at url: URL, directory: Bool) throws
    /// `rename(2)`: atomic replacement of `destination`, which is what makes a
    /// half-written state impossible.
    func rename(from source: URL, to destination: URL) throws
    /// Reads `url`, refusing anything larger than `maximumBytes` before the
    /// bytes are mapped (`TextEngine.java:102`).
    func read(at url: URL, maximumBytes: Int) throws -> Data
    /// Removes `url`; a missing item is not an error.
    func removeItem(at url: URL) throws
}

/// The real file system: `FileManager` for metadata, POSIX for the durability
/// steps.
///
/// Foundation has no `F_FULLFSYNC` and its `Data.WritingOptions.atomic` uses a
/// temporary name of its own choosing, which cannot be excluded from backup
/// before the rename — so the commit drives `open`/`fcntl`/`rename` directly
/// and Foundation is used only where it adds the data protection class and the
/// backup flag.
public struct DataProtectionFileSystem: FileSystem, Sendable {
    /// The shared `FileManager`, used for metadata only; the durability steps
    /// go straight to POSIX. It is not a stored property because this type
    /// crosses isolation domains and `FileManager` is not `Sendable`.
    private var manager: FileManager { .default }

    public init() {}

    /// `Application Support/paranoid/`, the directory that holds
    /// `text-state.enc`.
    ///
    /// `Application Support` itself may not exist yet in a fresh container;
    /// `createDirectory(at:)` creates both.
    public static func applicationSupportDirectory(manager: FileManager = .default) throws -> URL {
        try manager.url(for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: false)
            .appendingPathComponent("paranoid", isDirectory: true)
    }

    public func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o700)]
        #if os(iOS)
        // The state file is opened on every launch, including one that follows
        // a reboot before the passcode is entered, so the directory carries
        // the same class as the file.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        } catch {
            throw FileSystemError(.createDirectory, url, underlying: error)
        }
    }

    public func excludeFromBackup(at url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            throw FileSystemError(.excludeFromBackup, url, underlying: error)
        }
    }

    public func isExcludedFromBackup(at url: URL) throws -> Bool {
        var target = url
        // `URL` caches resource values; a flag set through another `URL` value
        // would otherwise not be visible here.
        target.removeAllCachedResourceValues()
        do {
            return try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        } catch {
            throw FileSystemError(.readBackupFlag, url, underlying: error)
        }
    }

    public func write(_ data: Data, to url: URL) throws {
        do {
            #if os(iOS)
            try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url)
            #endif
        } catch {
            throw FileSystemError(.write, url, underlying: error)
        }
    }

    public func fullSync(at url: URL, directory: Bool) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { throw FileSystemError(.fullSync, url, errno: errno) }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw FileSystemError(.fullSync, url, errno: errno)
        }
        guard (information.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw FileSystemError(.fullSync, url, code: Int(ENOTDIR),
                                  reason: directory ? "not a directory" : "not a regular file")
        }
        guard fcntl(descriptor, F_FULLFSYNC) != -1 else {
            throw FileSystemError(.fullSync, url, errno: errno)
        }
    }

    public func rename(from source: URL, to destination: URL) throws {
        var code: Int32 = 0
        let result = source.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else {
                    code = EINVAL
                    return -1
                }
                let status = Darwin.rename(from, to)
                code = errno
                return status
            }
        }
        guard result == 0 else { throw FileSystemError(.rename, destination, errno: code) }
    }

    public func read(at url: URL, maximumBytes: Int) throws -> Data {
        let size: Int
        do {
            size = (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw FileSystemError(.read, url, underlying: error)
        }
        guard size <= maximumBytes else {
            throw FileSystemError(.read, url, code: Int(EFBIG), reason: "stored snapshot above the read limit")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [])
        } catch {
            throw FileSystemError(.read, url, underlying: error)
        }
        guard data.count <= maximumBytes else {
            throw FileSystemError(.read, url, code: Int(EFBIG), reason: "stored snapshot above the read limit")
        }
        return data
    }

    public func removeItem(at url: URL) throws {
        guard manager.fileExists(atPath: url.path) else { return }
        do {
            try manager.removeItem(at: url)
        } catch {
            throw FileSystemError(.remove, url, underlying: error)
        }
    }
}
