import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GET retries share one deadline. Writes remain single-attempt even when an
/// idempotency key is present: mutation replay is a separate server contract.
struct VEXAPITransport: Sendable {
    var load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }

    func data(for request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw URLError(.timedOut) }
        let deadline = now() + timeout
        // URLRequest's timeout measures inactivity. A server that keeps sending
        // bytes must not extend the total API operation beyond this deadline.
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await attempts(request, deadline: deadline) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            return (result.data, result.response)
        }
    }

    private func attempts(_ request: URLRequest, deadline: TimeInterval) async throws -> Response {
        let limit = request.httpMethod?.uppercased() == "GET" || request.httpMethod == nil ? 3 : 1
        for attempt in 1...limit {
            try Task.checkCancellation()
            let remaining = deadline - now()
            guard remaining > 0 else { throw URLError(.timedOut) }
            var current = request
            current.timeoutInterval = remaining
            let result: Response
            do {
                let (data, response) = try await load(current)
                try Task.checkCancellation()
                guard now() < deadline else { throw URLError(.timedOut) }
                result = Response(data: data, response: response)
            } catch {
                try Task.checkCancellation()
                let delay = 0.6 * Double(attempt)
                guard attempt < limit, Self.isRetryable(error), delay < deadline - now() else { throw error }
                try await sleep(delay)
                continue
            }
            guard attempt < limit, let http = result.response as? HTTPURLResponse,
                  [429, 502, 503, 504].contains(http.statusCode) else { return result }
            let delay = max(0.6 * Double(attempt), Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 0)
            // Preserve the actual HTTP status if the requested server cooldown
            // cannot fit. Do not turn throttling into a fabricated timeout.
            guard delay < deadline - now() else { return result }
            try await sleep(delay)
        }
        throw URLError(.timedOut)
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let seconds = TimeInterval(value), seconds.isFinite else { return nil }
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
    }

    private struct Response: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }
}
