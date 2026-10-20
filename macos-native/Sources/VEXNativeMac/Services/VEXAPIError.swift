import Foundation

enum VEXAPIError: LocalizedError {
    case invalidResponse
    case invalidAPIBaseURL
    case technicalWorks
    case requestTimeout
    case http(status: Int, message: String, code: String? = nil, retryAfter: TimeInterval? = nil)

    static let technicalWorksMessage = "Идут технические работы. Мы уже переключаем сервисы, попробуйте через пару минут."

    static func payload(_ data: Data) -> (code: String?, message: String) {
        let fallback = "HTTP request failed"
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let structured = ["{", "[", "\"", "<"].contains { text.hasPrefix($0) }
            return (nil, !structured && !text.isEmpty ? text : fallback)
        }
        if let text = decoded as? String { return (nil, stringValue(text) ?? fallback) }
        guard let fields = decoded as? [String: Any] else { return (nil, fallback) }
        return (stringValue(fields["code"]), stringValue(fields["message"]) ?? stringValue(fields["error"]) ?? fallback)
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isUnauthorized: Bool {
        if case .http(let status, _, let code, _) = self {
            return status == 401 && code != "maintenance"
        }
        return false
    }

    var isRateLimited: Bool {
        if case .http(let status, _, _, _) = self {
            return status == 429
        }
        return false
    }

    var code: String? {
        switch self {
        case .invalidAPIBaseURL: return "invalid_api_base_url"
        case .requestTimeout: return "request_timeout"
        case .http(_, _, let code, _): return code
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Некорректный ответ API."
        case .invalidAPIBaseURL:
            return "Неверно настроен адрес API."
        case .technicalWorks, .requestTimeout:
            return Self.technicalWorksMessage
        case .http(let status, let message, let code, _):
            if Self.isMaintenanceStatus(status) || code == "maintenance" {
                return Self.technicalWorksMessage
            }
            return "HTTP \(status): \(message)"
        }
    }

    static func isMaintenanceStatus(_ status: Int) -> Bool {
        status == 502 || status == 503 || status == 504
    }

    static func isServerUnavailable(_ error: Error) -> Bool {
        if let apiError = error as? VEXAPIError {
            switch apiError {
            case .technicalWorks, .requestTimeout:
                return true
            case .http(let status, _, let code, _):
                return isMaintenanceStatus(status) || code == "maintenance"
            case .invalidResponse, .invalidAPIBaseURL:
                return false
            }
        }
        if let urlError = error as? URLError {
            return VEXAPITransport.isRetryable(urlError)
        }
        let message = error.localizedDescription.localizedLowercase
        return message.contains("идут технические работы")
            || message.contains("could not connect")
            || message.contains("connection refused")
            || message.contains("connection reset")
            || message.contains("network connection was lost")
            || message.contains("timed out")
    }
}

extension Error {
    var isUnauthorizedAPIError: Bool {
        (self as? VEXAPIError)?.isUnauthorized == true
    }

    var isRateLimitedAPIError: Bool {
        (self as? VEXAPIError)?.isRateLimited == true
    }

    var isTimeout: Bool {
        // Keep normalized API deadlines separate from this legacy transport
        // flag: profile timeout fallback is not qualified for replaced keys.
        if let urlError = self as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    var isProfileProvisioningUnavailable: Bool {
        guard case .http(let status, let message, let code, _) = self as? VEXAPIError,
              code != "maintenance" else {
            return false
        }
        let normalized = message.localizedLowercase
        return status == 400 && (
            normalized.contains("add-peer")
                || normalized.contains("node-agent")
                || normalized.contains("connection refused")
                || normalized.contains("connect: connection refused")
        )
    }
}
