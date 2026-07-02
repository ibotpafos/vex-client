import SwiftUI

struct SupportPanel: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @State private var subject = ""
    @State private var chatItems: [SupportChatItem] = []
    @State private var expandedMessageIDs: Set<String> = []
    @State private var expandedDiagnosticGroupIDs: Set<String> = []

    private let supportTopics = [
        "Не подключается",
        "Оплата",
        "Конфиг",
        "Скорость",
    ]

    var body: some View {
        VStack(spacing: 12) {
            supportHeader
            chatShell
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            rebuildChatItems()
        }
        .onChange(of: appState.supportTickets) { _, _ in
            rebuildChatItems()
        }
    }

    private var supportHeader: some View {
        GlassPanel(cornerRadius: 20) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.vexCyan)
                    Text("V")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.vexBackground)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Поддержка VEX")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color.vexText)
                        .lineLimit(1)
                    Text(connectionStatusText)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(connectionStatusColor)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task { await appState.refreshSupport() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.vexGlass)

                Button {
                    Task { await appState.sendSupportDiagnostics(using: helper) }
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(.vexGlass)
                .disabled(appState.accessToken == nil)
            }
            .frame(minHeight: 48)
        }
    }

    private var chatShell: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 7) {
                        dayPill
                        chatBody
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatItems.map(\.id)) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            VStack(spacing: 10) {
                if showTopics {
                    topicRow
                }
                composerRow
                if let reconnectHint {
                    statusHint(text: reconnectHint)
                }
            }
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var chatBody: some View {
        if appState.accessToken == nil {
            emptyHint(
                title: "Войдите в аккаунт",
                subtitle: "После входа здесь появится история переписки с поддержкой."
            )
        } else if chatItems.isEmpty {
            emptyHint(
                title: "Чат пока пуст",
                subtitle: "Опишите устройство, ошибку и когда проблема началась. Повторные сообщения попадут в текущее обращение."
            )
        } else {
            ForEach(chatItems) { item in
                switch item {
                case .message(let message):
                    let bubbleID = SupportChatBuilder.messageKey(message)
                    SupportMessageBubble(
                        item: item,
                        isExpanded: expandedMessageIDs.contains(bubbleID),
                        onExpand: {
                            expandedMessageIDs.insert(bubbleID)
                        }
                    )
                    .id(item.id)
                case .diagnosticGroup:
                    SupportMessageBubble(
                        item: item,
                        isExpanded: expandedDiagnosticGroupIDs.contains(item.id),
                        onExpand: {
                            if expandedDiagnosticGroupIDs.contains(item.id) {
                                expandedDiagnosticGroupIDs.remove(item.id)
                            } else {
                                expandedDiagnosticGroupIDs.insert(item.id)
                            }
                        }
                    )
                    .id(item.id)
                }
            }

            if SupportChatBuilder.needsReply(appState.supportTickets) {
                supportNotice(
                    "Спасибо, сообщение получено. Ответ появится здесь, как только специалист возьмет обращение в работу."
                )
            }
        }
    }

    private var composerRow: some View {
        SupportComposer(
            isEnabled: appState.accessToken != nil,
            selectedSubject: subject,
            onSend: { body, selectedSubject in
                Task {
                    await appState.sendSupportMessage(body, subject: selectedSubject)
                    subject = ""
                }
            }
        )
    }

    private var topicRow: some View {
        HStack(spacing: 8) {
            ForEach(supportTopics, id: \.self) { topic in
                let isSelected = topic == subject
                Button {
                    subject = isSelected ? "" : topic
                } label: {
                    Text(topic)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(isSelected ? Color.vexBackground : Color.vexSecondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.vexCyan : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var dayPill: some View {
        Text("Сегодня")
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(Color.vexMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.18))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
    }

    private func emptyHint(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color.vexText)
            Text(subtitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vexSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func supportNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.vexSecondaryText)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 470, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statusHint(text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.vexMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await appState.refreshSupport() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.vexCyan)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.vexCyan.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = chatItems.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private var showTopics: Bool {
        chatItems.isEmpty
    }

    private var connectionStatusText: String {
        if appState.accessToken == nil {
            return "нужен вход"
        }
        if appState.supportSocketConnected {
            return "в сети"
        }
        if appState.supportSocketReconnecting {
            return "обновляем чат..."
        }
        return "подключаемся..."
    }

    private var connectionStatusColor: Color {
        if appState.supportSocketConnected {
            return Color.vexCyan
        }
        if appState.accessToken == nil {
            return Color.vexSecondaryText
        }
        return Color.vexMuted
    }

    private var reconnectHint: String? {
        guard appState.supportSocketReconnecting else { return nil }
        return "Live-обновления временно восстанавливаются. Отправка работает, история обновится автоматически."
    }

    private func rebuildChatItems() {
        chatItems = SupportChatBuilder.items(from: appState.supportTickets)
    }
}

private struct SupportComposer: View {
    let isEnabled: Bool
    let selectedSubject: String
    let onSend: (String, String?) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Напишите сообщение",
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.vexText)
            .lineLimit(1...5)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.vexInput.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isFocused ? Color.vexCyan.opacity(0.46) : Color.vexBorder.opacity(0.24), lineWidth: 1)
                    )
            )

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(canSend ? Color.vexBackground : Color.vexMuted)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSend ? Color.vexCyan : Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        isEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !body.isEmpty else { return }
        let subject = selectedSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        onSend(body, subject.isEmpty ? SupportChatBuilder.buildSubject(body) : subject)
        isFocused = true
    }
}

