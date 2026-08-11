import AppKit
import XCTest
@testable import VEXNativeMac

final class ServerSidebarWindowTests: XCTestCase {
    private let germany = VpnLocation(
        id: "de-berlin",
        countryCode: "DE",
        city: "Berlin",
        flagEmoji: "🇩🇪",
        availability: "available",
        status: "healthy",
        healthyNodes: 3,
        latencyMs: 12
    )
    private let finland = VpnLocation(
        id: "fi-helsinki",
        countryCode: "FI",
        city: "Helsinki",
        flagEmoji: "🇫🇮",
        availability: "available",
        status: "online",
        healthyNodes: 2,
        latencyMs: 8
    )
    private let maintenance = VpnLocation(
        id: "nl-amsterdam",
        countryCode: "NL",
        city: "Amsterdam",
        flagEmoji: "🇳🇱",
        availability: "unavailable",
        status: "maintenance",
        healthyNodes: 0,
        latencyMs: nil
    )

    func testSearchMatchesRussianCountryWithLatinQuery() {
        XCTAssertTrue(
            ServerSidebarSearch.matches(
                query: "fin",
                values: ["fi", "FI", "🇫🇮 Финляндия", "healthy"]
            )
        )
        XCTAssertFalse(
            ServerSidebarSearch.matches(
                query: "герм",
                values: ["fi", "FI", "🇫🇮 Финляндия", "healthy"]
            )
        )
        XCTAssertTrue(
            ServerSidebarSearch.matches(
                query: "герм",
                values: ["de", "DE", "Germany", "healthy"]
            )
        )
    }

    func testFavoritesCodecPersistsUniqueStableLocationIDs() {
        var favorites = ServerSidebarFavorites.decode("fi-helsinki,de-berlin,fi-helsinki")

        favorites = ServerSidebarFavorites.toggling("nl-amsterdam", in: favorites)
        favorites = ServerSidebarFavorites.toggling("de-berlin", in: favorites)

        XCTAssertEqual(favorites, Set(["fi-helsinki", "nl-amsterdam"]))
        XCTAssertEqual(
            ServerSidebarFavorites.encode(favorites),
            "fi-helsinki,nl-amsterdam"
        )
    }

    func testFastestFilterUsesAvailableLatencyOrder() {
        let result = ServerSidebarCatalog.filtered(
            locations: [germany, maintenance, finland],
            query: "",
            filter: .fastest,
            favoriteIDs: []
        )

        XCTAssertEqual(result.map(\.id), ["fi-helsinki", "de-berlin"])
        XCTAssertEqual(ServerSidebarCatalog.groups(result).map(\.id), ["FI", "DE"])
    }

    func testFastestFilterIgnoresFavoritePriorityAndPreservesLatencyInsideCountry() {
        let slowFavorite = VpnLocation(
            id: "de-berlin-slow",
            countryCode: "DE",
            city: "Aachen",
            flagEmoji: "🇩🇪",
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: 90
        )
        let fast = VpnLocation(
            id: "de-munich-fast",
            countryCode: "DE",
            city: "Zurich",
            flagEmoji: "🇩🇪",
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: 6
        )

        let result = ServerSidebarCatalog.filtered(
            locations: [slowFavorite, fast],
            query: "",
            filter: .fastest,
            favoriteIDs: ["de-berlin-slow"]
        )
        let grouped = ServerSidebarCatalog.groups(result)

        XCTAssertEqual(result.map(\.id), ["de-munich-fast", "de-berlin-slow"])
        XCTAssertEqual(grouped[0].locations.map(\.id), ["de-munich-fast", "de-berlin-slow"])
    }

    func testKeyboardCandidatesExcludeUnavailableServersAndNormalizeStaleSelection() {
        let candidates = ServerSidebarKeyboard.candidates(
            locations: [maintenance, finland],
            includesAuto: true
        )

        XCTAssertEqual(candidates, [ServerSidebarKeyboard.autoID, "fi-helsinki"])
        XCTAssertEqual(
            ServerSidebarKeyboard.normalizedSelection("missing", candidates: candidates),
            ServerSidebarKeyboard.autoID
        )
        XCTAssertEqual(
            ServerSidebarKeyboard.normalizedSelection("fi-helsinki", candidates: candidates),
            "fi-helsinki"
        )
    }

    func testFavoritesAndAvailableFiltersHaveDistinctResults() {
        let locations = [germany, maintenance, finland]

        let favorites = ServerSidebarCatalog.filtered(
            locations: locations,
            query: "",
            filter: .favorites,
            favoriteIDs: ["nl-amsterdam", "fi-helsinki"]
        )
        let available = ServerSidebarCatalog.filtered(
            locations: locations,
            query: "",
            filter: .available,
            favoriteIDs: []
        )

        XCTAssertEqual(favorites.map(\.id), ["fi-helsinki", "nl-amsterdam"])
        XCTAssertEqual(available.map(\.id), ["fi-helsinki", "de-berlin"])
    }

