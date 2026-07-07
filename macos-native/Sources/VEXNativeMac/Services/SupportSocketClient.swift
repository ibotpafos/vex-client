import Foundation

@MainActor
final class SupportSocketClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var lastError: String?

    private let api: VEXAPIClient
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var accessToken: String?
    private var onSnapshot: (([SupportTicket]) -> Void)?
    private var onTicket: ((SupportTicket) -> Void)?

    init(api: VEXAPIClient = VEXAPIClient()) {
        self.api = api
    }

    func connect(accessToken: String, onSnapshot: @escaping ([SupportTicket]) -> Void, onTicket: @escaping (SupportTicket) -> Void) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isConnected = false
        isReconnecting = false
        self.accessToken = accessToken
        self.onSnapshot = onSnapshot
        self.onTicket = onTicket
        Task { await open() }
    }

    func close() {
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        isReconnecting = false
    }

    func send(body: String, subject: String? = nil, ticketId: String? = nil) -> Bool {
        guard let task, isConnected else { return false }
        var payload: [String: String] = [
            "type": "support.message",
            "body": body,
        ]
        if let subject, !subject.isEmpty {
            payload["subject"] = subject
        }
        if let ticketId, !ticketId.isEmpty {
            payload["ticket_id"] = ticketId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        task.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
        return true
    }

    private func open() async {
        guard let accessToken else { return }
        do {
            let url = try await api.supportWebSocketURL(accessToken: accessToken)
            let task = URLSession.shared.webSocketTask(with: url)
            self.task = task
            task.resume()
            validateOpen(task)
            receiveLoop(task)
        } catch {
            lastError = error.localizedDescription
            scheduleReconnect()
        }
    }

    private func validateOpen(_ task: URLSessionWebSocketTask) {
        task.sendPing { [weak self, weak task] error in
            Task { @MainActor in
                guard let self, let task, self.task === task else { return }
                if let error {
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    self.scheduleReconnect()
                    return
                }
                self.isConnected = true
                self.isReconnecting = false
                self.lastError = nil
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    self.isConnected = true
                    self.isReconnecting = false
                    self.lastError = nil
                    self.dispatch(message)
                    self.receiveLoop(task)
                case .failure(let error):
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func dispatch(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = text.data(using: .utf8)
        @unknown default:
            data = nil
        }
        guard let data else {
            lastError = "Получили некорректное событие чата поддержки."
            return
        }
        do {
            let envelope = try JSONDecoder().decode(SupportSocketEnvelope.self, from: data)
            switch envelope.type {
            case "support.snapshot":
                onSnapshot?(envelope.tickets ?? [])
            case "support.ticket":
                if let ticket = envelope.ticket {
                    onTicket?(ticket)
                }
            case "support.error":
                lastError = envelope.message
            default:
                break
            }
        } catch {
            lastError = "Получили некорректное событие чата поддержки."
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self?.reconnectTask = nil
            }
            await self?.open()
        }
    }
}
