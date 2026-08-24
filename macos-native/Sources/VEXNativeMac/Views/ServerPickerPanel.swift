import SwiftUI

struct ServerSidebarPanel: View {
    @EnvironmentObject private var appState: VEXAppState
    @EnvironmentObject private var helper: VEXHelperModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var keyboardID: String?
    @State private var progress: ServerSidebarSwitchProgress?
    @State private var operationName = ""
    @State private var selectionQueued = false
    @State private var appeared = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.vexBackground
            VStack(alignment: .leading, spacing: 12) {
                header
                search
                filters
                refreshWarning
                if let progress {
                    ServerSidebarSwitchProgressView(progress: progress)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                list
            }
            .padding(16)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -8)
            .scaleEffect(appeared ? 1 : 0.985, anchor: .trailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Все серверы VEX")
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.24).delay(0.04)) { appeared = true }
            }
            listFocused = true
            if appState.serverSidebarOperation.isBusy {
                syncProgress(with: appState.serverSidebarOperation)
            } else {
                appState.acknowledgeServerSidebarOperation(appState.serverSidebarOperation)
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--render-ui-preview") {
                return
            }
            #endif
            await appState.refreshLocations()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await appState.refreshLocations()
            }
        }
        .onChange(of: candidates) { _, updatedCandidates in
            keyboardID = ServerSidebarKeyboard.normalizedSelection(
                keyboardID,
                candidates: updatedCandidates
            )
        }
        .onChange(of: appState.serverSidebarOperation) { _, operation in
            syncProgress(with: operation)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.vexCyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Все серверы")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexText)
                Text(countText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
            }
            Spacer()
            iconButton(
                "arrow.clockwise",
                help: "Обновить серверы",
                disabled: appState.isLoadingLocations
            ) {
                Task { await appState.refreshLocations() }
            }
            .rotationEffect(
                .degrees(appState.isLoadingLocations && !reduceMotion ? 360 : 0)
            )
            .animation(
                appState.isLoadingLocations && !reduceMotion
                    ? .linear(duration: 0.82).repeatForever(autoreverses: false)
                    : nil,
                value: appState.isLoadingLocations
            )
            iconButton("xmark", help: "Закрыть список серверов", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(searchFocused ? Color.vexCyan : Color.vexMuted)
            TextField("Поиск страны или сервера", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.vexText)
                .focused($searchFocused)
                .onSubmit {
                    keyboardID = candidates.first
                    activateKeyboardSelection()
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.vexMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.vexInput.opacity(0.90))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    searchFocused ? Color.vexCyan.opacity(0.52) : Color.clear,
                    lineWidth: 1
                )
        }
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(ServerSidebarFilter.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        appState.setServerSidebarFilter(item)
                        keyboardID = nil
                    }
                    listFocused = true
                } label: {
                    Text(item.title)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            filter == item ? Color.vexCyanLight : Color.vexSecondaryText
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(
                                filter == item
                                    ? Color.vexCyan.opacity(0.11)
                                    : Color.clear
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Фильтр: \(item.title)")
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var refreshWarning: some View {
        if let error = appState.locationLoadError, !appState.locations.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.orange)
                Text("Не удалось обновить. Показаны последние данные.")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await appState.refreshLocations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(error)
                .accessibilityLabel("Повторить обновление серверов")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                if showsAuto {
                    ServerPickerRow(
                        systemName: "sparkles",
                        title: "Автовыбор",
                        subtitle: "Самый быстрый доступный маршрут",
                        trailing: appState.serverSelectionMode == "auto" ? "Выбран" : nil,
                        selected: appState.serverSelectionMode == "auto",
                        keyboardFocused: keyboardID == ServerSidebarKeyboard.autoID,
                        favorite: false,
                        favoriteVisible: false,
                        actionDisabled: isSwitching,
                        favoriteDisabled: true,
                        disabledReason: isSwitching ? "Дождитесь завершения текущей операции VPN." : nil,
                        action: selectAuto,
                        onFavorite: {}
                    )
                    .id(ServerSidebarKeyboard.autoID)
                }
                if appState.locations.isEmpty {
                    ServerPickerEmptyRow(
                        isLoading: appState.isLoadingLocations,
                        errorMessage: appState.locationLoadError
                    ) {
                        Task { await appState.refreshLocations() }
                    }
                } else if visibleLocations.isEmpty {
                    ServerPickerMessageRow(
                        systemName: "magnifyingglass",
                        title: "Ничего не найдено",
                        subtitle: emptyText
                    )
                } else {
                    ForEach(groups) { country in
                        countryView(country)
                    }
                }
            }
            .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .focusable()
            .focused($listFocused)
            .onKeyPress(.upArrow) {
                moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(1)
                return .handled
            }
            .onKeyPress(.return) {
                activateKeyboardSelection()
                return .handled
            }
            .onChange(of: keyboardID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private func countryView(_ country: ServerSidebarCountryGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(country.flagEmoji)
                Text(country.title)
                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                    .foregroundStyle(Color.vexSecondaryText)
                Spacer()
                Text("\(country.locations.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.vexMuted)
            }
            .padding(.horizontal, 5)
            ForEach(country.locations) { location in
                let available = ServerSidebarCatalog.isAvailable(location)
                ServerPickerRow(
                    systemName: "mappin.and.ellipse",
                    title: rowTitle(location),
                    subtitle: "\(nodeCountText(location.healthyNodes)) · \(location.localizedStatus)",
                    trailing: latencyText(location),
                    selected: appState.serverSelectionMode == "manual"
                        && appState.selectedLocationId == location.id,
                    keyboardFocused: keyboardID == location.id,
                    favorite: favoriteIDs.contains(location.id.lowercased()),
                    favoriteVisible: true,
                    actionDisabled: isSwitching || !available,
                    favoriteDisabled: isSwitching,
                    disabledReason: available
                        ? (isSwitching ? "Дождитесь завершения текущей операции VPN." : nil)
                        : "Сервер временно недоступен для подключения.",
                    action: { select(location) },
                    onFavorite: { toggleFavorite(location.id) }
                )
                .id(location.id)
            }
        }
    }

    private var favoriteIDs: Set<String> {
        appState.favoriteLocationIDs
    }

    private var filter: ServerSidebarFilter {
        appState.serverSidebarFilter
    }

    private var visibleLocations: [VpnLocation] {
        ServerSidebarCatalog.filtered(
            locations: appState.locations,
            query: query,
            filter: filter,
            favoriteIDs: favoriteIDs
        )
    }

    private var groups: [ServerSidebarCountryGroup] {
        ServerSidebarCatalog.groups(visibleLocations)
    }

    private var showsAuto: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && filter != .favorites
    }

    private var candidates: [String] {
        ServerSidebarKeyboard.candidates(
            locations: visibleLocations,
            includesAuto: showsAuto
        )
    }

    private var isSwitching: Bool {
        selectionQueued || appState.isVpnBusy || appState.isServerSelectionBusy || helper.isBusy
    }

    private var countText: String {
        let count = appState.locations.count
        guard let date = appState.lastLocationsRefreshAt else {
            return count == 1 ? "1 локация доступна" : "\(count) локаций доступно"
        }
        let age = max(0, Int(Date().timeIntervalSince(date)))
        return "\(count) локаций · \(age < 60 ? "обновлено сейчас" : "\(age / 60) мин назад")"
    }

    private var emptyText: String {
        if filter == .favorites {
            return "Добавьте серверы звездой — они появятся здесь."
        }
        return query.isEmpty
            ? "Для выбранного фильтра пока нет серверов."
            : "Нет серверов по запросу «\(query)»."
    }

    private func iconButton(
        _ image: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.vexSecondaryText)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggleFavorite(_ id: String) {
        appState.toggleFavoriteLocation(id)
    }

    private func moveSelection(_ offset: Int) {
        guard !candidates.isEmpty else { return }
        guard let keyboardID, let index = candidates.firstIndex(of: keyboardID) else {
            self.keyboardID = offset < 0 ? candidates.last : candidates.first
            return
        }
        self.keyboardID = candidates[min(max(index + offset, 0), candidates.count - 1)]
    }

    private func activateKeyboardSelection() {
        guard let keyboardID = ServerSidebarKeyboard.normalizedSelection(
            keyboardID,
            candidates: candidates
        ) else { return }
        self.keyboardID = keyboardID
        if keyboardID == ServerSidebarKeyboard.autoID {
            selectAuto()
        } else if let location = visibleLocations.first(where: {
            $0.id == keyboardID && ServerSidebarCatalog.isAvailable($0)
        }) {
            select(location)
        }
    }

    private func selectAuto() {
        guard !isSwitching else { return }
        operationName = "лучшего сервера"
        selectionQueued = true
        Task {
            defer { selectionQueued = false }
            await appState.selectAutoServer(using: helper)
        }
    }

    private func select(_ location: VpnLocation) {
        guard !isSwitching, ServerSidebarCatalog.isAvailable(location) else { return }
        keyboardID = location.id
        operationName = location.displayName
        selectionQueued = true
        Task {
            defer { selectionQueued = false }
            await appState.selectLocation(location, using: helper)
        }
    }

    private func syncProgress(with operation: ServerSidebarOperationState) {
        let name = operationName.isEmpty
            ? (appState.selectedLocation?.displayName ?? "выбранного сервера")
            : operationName
        guard let updated = ServerSidebarSwitchProgress.make(
            from: operation,
            name: name
        ) else {
            withAnimation(.easeIn(duration: 0.16)) { progress = nil }
            return
        }

        setProgress(updated.name, updated.phase)
        guard [.selected, .verified, .failed].contains(updated.phase) else {
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(updated.phase == .failed ? 4 : 2))
            guard progress == updated else { return }
            withAnimation(.easeIn(duration: 0.16)) { progress = nil }
            appState.acknowledgeServerSidebarOperation(operation)
        }
    }

    private func setProgress(_ name: String, _ phase: ServerSidebarSwitchProgress.Phase) {
        withAnimation(.easeOut(duration: 0.18)) {
            progress = ServerSidebarSwitchProgress(name: name, phase: phase)
        }
    }

    private func rowTitle(_ location: VpnLocation) -> String {
        let city = location.city.trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? location.displayName : city.capitalized
    }

    private func latencyText(_ location: VpnLocation) -> String? {
        FocusPulsePresentation.latencyText(location.latencyMs)
    }

    private func nodeCountText(_ count: Int) -> String {
        FocusPulsePresentation.nodeCountText(count)
    }
}
