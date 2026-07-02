import Foundation

struct AppSensitiveFileStore {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directoryURL = base
                .appendingPathComponent("VEX Native", isDirectory: true)
                .appendingPathComponent("Sensitive Store", isDirectory: true)
        }
    }

    func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw VEXKeychainError.invalidValue
        }
        try setData(data, for: key)
    }

    func setData(_ data: Data, for key: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(_ key: String) throws {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for key: String) -> URL {
        directoryURL
            .appendingPathComponent(safeFileName(key), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func safeFileName(_ key: String) -> String {
        key.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
    }
}
