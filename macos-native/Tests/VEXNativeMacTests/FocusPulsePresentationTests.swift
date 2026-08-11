import Foundation
import XCTest
@testable import VEXNativeMac

final class FocusPulsePresentationTests: XCTestCase {
    func testConnectionCopyTracksEveryVpnState() {
        XCTAssertEqual(
            FocusPulsePresentation.connectionTitle(
                status: .connected,
                requiresHelperInstall: false
            ),
            "Подключено"
        )
        XCTAssertEqual(
            FocusPulsePresentation.connectionTitle(
                status: .connecting,
                requiresHelperInstall: false
            ),
            "Подключаемся"
        )
        XCTAssertEqual(
            FocusPulsePresentation.connectionTitle(
                status: .disconnecting,
                requiresHelperInstall: false
            ),
            "Отключаемся"
        )
        XCTAssertEqual(
            FocusPulsePresentation.connectionTitle(
                status: .disconnected,
                requiresHelperInstall: false
            ),
            "Не подключено"
        )
        XCTAssertEqual(
            FocusPulsePresentation.connectionTitle(
                status: .disconnected,
                requiresHelperInstall: true
            ),
            "Требуется helper"
        )
    }

    func testTrafficFormattingUsesCompactRussianUnits() {
        XCTAssertEqual(FocusPulsePresentation.formatBytes(0), "0 Б")
        XCTAssertEqual(FocusPulsePresentation.formatBytes(1_536), "1,5 КБ")
        XCTAssertEqual(FocusPulsePresentation.formatBytes(133_588_582), "127,4 МБ")
    }

    func testConnectionAnimationOnlyRunsDuringRealTransitions() {
        XCTAssertTrue(
            FocusPulsePresentation.shouldAnimateConnection(
                status: .connecting,
                isBusy: false
            )
        )
        XCTAssertTrue(
            FocusPulsePresentation.shouldAnimateConnection(
                status: .disconnected,
                isBusy: true
            )
        )
        XCTAssertTrue(
            FocusPulsePresentation.shouldAnimateConnection(
                status: .disconnecting,
                isBusy: false
            )
        )
        XCTAssertFalse(
            FocusPulsePresentation.shouldAnimateConnection(
                status: .connected,
                isBusy: false
            )
        )
        XCTAssertFalse(
            FocusPulsePresentation.shouldAnimateConnection(
                status: .disconnected,
                isBusy: false
            )
        )
    }

    func testHelperInstallationPhasesExposeStableProgressCopy() {
        XCTAssertEqual(VEXHelperInstallationPhase.preparing.title, "Подготовка helper")
        XCTAssertEqual(VEXHelperInstallationPhase.authorizing.title, "Подтвердите установку")
        XCTAssertEqual(VEXHelperInstallationPhase.installing.title, "Устанавливаем helper")
        XCTAssertEqual(VEXHelperInstallationPhase.verifying.title, "Проверяем helper")
        XCTAssertEqual(VEXHelperInstallationPhase.installed.title, "Helper установлен")
        XCTAssertTrue(VEXHelperInstallationPhase.installing.isActive)
        XCTAssertTrue(VEXHelperInstallationPhase.authorizing.isActive)
        XCTAssertFalse(VEXHelperInstallationPhase.idle.isActive)
        XCTAssertFalse(VEXHelperInstallationPhase.failed("test").isActive)
        XCTAssertEqual(
            VEXHelperInstallationPhase.failed("Причина").detail,
            "Причина"
        )
    }

    func testFeaturedLocationsKeepsSelectedLocationFirstAndLimitsResults() {
        let germany = location(id: "de", city: "Германия", latency: 12)
        let finland = location(id: "fi", city: "Финляндия", latency: 8)
        let netherlands = location(id: "nl", city: "Нидерланды", latency: 18)
        let result = FocusPulsePresentation.featuredLocations(
            [finland, netherlands, germany],
            selectedLocationId: "de",
            limit: 2
        )

        XCTAssertEqual(result.map(\.id), ["de", "fi"])
    }

