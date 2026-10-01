import Foundation
import Darwin

/// Small Darwin-only, descriptor-anchored store for staged push metadata.
/// Every path component is opened relative to a held directory FD with O_NOFOLLOW.
struct NativePushSecureFileStore {
    enum StoreError: Error { case invalidPath, unsafeFile, tooLarge; case io(stage: String, errno: Int32) }
    let rootURL: URL
    let maxBytes: Int
    var afterDirectoryFDOpened: (() -> Void)? = nil // test seam: called while FDs remain held

    init(rootURL: URL, maxBytes: Int = 64 * 1024, afterDirectoryFDOpened: (() -> Void)? = nil) {
        self.rootURL = rootURL
        self.maxBytes = min(max(1, maxBytes), 1024 * 1024)
        self.afterDirectoryFDOpened = afterDirectoryFDOpened
    }

    func ensureDirectory() throws { let fd = try openDirectory(createChild: true); close(fd) }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else { throw StoreError.invalidPath }
    }

    func read(_ name: String) throws -> Data? {
        try validateName(name)
        let dir: Int32
        do { dir = try openDirectory(createChild: false) } catch StoreError.io(let stage, let code) where stage == "child" && code == ENOENT { return nil }
        defer { close(dir) }
        afterDirectoryFDOpened?()
        try verifyDirectoryMapping(dir)
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw StoreError.io(stage: #function, errno: errno) }
        defer { close(fd) }
        try validateFile(fd)
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let n = Darwin.read(fd, &buffer, buffer.count); if n < 0 { throw StoreError.io(stage: #function, errno: errno) }; if n == 0 { break }; bytes.append(buffer, count: n); if bytes.count > maxBytes { throw StoreError.tooLarge } }
        try verifyDirectoryMapping(dir)
        return bytes
    }

    func write(_ data: Data, name: String) throws {
        try validateName(name)
        guard data.count <= maxBytes else { throw StoreError.tooLarge }
        let dir = try openDirectory(createChild: true); defer { close(dir) }
        afterDirectoryFDOpened?()
        try verifyDirectoryMapping(dir)
        let temp = ".tmp-" + UUID().uuidString
        var fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io(stage: #function, errno: errno) }
        var done = 0
        do {
            try validateFile(fd)
            try data.withUnsafeBytes { raw in while done < raw.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done); if n <= 0 { throw StoreError.io(stage: #function, errno: errno) }; done += n } }
            guard fsync(fd) == 0 else { throw StoreError.io(stage: #function, errno: errno) }; close(fd); fd = -1
            try verifyDirectoryMapping(dir)
            guard renameat(dir, temp, dir, name) == 0 else { throw StoreError.io(stage: #function, errno: errno) }
            // Darwin filesystems may reject directory fsync with EINVAL; file contents were synced first.
            if fsync(dir) != 0 && errno != EINVAL { throw StoreError.io(stage: #function, errno: errno) }
            try verifyDirectoryMapping(dir)
        } catch { if fd >= 0 { close(fd) }; _ = unlinkat(dir, temp, 0); throw error }
    }

    func remove(_ name: String) throws {
        try validateName(name)
        let dir: Int32
        do { dir = try openDirectory(createChild: false) } catch StoreError.io(let stage, let code) where stage == "child" && code == ENOENT { return }
        defer { close(dir) }
        afterDirectoryFDOpened?()
        try verifyDirectoryMapping(dir)
        if unlinkat(dir, name, 0) != 0 && errno != ENOENT { throw StoreError.io(stage: #function, errno: errno) }
        if fsync(dir) != 0 && errno != EINVAL { throw StoreError.io(stage: #function, errno: errno) }
        try verifyDirectoryMapping(dir)
    }

    /// Held FDs prevent redirection into an external path; this comparison also
    /// refuses success if the caller's inbox path no longer names that directory.
    private func verifyDirectoryMapping(_ expected: Int32) throws {
        let current = try openDirectory(createChild: false, updatePermissions: false)
        defer { close(current) }
        var originalStat = stat()
        var currentStat = stat()
        guard fstat(expected, &originalStat) == 0,
              fstat(current, &currentStat) == 0,
              originalStat.st_dev == currentStat.st_dev,
              originalStat.st_ino == currentStat.st_ino else {
            throw StoreError.unsafeFile
        }
    }

    private func openDirectory(createChild: Bool, updatePermissions: Bool = true) throws -> Int32 {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else { throw StoreError.invalidPath }
        let comps = rootURL.pathComponents.filter { $0 != "/" }
        guard !comps.isEmpty, !comps.contains(".."), !comps.contains(".") else { throw StoreError.invalidPath }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.io(stage: #function, errno: errno) }
        for (i, component) in comps.enumerated() {
            var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT && createChild && i == comps.count - 1 {
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { close(fd); throw StoreError.io(stage: #function, errno: errno) }
                next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd); guard next >= 0 else { throw StoreError.io(stage: "directoryComponent", errno: errno) }; fd = next
            var s = stat(); guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { close(fd); throw StoreError.unsafeFile }
        }
        var rootStat = stat()
        guard fstat(fd, &rootStat) == 0, rootStat.st_uid == getuid() else { close(fd); throw StoreError.unsafeFile }
        guard !updatePermissions || fchmod(fd, 0o700) == 0 else { close(fd); throw StoreError.io(stage: #function, errno: errno) }
        // The queue child can be created only below the owned app root.
        let child = "push-psk-events"
        var childFD = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if childFD < 0 && errno == ENOENT && createChild { guard mkdirat(fd, child, 0o700) == 0 || errno == EEXIST else { close(fd); throw StoreError.io(stage: #function, errno: errno) }; childFD = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        close(fd); guard childFD >= 0 else { throw StoreError.io(stage: "child", errno: errno) }
        var s = stat(); guard fstat(childFD, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid() else { close(childFD); throw StoreError.unsafeFile }
        guard !updatePermissions || fchmod(childFD, 0o700) == 0 else { close(childFD); throw StoreError.io(stage: #function, errno: errno) }
        return childFD
    }

    private func validateFile(_ fd: Int32) throws { var s = stat(); guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, (s.st_mode & 0o077) == 0, s.st_size <= off_t(maxBytes) else { throw StoreError.unsafeFile } }
}
