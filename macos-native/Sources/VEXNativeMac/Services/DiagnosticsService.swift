import Foundation

actor DiagnosticsService {
    private let api: VEXAPIClient
    private let fileManager: FileManager
    private let maxQueuedReports = 10
    private var rateLimitedUntil: Date?
    private let networkMonitor = ClientNetworkMonitor()
    private var capturedNetwork: CapturedClientNetwork?
    private var captureGeneration = 0

    init(api: VEXAPIClient = VEXAPIClient(), fileManager: FileManager = .default) {
        self.api = api
        self.fileManager = fileManager
    }

    func upload(accessToken: String, report: ClientDiagnosticsReport) async {
        var report = report
        let network = networkMonitor.snapshot()
        report.networkClass = network.networkClass
        if let capturedNetwork, capturedNetwork.matches(network, device: report.deviceId, token: accessToken, now: Date()) {
            report.networkObservationId = capturedNetwork.id
            report.networkGeneration = network.generation
        }
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

    func captureNetwork(accessToken: String, deviceId: String, vpnState: String) async {
        captureGeneration += 1
        let attempt = captureGeneration
        capturedNetwork = nil
        guard vpnState == "disconnected", !isRateLimited else { return }
        let network = networkMonitor.snapshot()
        guard network.networkClass != "unknown", !network.generation.isEmpty else { return }
        var seed = ClientDiagnosticsReport(deviceId: deviceId, reason: "network_before_connect", status: "info", vpnState: "disconnected", rxBytes: 0, txBytes: 0, samples: [:])
        seed.networkClass = network.networkClass
        seed.networkGeneration = network.generation
        let started = Date()
        // Never queue an observation seed or retry it through the VPN exit.
        guard let id = try? await api.captureClientNetwork(accessToken: accessToken, report: seed),
            attempt == captureGeneration, Date().timeIntervalSince(started) < 1.5,
            networkMonitor.snapshot() == network else { return }
        capturedNetwork = CapturedClientNetwork(snapshot: network, id: id, deviceId: deviceId, accessToken: accessToken, capturedAt: started)
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