    func testCountrySilhouetteAssetsContainDetailedServerCountries() {
        for countryCode in ["DE", "FI", "NL", "US", "JP"] {
            let geometry = CountrySilhouetteStore.geometry(for: countryCode)
            XCTAssertNotNil(geometry, "Missing silhouette for \(countryCode)")
            XCTAssertGreaterThan(
                geometry?.rings.reduce(0) { $0 + $1.count } ?? 0,
                20,
                "Silhouette for \(countryCode) is not detailed enough"
            )
        }
    }

    func testPackagedCountrySilhouetteResolvesFromAppResources() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let appBundleURL = temporaryRoot.appendingPathComponent("VEX Native.app", isDirectory: true)
        let appResourcesURL = appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let resourceBundleURL = appResourcesURL
            .appendingPathComponent("VEXNativeMac_VEXNativeMac.bundle", isDirectory: true)
        let silhouetteURL = resourceBundleURL.appendingPathComponent("country-silhouettes.json")
        try FileManager.default.createDirectory(at: resourceBundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: silhouetteURL)

        XCTAssertEqual(
            VEXAppResources.resourceURL(
                forResource: "country-silhouettes",
                withExtension: "json",
                mainBundleURL: appBundleURL,
                mainResourceURL: appResourcesURL
            ),
            silhouetteURL
        )
    }

    func testWindowHeaderOmitsHomeTitleAndNamesSecondaryPages() {
        XCTAssertNil(AppSection.home.headerTitle)
        XCTAssertEqual(AppSection.account.headerTitle, "Аккаунт")
        XCTAssertEqual(AppSection.settings.headerTitle, "Настройки")
    }

    func testClientNavigationDoesNotExposeInAppSupportChat() {
        XCTAssertFalse(AppSection.allCases.map(\.title).contains("Поддержка"))
    }

    func testServerStatusDistinguishesUnknownHealthyDegradedAndUnavailable() {
        XCTAssertEqual(
            FocusPulsePresentation.serverStatus(
                locations: [],
                isAuthenticated: false,
                isLoading: false
            ),
            .unknown
        )
        XCTAssertEqual(
            FocusPulsePresentation.serverStatus(
                locations: [],
                isAuthenticated: true,
                isLoading: true
            ),
            .checking
        )
        XCTAssertEqual(
            FocusPulsePresentation.serverStatus(
                locations: [location(id: "de", city: "Германия", latency: 12)],
                isAuthenticated: true,
                isLoading: false
            ),
            .available
        )
        XCTAssertEqual(
            FocusPulsePresentation.serverStatus(
                locations: [
                    location(id: "de", city: "Германия", latency: 12),
                    location(id: "fi", city: "Финляндия", latency: 8, status: "maintenance"),
                ],
                isAuthenticated: true,
                isLoading: false
            ),
            .degraded
        )
        XCTAssertEqual(
            FocusPulsePresentation.serverStatus(
                locations: [],
                isAuthenticated: true,
                isLoading: false
            ),
            .unavailable
        )
    }

    func testLaunchAnimationIsBriefAndReduceMotionSkipsTheShowcase() {
        XCTAssertEqual(
            VEXLaunchTiming.minimumDisplayNanoseconds(reduceMotion: false),
            1_050_000_000
        )
        XCTAssertEqual(
            VEXLaunchTiming.minimumDisplayNanoseconds(reduceMotion: true),
            80_000_000
        )
    }

    private func location(
        id: String,
        city: String,
        latency: Double,
        status: String = "healthy"
    ) -> VpnLocation {
        VpnLocation(
            id: id,
            countryCode: id.uppercased(),
            city: city,
            flagEmoji: nil,
            availability: "available",
            status: status,
            healthyNodes: 1,
            latencyMs: latency
        )
    }
}