    func testCatalogGroupsCitiesByCountry() {
        let munich = VpnLocation(
            id: "de-munich",
            countryCode: "DE",
            city: "Munich",
            flagEmoji: "🇩🇪",
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: 18
        )

        let groups = ServerSidebarCatalog.groups([munich, finland, germany])

        XCTAssertEqual(groups.map(\.id), ["DE", "FI"])
        XCTAssertEqual(groups[0].locations.map(\.id), ["de-munich", "de-berlin"])
    }

    func testOperationStateDrivesEveryVisibleSwitchProgressPhase() {
        XCTAssertEqual(
            ServerSidebarSwitchProgress.make(from: .preparingRoute, name: "Финляндия")?.phase,
            .preparing
        )
        XCTAssertEqual(
            ServerSidebarSwitchProgress.make(from: .connecting, name: "Финляндия")?.phase,
            .connecting
        )
        XCTAssertEqual(
            ServerSidebarSwitchProgress.make(from: .verifying, name: "Финляндия")?.phase,
            .verifying
        )
        XCTAssertEqual(
            ServerSidebarSwitchProgress.make(from: .failed("Ошибка"), name: "Финляндия")?.phase,
            .failed
        )
        XCTAssertNil(ServerSidebarSwitchProgress.make(from: .idle, name: "Финляндия"))
    }

