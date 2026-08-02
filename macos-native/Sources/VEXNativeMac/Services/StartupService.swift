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
