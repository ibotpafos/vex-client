import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

@MainActor
final class PKCEAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let apiBaseURL: URL
    private let defaults: UserDefaults
    private let identityStore: VEXDeviceIdentityStore
    private let verifierKey = "vex.auth.pkce.verifier"
    private let stateKey = "vex.auth.pkce.state"
    private var webAuthSession: ASWebAuthenticationSession?

    init(apiBaseURL: URL = URL(string: ProcessInfo.processInfo.environment["VEX_API_BASE_URL"] ?? "https://vexguard.app")!,
         defaults: UserDefaults = .standard,
         identityStore: VEXDeviceIdentityStore = VEXDeviceIdentityStore()) {
        self.apiBaseURL = apiBaseURL
        self.defaults = defaults
        self.identityStore = identityStore
        super.init()
    }

    func startWebAuth(mode: WebAuthMode = .login) async throws -> URL {
        let url = try makeWebAuthURL(mode: mode)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vexguard") { [weak self] callbackURL, error in
                    Task { @MainActor in
                        self?.webAuthSession = nil
                        if let callbackURL {
                            continuation.resume(returning: callbackURL)
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: PKCEAuthError.invalidCallback)
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                webAuthSession = session
                guard session.start() else {
                    webAuthSession = nil
                    continuation.resume(throwing: PKCEAuthError.webAuthSessionFailed)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWebAuth()
            }
        }
    }

    func cancelWebAuth() {
        webAuthSession?.cancel()
        webAuthSession = nil
        clearVerifier()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }

    private func makeWebAuthURL(mode: WebAuthMode) throws -> URL {
        let verifier = randomString(length: 64)
        let state = randomString(length: 16)
        defaults.set(verifier, forKey: verifierKey)
        defaults.set(state, forKey: stateKey)

        var components = URLComponents(url: apiBaseURL.appendingPathComponent("auth/app"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: "vex_app"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device_id", value: identityStore.getOrCreateDeviceId()),
            URLQueryItem(name: "device_name", value: "Mac"),
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        guard let url = components?.url else {
            throw VEXAPIError.invalidResponse
        }
        return url
    }

    func consumeVerifier(for callbackURL: URL) throws -> String {
        guard callbackURL.scheme == "vexguard" || callbackURL.scheme == "vex",
              callbackURL.host == "auth",
              callbackURL.path.hasPrefix("/callback") else {
            throw PKCEAuthError.unsupportedURL
        }
        guard let returnedState = uniqueQueryValue("state", in: callbackURL), !returnedState.isEmpty else {
            throw PKCEAuthError.invalidCallback
        }
        guard let storedState = defaults.string(forKey: stateKey), storedState == returnedState else {
            throw PKCEAuthError.stateMismatch
        }
        guard let verifier = defaults.string(forKey: verifierKey), !verifier.isEmpty else {
            throw PKCEAuthError.missingVerifier
        }
        return verifier
    }

    func clearVerifier() {
        defaults.removeObject(forKey: verifierKey)
        defaults.removeObject(forKey: stateKey)
    }

    func code(from callbackURL: URL) throws -> String {
        guard let code = uniqueQueryValue("code", in: callbackURL), !code.isEmpty else {
            throw PKCEAuthError.invalidCallback
        }
        return code
    }

    private func uniqueQueryValue(_ name: String, in url: URL) -> String? {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == name }
            .compactMap(\.value) ?? []
        return values.count == 1 ? values[0] : nil
    }

    private func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

enum WebAuthMode: String {
    case login
    case register
}

enum PKCEAuthError: LocalizedError {
    case unsupportedURL
    case invalidCallback
    case stateMismatch
    case missingVerifier
    case webAuthSessionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Неподдерживаемый auth callback."
        case .invalidCallback:
            return "Неверные параметры авторизации от сервера."
        case .stateMismatch:
            return "Несовпадение параметров безопасности."
        case .missingVerifier:
            return "Отсутствует PKCE verifier."
        case .webAuthSessionFailed:
            return "Не удалось открыть безопасный вход через сайт."
        }
    }
}