    func testSidebarExposesDesktopKeyboardContract() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/VEXNativeMacApp.swift"
            ),
            encoding: .utf8
        )
        let panelSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/ServerPickerPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("VEXServerSidebarWindow.toggle()"))
        XCTAssertTrue(appSource.contains(".keyboardShortcut(\"k\", modifiers: .command)"))
        XCTAssertTrue(panelSource.contains(".onKeyPress(.upArrow)"))
        XCTAssertTrue(panelSource.contains(".onKeyPress(.downArrow)"))
        XCTAssertTrue(panelSource.contains(".onKeyPress(.return)"))
    }

    func testLocationRefreshOwnsIndependentLoadingAndErrorState() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Stores/VEXAppState.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@Published private(set) var isLoadingLocations"))
        XCTAssertTrue(source.contains("@Published private(set) var locationLoadError"))
        XCTAssertTrue(source.contains("@Published private(set) var lastLocationsRefreshAt"))
        XCTAssertTrue(source.contains("func refreshLocations() async"))
    }

    func testConnectedServerSelectionIsSerializedAndRollsBackPersistedChoice() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Stores/VEXAppState.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("guard !isServerSelectionBusy, !isVpnBusy, !helper.isBusy"))
        XCTAssertTrue(source.contains("isServerSelectionBusy = true"))
        XCTAssertTrue(source.contains("selectedLocationId = previousLocationID"))
        XCTAssertTrue(source.contains("serverSelectionMode = previousSelectionMode"))
        XCTAssertTrue(source.contains("autoServerEnabled = previousAutoServerEnabled"))

        let switchStart = try XCTUnwrap(
            source.range(of: "private func switchConnectedVPNLocation")
        )
        let switchSource = source[switchStart.lowerBound...]
        let busyCapture = try XCTUnwrap(switchSource.range(of: "isVpnBusy = true"))
        let tokenRefresh = try XCTUnwrap(
            switchSource.range(of: "authenticatedAccessToken()")
        )
        XCTAssertLessThan(busyCapture.lowerBound, tokenRefresh.lowerBound)
    }

    func testServerListUsesAnInWindowOverlayInsteadOfASecondWindow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentURL = packageRoot.appendingPathComponent(
            "Sources/VEXNativeMac/ContentView.swift"
        )
        let appURL = packageRoot.appendingPathComponent(
            "Sources/VEXNativeMac/VEXNativeMacApp.swift"
        )
        let content = try String(contentsOf: contentURL, encoding: .utf8)
        let app = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(content.contains("@State private var isServerDrawerPresented"))
        XCTAssertTrue(content.contains("ServerSidebarOverlay"))
        XCTAssertTrue(content.contains("Button(action: dismissServerDrawer)"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Закрыть список серверов\")"))
        XCTAssertFalse(app.contains("ServerSidebarWindowController"))
        XCTAssertFalse(app.contains("addChildWindow(panel"))
    }

    func testLoadingStateUsesAnimatedVEXSpinner() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/VEXNativeMac/Views/ServerSidebarComponents.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("VEXMiniSpinner"))
        XCTAssertTrue(source.contains("Подгружаем доступные серверы VEX"))
    }

    func testServerRowsAvoidNestedCardAndIconWrappers() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/ServerSidebarComponents.swift"
            ),
            encoding: .utf8
        )
        let rowStart = try XCTUnwrap(source.range(of: "struct ServerPickerRow"))
        let rowEnd = try XCTUnwrap(source.range(of: "struct ServerPickerEmptyRow"))
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]

        XCTAssertFalse(rowSource.contains("PanelIcon("))
        XCTAssertFalse(rowSource.contains("selected ? \"checkmark.circle.fill\" : \"circle\""))
        XCTAssertFalse(rowSource.contains("Color.vexBorder.opacity(0.14)"))
        XCTAssertTrue(rowSource.contains("keyboardFocused ?"))
    }

    func testTrafficMetricsUseCompactFlatTreatment() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/FocusPulseHero.swift"
            ),
            encoding: .utf8
        )
        let cardStart = try XCTUnwrap(source.range(of: "private struct FocusPulseTrafficCard"))
        let cardEnd = try XCTUnwrap(source.range(of: "private struct MiniTrafficSparkline"))
        let cardSource = source[cardStart.lowerBound..<cardEnd.lowerBound]

        XCTAssertTrue(cardSource.contains(".frame(width: 136, height: 78"))
        XCTAssertFalse(cardSource.contains(".shadow("))
        XCTAssertFalse(cardSource.contains("isHovered"))
    }

    func testSettingsHeaderAndGlyphsAvoidDecorativeWrapperStack() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/VEXSettingsView.swift"
            ),
            encoding: .utf8
        )
        let heroStart = try XCTUnwrap(source.range(of: "private struct SettingsHero"))
        let heroEnd = try XCTUnwrap(source.range(of: "private struct SettingsFeatureCard"))
        let heroSource = source[heroStart.lowerBound..<heroEnd.lowerBound]
        let glyphStart = try XCTUnwrap(source.range(of: "private struct SettingsGlyph"))
        let glyphSource = source[glyphStart.lowerBound...]

        XCTAssertFalse(heroSource.contains("RoundedRectangle("))
        XCTAssertFalse(heroSource.contains("Circle()"))
        XCTAssertFalse(glyphSource.contains(".background(Circle()"))
    }

    func testAccountSummaryAndSubscriptionAvoidOuterSurfaceNesting() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/AccountPanel.swift"
            ),
            encoding: .utf8
        )
        let heroStart = try XCTUnwrap(source.range(of: "private struct AccountHero"))
        let heroEnd = try XCTUnwrap(source.range(of: "private struct BillingFamilyCard"))
        let heroSource = source[heroStart.lowerBound..<heroEnd.lowerBound]
        let pickerStart = try XCTUnwrap(source.range(of: "private var subscriptionPicker"))
        let pickerEnd = try XCTUnwrap(source.range(of: "private var paymentHistory"))
        let pickerSource = source[pickerStart.lowerBound..<pickerEnd.lowerBound]

        XCTAssertFalse(heroSource.contains("VEXFeatureSurface("))
        XCTAssertFalse(pickerSource.contains("AccountSurfaceCard("))
        XCTAssertTrue(pickerSource.contains("BillingFamilyCard("))
        XCTAssertTrue(pickerSource.contains("BillingDurationSelector("))
    }

    func testSubscriptionSelectionFollowsCurrentPlanUntilUserChoosesManually() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/AccountPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@State private var didChooseSubscriptionManually = false"))
        XCTAssertTrue(source.contains("synchronizeSelection(with: appState.billingSummary)"))
        XCTAssertTrue(source.contains("guard !didChooseSubscriptionManually"))
        XCTAssertTrue(source.contains("plan.id == currentPlan.id || plan.months == currentPlan.months"))
    }

    func testSubscriptionAndServerChoicesExposeAccessibleSelectionState() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let account = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/AccountPanel.swift"
            ),
            encoding: .utf8
        )
        let serverRows = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/ServerSidebarComponents.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(account.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(account.contains(".accessibilityValue(\"\\(durationText(selectedPlan.months)), \\(priceText(selectedPlan))\")"))
        XCTAssertTrue(serverRows.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
    }

    func testPowerControlExplainsHelperActionAndDisablesDuringWork() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/FocusPulseHero.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".disabled(isBusy || installationPhase.isActive)"))
        XCTAssertTrue(source.contains("if requiresHelperInstall"))
        XCTAssertTrue(source.contains("return \"Установить системный компонент VEX\""))
    }

}
