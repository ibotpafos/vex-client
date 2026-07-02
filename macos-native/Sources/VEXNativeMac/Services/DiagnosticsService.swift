import Foundation

actor DiagnosticsService {
    private let api: VEXAPIClient
    private let fileManager: FileManager
    private let maxQueuedReports = 10
    private var rateLimitedUntil: Date?

    init(api: VEXAPIClient = VEXAPIClient(), fileManager: FileManager = .default) {
        self.api = api
        self.fileManager = fileManager
    }

    func upload(accessToken: String, report: ClientDiagnosticsReport) async {
        guard !isRateLimited else {
            saveQueue(Array((loadQueue() + [report]).suffix(maxQueuedReports)))
            return
        }

        var remaining = [ClientDiagnosticsReport]()

        for queued in loadQueue() {
            do {
                try await api.submitClientDiagnostics(accessToken: accessToken, report: queued)
            } catch {
                if error.isRateLimitedAPIError {
                    rateLimitedUntil = Date().addingTimeInterval(60)
                    saveQueue(Array((remaining + [queued, report]).suffix(maxQueuedReports)))
                    return
                }
                remaining.append(queued)
            }
        }

        do {
            try await api.submitClientDiagnostics(accessToken: accessToken, report: report)
            saveQueue(remaining)
        } catch {
            if error.isRateLimitedAPIError {
                rateLimitedUntil = Date().addingTimeInterval(60)
            }
            saveQueue(Array((remaining + [report]).suffix(maxQueuedReports)))
        }
    }

    func flush(accessToken: String) async {
        guard !isRateLimited else { return }
        var remaining = [ClientDiagnosticsReport]()
        for queued in loadQueue() {
            do {
                try await api.submitClientDiagnostics(accessToken: accessToken, report: queued)
            } catch {
                if error.isRateLimitedAPIError {
                    rateLimitedUntil = Date().addingTimeInterval(60)
                    remaining.append(queued)
                    break
                }
                remaining.append(queued)
            }
        }
        saveQueue(Array(remaining.suffix(maxQueuedReports)))
    }

    private var isRateLimited: Bool {
        guard let rateLimitedUntil else { return false }
        if rateLimitedUntil > Date() {
            return true
        }
        self.rateLimitedUntil = nil
        return false
    }

    private func loadQueue() -> [ClientDiagnosticsReport] {
        guard let data = try? Data(contentsOf: queueURL()) else { return [] }
        return ((try? JSONDecoder().decode([ClientDiagnosticsReport].self, from: data)) ?? []).suffix(maxQueuedReports)
    }

    private func saveQueue(_ reports: [ClientDiagnosticsReport]) {
        let url = queueURL()
        if reports.isEmpty {
            try? fileManager.removeItem(at: url)
            return
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(reports.suffix(maxQueuedReports))) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func queueURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("VEX Native", isDirectory: true)
            .appendingPathComponent("client-diagnostics-queue.json")
    }
}
