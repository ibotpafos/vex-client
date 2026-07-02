import AppKit
import CryptoKit
import Foundation

struct StartupService {
    private let fileManager = FileManager.default
    private let label = "app.vex.vpn.native.launch"

    func isEnabled() -> Bool {
        fileManager.fileExists(atPath: launchAgentURL().path)
    }

    func setEnabled(_ enabled: Bool) throws {
        let url = launchAgentURL()
        if enabled {
            guard let bundlePath = Bundle.main.bundleURL.path.removingPercentEncoding else {
                throw StartupServiceError.bundlePathUnavailable
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>\(label)</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>\(bundlePath)</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
            </dict>
            </plist>
            """
            try plist.write(to: url, atomically: true, encoding: .utf8)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func launchAgentURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}

enum StartupServiceError: LocalizedError {
    case bundlePathUnavailable

    var errorDescription: String? {
        "Не удалось определить путь приложения для автозапуска."
    }
}

struct UpdateService {
    private let fileManager = FileManager.default

    func openDownload(_ update: AppUpdateCheckResult?) {
        guard let value = update?.downloadUrl,
              let url = URL(string: value),
              !value.isEmpty else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func download(_ update: AppUpdateCheckResult?) async throws -> URL {
        guard let value = update?.downloadUrl,
              let url = URL(string: value),
              !value.isEmpty else {
            throw UpdateServiceError.missingDownloadURL
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.downloadFailed
        }
        if let checksum = update?.checksumSha256?.trimmingCharacters(in: .whitespacesAndNewlines),
           !checksum.isEmpty {
            try verifySHA256(fileURL: temporaryURL, expected: checksum)
        }

        let destination = downloadsURL(for: url, update: update)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func reveal(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func launchInstaller(_ fileURL: URL) {
        NSWorkspace.shared.open(fileURL)
    }

    private func downloadsURL(for url: URL, update: AppUpdateCheckResult?) -> URL {
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let ext = url.pathExtension.isEmpty ? "dmg" : url.pathExtension
        let version = update?.latestVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = "VEX-\((version?.isEmpty == false ? version! : VEXAppInfo.version)).\(ext)"
        return downloads.appendingPathComponent(fileName)
    }

    private func verifySHA256(fileURL: URL, expected: String) throws {
        let data = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw UpdateServiceError.checksumMismatch
        }
    }
}

enum UpdateServiceError: LocalizedError {
    case missingDownloadURL
    case downloadFailed
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .missingDownloadURL:
            return "Ссылка на обновление отсутствует."
        case .downloadFailed:
            return "Не удалось скачать обновление."
        case .checksumMismatch:
            return "Checksum обновления не совпал."
        }
    }
}
