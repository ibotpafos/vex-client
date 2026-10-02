import Darwin
import Foundation

/// A lease is held for the complete operation, not for a wall-clock TTL.
/// The file inode must remain in place after unlocking (unlinking it permits
/// two processes to lock different inodes under the same path).
final class HelperOperationLease {
    private static let registryLock = NSLock()
    private static var heldPaths = Set<String>()
    private let path: String
    private var descriptor: Int32?

    static func acquire(path: String, fileSystem: HelperFileSystem) throws -> HelperOperationLease {
        let inserted = registryLock.withLock { heldPaths.insert(path).inserted }
        guard inserted else { throw HelperError.operationInProgress }
        do {
            // All production construction uses LocalFileSystem. In-memory
            // filesystem ports must not open real host paths in offline tests.
            let fd = fileSystem is LocalFileSystem ? try openLockedFile(path + ".lease") : nil
            return HelperOperationLease(path: path, descriptor: fd)
        } catch {
            _ = registryLock.withLock { heldPaths.remove(path) }
            throw error
        }
    }

    static func isHeld(path: String, fileSystem: HelperFileSystem) -> Bool {
        if registryLock.withLock({ heldPaths.contains(path) }) { return true }
        guard fileSystem is LocalFileSystem else { return false }
        let fd = Darwin.open(path + ".lease", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return errno != ENOENT }
        defer { Darwin.close(fd) }
        guard isPrivateRegularFile(fd) else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        _ = flock(fd, LOCK_UN)
        return false
    }

    private init(path: String, descriptor: Int32?) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        if let descriptor {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        _ = Self.registryLock.withLock { Self.heldPaths.remove(path) }
    }

    private static func isPrivateRegularFile(_ fd: Int32) -> Bool {
        var metadata = stat()
        return fstat(fd, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
            && (metadata.st_mode & 0o077) == 0
    }

    private static func openLockedFile(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw HelperError.io("could not open helper operation lease") }
        guard isPrivateRegularFile(fd) else {
            Darwin.close(fd)
            throw HelperError.io("helper operation lease is not a private regular file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(fd)
            if failure == EWOULDBLOCK || failure == EAGAIN { throw HelperError.operationInProgress }
            throw HelperError.io("could not acquire helper operation lease")
        }
        var descriptorMetadata = stat(), pathMetadata = stat()
        guard fstat(fd, &descriptorMetadata) == 0, lstat(path, &pathMetadata) == 0,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino else {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
            throw HelperError.io("helper operation lease path changed")
        }
        return fd
    }
}