private struct SupportMessageBubble: View {
    let item: SupportChatItem
    let isExpanded: Bool
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: bubbleAlignment, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !isUserMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Color.vexText)
                        Spacer(minLength: 8)
                        Text(item.timeText)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color.vexMuted)
                    }
                }

                Text(item.displayBody(expanded: isExpanded))
                    .font(.system(size: item.usesCompactBody ? 12 : 14, weight: .medium))
                    .foregroundStyle(item.bodyColor)
                    .lineSpacing(item.usesCompactBody ? 2 : 1)
                    .textSelection(.enabled)

                if isUserMessage {
                    Text(item.timeText)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.vexText.opacity(0.66))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if item.canExpand {
                    Button {
                        onExpand()
                    } label: {
                        Text(item.expandButtonTitle(expanded: isExpanded))
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.vexCyanLight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(bubbleBorder, lineWidth: 1)
            )
            .clipShape(RoundedBubbleShape(isUser: isUserMessage))
            .frame(maxWidth: item.isDiagnostic ? 360 : 318, alignment: isUserMessage ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    private var isUserMessage: Bool {
        item.sender.lowercased() == "user"
    }

    private var bubbleAlignment: HorizontalAlignment {
        isUserMessage ? .trailing : .leading
    }

    private var bubbleBackground: some ShapeStyle {
        if isUserMessage {
            return AnyShapeStyle(Color.vexCyan.opacity(0.28))
        }
        if item.isDiagnostic {
            return AnyShapeStyle(Color.black.opacity(0.18))
        }
        return AnyShapeStyle(Color.black.opacity(0.30))
    }

    private var bubbleBorder: Color {
        if isUserMessage {
            return Color.vexCyan.opacity(0.34)
        }
        if item.isDiagnostic {
            return Color.white.opacity(0.10)
        }
        return Color.white.opacity(0.12)
    }
}

private struct RoundedBubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 16
        let tailRadius: CGFloat = 5

        let topLeft = radius
        let topRight = radius
        let bottomLeft = isUser ? radius : tailRadius
        let bottomRight = isUser ? tailRadius : radius

        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private enum SupportChatItem: Identifiable {
    case message(SupportMessage)
    case diagnosticGroup(id: String, messages: [SupportMessage])

    var id: String {
        switch self {
        case .message(let message):
            return SupportChatBuilder.messageKey(message)
        case .diagnosticGroup(let id, _):
            return id
        }
    }

    var sender: String {
        switch self {
        case .message(let message):
            return message.sender
        case .diagnosticGroup(_, let messages):
            return messages.last?.sender ?? "user"
        }
    }

    var title: String {
        sender.lowercased() == "admin" ? "Поддержка" : "Вы"
    }

    var timeText: String {
        let value: String
        switch self {
        case .message(let message):
            value = message.createdAt
        case .diagnosticGroup(_, let messages):
            value = messages.last?.createdAt ?? ""
        }
        return DateFormatter.vexSupportTime(value) ?? ""
    }

    var canExpand: Bool {
        switch self {
        case .message(let message):
            return SupportChatBuilder.shouldCollapse(message.body)
        case .diagnosticGroup(_, let messages):
            return messages.count > 1 || messages.contains { SupportChatBuilder.shouldCollapse($0.body) }
        }
    }

    var isDiagnostic: Bool {
        switch self {
        case .message(let message):
            return SupportChatBuilder.isDiagnostic(message.body)
        case .diagnosticGroup:
            return true
        }
    }

    var usesCompactBody: Bool {
        isDiagnostic
    }

    var bodyColor: Color {
        if sender.lowercased() == "user" {
            return Color.vexText
        }
        return isDiagnostic ? Color.vexText.opacity(0.82) : Color.vexSubtext
    }

    func displayBody(expanded: Bool) -> String {
        switch self {
        case .message(let message):
            return SupportChatBuilder.displayBody(message.body, expanded: expanded)
        case .diagnosticGroup(_, let messages):
            return SupportChatBuilder.diagnosticGroupBody(messages, expanded: expanded)
        }
    }

    func expandButtonTitle(expanded: Bool) -> String {
        switch self {
        case .message:
            return expanded ? "Скрыть" : "Показать полностью"
        case .diagnosticGroup:
            return expanded ? "Скрыть" : "Показать отчеты"
        }
    }
}

private enum SupportChatBuilder {
    private static let duplicateWindow: TimeInterval = 10
    private static let collapsedLength = 360
    private static let collapsedLines = 8

    static func items(from tickets: [SupportTicket]) -> [SupportChatItem] {
        let messages = chatMessages(from: tickets)
        var items: [SupportChatItem] = []
        var diagnostics: [SupportMessage] = []

        func flushDiagnostics() {
            guard !diagnostics.isEmpty else { return }
            if diagnostics.count == 1, let message = diagnostics.first {
                items.append(.message(message))
            } else {
                items.append(.diagnosticGroup(id: diagnosticGroupID(diagnostics), messages: diagnostics))
            }
            diagnostics = []
        }

        for message in messages {
            if isDiagnostic(message.body) {
                diagnostics.append(message)
            } else {
                flushDiagnostics()
                items.append(.message(message))
            }
        }
        flushDiagnostics()
        return items
    }

    static func needsReply(_ tickets: [SupportTicket]) -> Bool {
        guard let active = tickets.first(where: { !["closed", "resolved"].contains($0.status.lowercased()) }) else {
            return false
        }
        return legacyMessages(for: active).last?.sender.lowercased() == "user"
    }

    static func shouldCollapse(_ body: String) -> Bool {
        body.count > collapsedLength || body.components(separatedBy: .newlines).count > collapsedLines
    }

    static func displayBody(_ body: String, expanded: Bool) -> String {
        guard !expanded, shouldCollapse(body) else { return body }
        if isDiagnostic(body) {
            return diagnosticPreview(body)
        }
        let lines = body.components(separatedBy: .newlines)
        let head = lines.prefix(5).joined(separator: "\n")
        let preview = head.count > collapsedLength ? "\(head.prefix(collapsedLength).trimmingCharacters(in: .whitespacesAndNewlines))..." : "\(head.trimmingCharacters(in: .whitespacesAndNewlines))..."
        let hidden = max(0, lines.count - 5)
        return hidden > 0 ? "\(preview)\n\nЕще \(hidden) строк диагностики" : preview
    }

    static func diagnosticGroupBody(_ messages: [SupportMessage], expanded: Bool) -> String {
        if expanded {
            return messages.enumerated().map { index, message in
                diagnosticPreview(message.body).replacingOccurrences(of: "Автоматическая диагностика", with: "Отчет \(index + 1), \(DateFormatter.vexSupportTime(message.createdAt) ?? "")")
            }.joined(separator: "\n\n")
        }
        guard let latest = messages.last else { return "Автоматическая диагностика" }
        let fields = diagnosticFields(latest.body)
        var lines = ["Автоматическая диагностика (\(messages.count))"]
        if let status = fields["status"] {
            lines.append("последний статус: \(status)")
        }
        if let reason = fields["reason"] {
            lines.append("последняя причина: \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    static func buildSubject(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        let firstLine = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Вопрос в поддержку"
        if firstLine.count <= 46 {
            return firstLine
        }
        return "\(firstLine.prefix(43))..."
    }

    static func messageKey(_ message: SupportMessage) -> String {
        [message.id, message.ticketId, message.sender, message.createdAt, message.body.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: ":")
    }

    private static func chatMessages(from tickets: [SupportTicket]) -> [SupportMessage] {
        let sorted = tickets.flatMap(legacyMessages)
            .sorted { timestamp($0.createdAt) < timestamp($1.createdAt) }
        return removeNearDuplicates(unique(sorted))
    }

    private static func legacyMessages(for ticket: SupportTicket) -> [SupportMessage] {
        if let messages = ticket.messages, !messages.isEmpty {
            return messages
        }
        var items: [SupportMessage] = []
        if !ticket.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(SupportMessage(id: "\(ticket.id)-user", ticketId: ticket.id, sender: "user", authorId: nil, body: ticket.message, createdAt: ticket.createdAt))
        }
        if let adminNote = ticket.adminNote, !adminNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(SupportMessage(id: "\(ticket.id)-admin", ticketId: ticket.id, sender: "admin", authorId: nil, body: adminNote, createdAt: ticket.updatedAt))
        }
        return items
    }

    private static func unique(_ messages: [SupportMessage]) -> [SupportMessage] {
        var seen = Set<String>()
        return messages.filter { message in
            let key = messageKey(message)
            return seen.insert(key).inserted
        }
    }

    private static func removeNearDuplicates(_ messages: [SupportMessage]) -> [SupportMessage] {
        messages.enumerated().filter { index, message in
            guard index > 0 else { return true }
            let previous = messages[index - 1]
            guard previous.sender == message.sender else { return true }
            guard normalize(previous.body) == normalize(message.body) else { return true }
            return abs(timestamp(previous.createdAt).timeIntervalSince(timestamp(message.createdAt))) > duplicateWindow
        }.map(\.element)
    }

    private static func diagnosticGroupID(_ messages: [SupportMessage]) -> String {
        guard let first = messages.first, let last = messages.last else { return "diagnostics-empty" }
        return ["diagnostics", first.ticketId, first.createdAt, last.createdAt, String(messages.count)].joined(separator: ":")
    }

    static func isDiagnostic(_ body: String) -> Bool {
        body.contains("generated_at:") && (body.contains("check.") || body.contains("status:"))
    }

    private static func diagnosticPreview(_ body: String) -> String {
        let fields = diagnosticFields(body)
        var lines = ["Автоматическая диагностика"]
        if let status = fields["status"] {
            lines.append("статус: \(status)")
        }
        if let reason = fields["reason"] {
            lines.append("причина: \(reason)")
        }
        if let error = fields["error"] {
            lines.append("ошибка: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func diagnosticFields(_ body: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("error=") {
                values["error"] = String(line.dropFirst("error=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    private static func normalize(_ body: String) -> String {
        body.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func timestamp(_ value: String) -> Date {
        SupportDateParser.parse(value) ?? .distantPast
    }
}

private extension DateFormatter {
    static func vexSupportTime(_ value: String) -> String? {
        guard let date = SupportDateParser.parse(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private enum SupportDateParser {
    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: trimmed) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: trimmed)
    }
}
