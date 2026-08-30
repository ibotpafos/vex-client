import Foundation

struct CustomerRealtimeEvent: Equatable {
    let type: String
    let id: String
    let data: String
}

struct CustomerSSEParser {
    private(set) var remainder = ""
    private static let maximumRemainderLength = 64 * 1024
    private static let supportedTypes: Set<String> = [
        "customer.change",
        "customer.resync",
        "customer.session.revoked",
        "customer.heartbeat",
    ]

    mutating func append(_ chunk: String) -> [CustomerRealtimeEvent] {
        let buffered = (remainder + chunk)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let boundary = buffered.range(of: "\n\n", options: .backwards) else {
            remainder = String(buffered.suffix(Self.maximumRemainderLength))
            return []
        }

        let complete = String(buffered[..<boundary.lowerBound])
        remainder = String(buffered[boundary.upperBound...].suffix(Self.maximumRemainderLength))
        return complete.components(separatedBy: "\n\n").compactMap(Self.parseFrame)
    }

    private static func parseFrame(_ frame: String) -> CustomerRealtimeEvent? {
        var type = "message"
        var id = ""
        var data: [String] = []
        for line in frame.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                type = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("id:") {
                id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data.append(String(line.dropFirst(5).drop(while: { $0 == " " })))
            }
        }
        guard supportedTypes.contains(type), !data.isEmpty else { return nil }
        return CustomerRealtimeEvent(type: type, id: id, data: data.joined(separator: "\n"))
    }
}

struct CustomerRealtimeMetadata: Equatable {
    static let supportedDomains: Set<String> = [
        "account",
        "entitlement",
        "billing",
        "devices",
        "provisioning",
        "connection",
        "family",
        "support",
        "releases",
        "status",
    ]

    let domains: [String]
    let reason: String

    static func parse(type: String, data: String) -> CustomerRealtimeMetadata? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
            let payload = raw as? [String: Any]
        else { return nil }

        switch type {
        case "customer.heartbeat":
            return CustomerRealtimeMetadata(domains: [], reason: "")
        case "customer.session.revoked":
            return CustomerRealtimeMetadata(
                domains: [],
                reason: payload["reason"] as? String ?? "session_invalid"
            )
        case "customer.change":
            guard
                let domain = payload["domain"] as? String,
                supportedDomains.contains(domain),
                let version = payload["version"] as? NSNumber,
                version.doubleValue > 0
            else { return nil }
            return CustomerRealtimeMetadata(domains: [domain], reason: "")
        case "customer.resync":
            guard let versions = payload["versions"] as? [[String: Any]] else { return nil }
            let domains = versions.compactMap { version -> String? in
                guard
                    let domain = version["domain"] as? String,
                    supportedDomains.contains(domain)
                else { return nil }
                return domain
            }
            return CustomerRealtimeMetadata(
                domains: Array(Set(domains)).sorted(),
                reason: payload["reason"] as? String ?? "resync"
            )
        default:
            return nil
        }
    }
}

@MainActor
final class CustomerRealtimeService {
    typealias EventHandler = @MainActor (CustomerRealtimeEvent, CustomerRealtimeMetadata) async -> Void
    typealias StatusHandler = @MainActor (Bool) -> Void

    private let baseURL: URL
    private let session: URLSession
    private let onEvent: EventHandler
    private let onStatus: StatusHandler
    private var streamTask: Task<Void, Never>?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        onStatus: @escaping StatusHandler = { _ in },
        onEvent: @escaping EventHandler
    ) {
        self.baseURL = baseURL
        self.session = session
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    func start(accessToken: String) {
        stop()
        guard !accessToken.isEmpty else { return }
        streamTask = Task { [weak self] in
            await self?.run(accessToken: accessToken)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        onStatus(false)
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(min(max(0, attempt), 5))))
    }

    private func run(accessToken: String) async {
        var attempt = 0
        var lastEventID = ""
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/events"))
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 90
                if !lastEventID.isEmpty {
                    request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
                }

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                onStatus(true)
                attempt = 0
                var parser = CustomerSSEParser()
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    for event in parser.append(line + "\n") {
                        if !event.id.isEmpty { lastEventID = event.id }
                        guard let metadata = CustomerRealtimeMetadata.parse(type: event.type, data: event.data) else {
                            continue
                        }
                        await onEvent(event, metadata)
                    }
                }
                _ = parser.append("\n")
                onStatus(false)
            } catch is CancellationError {
                return
            } catch {
                onStatus(false)
            }
            guard !Task.isCancelled else { return }
            let delay = Self.reconnectDelay(attempt: attempt)
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
