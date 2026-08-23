import XCTest
@testable import VEXNativeMac

@MainActor
final class SparkleUpdateTests: XCTestCase {
    func testStartupDoesNotAutoCheckUpdatesAtLaunch() {
        let updater = MockNativeUpdaterService()
        let appState = VEXAppState(nativeUpdater: updater)

        appState.prepareAutomaticUpdatesForStartup()
        appState.prepareAutomaticUpdatesForStartup()

        // Sparkle is constructed lazily only on explicit user action; launch
        // must not schedule background checks (Tahoe launch-drain crash).
        XCTAssertEqual(updater.checkForUpdatesInBackgroundCallCount, 0)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
        XCTAssertTrue(updater.startUpdaterCallCount == 0)
    }

    func testStartupRespectsUserOptOutFromAutomaticUpdateChecks() {
        let updater = MockNativeUpdaterService()
        updater.automaticallyChecksForUpdates = false
        let appState = VEXAppState(nativeUpdater: updater)

        appState.prepareAutomaticUpdatesForStartup()

        XCTAssertEqual(updater.checkForUpdatesInBackgroundCallCount, 0)
    }

    func testHeaderUpdateActionRoutesToSparkleService() {
        let updater = MockNativeUpdaterService()
        let appState = VEXAppState(nativeUpdater: updater)

        XCTAssertEqual(appState.headerUpdateAction, .sparkleCheck)
        XCTAssertTrue(appState.canCheckForNativeUpdates)

        appState.checkForNativeUpdates()

        XCTAssertEqual(updater.checkForUpdatesCallCount, 1)
        XCTAssertEqual(appState.statusMessage, "Открыли Sparkle проверку обновлений.")
    }

    func testSparklePublicKeyValidationRejectsMissingAndPlaceholderValues() {
        XCTAssertFalse(SparkleUpdaterConfiguration.isValidPublicEDKey(nil))
        XCTAssertFalse(
            SparkleUpdaterConfiguration.isValidPublicEDKey(
                "VEX_SPARKLE_PUBLIC_ED_KEY_NOT_SET"
            )
        )
        XCTAssertFalse(
            SparkleUpdaterConfiguration.isValidPublicEDKey(
                Data(repeating: 0x7f, count: 31).base64EncodedString()
            )
        )
    }

    func testSparklePublicKeyValidationAcceptsEd25519KeyMaterial() {
        let publicKey = Data(repeating: 0x42, count: 32).base64EncodedString()

        XCTAssertTrue(
            SparkleUpdaterConfiguration.isValidPublicEDKey(publicKey)
        )
    }

    func testUnavailableUpdaterDoesNotClaimSparkleWindowWasOpened() {
        let updater = MockNativeUpdaterService(canCheckForUpdates: false)
        let appState = VEXAppState(nativeUpdater: updater)

        appState.checkForNativeUpdates()

        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
        XCTAssertEqual(
            appState.statusMessage,
            "Проверка обновлений временно недоступна."
        )
    }

    func testSameVersionUpdateMetadataDoesNotSurfaceReadyState() {
        let appState = VEXAppState(nativeUpdater: MockNativeUpdaterService())
        appState.applyUpdateCheck(Self.updateCheck(
            updateAvailable: true,
            latestVersion: VEXAppInfo.version,
            latestBuild: VEXAppInfo.buildNumber
        ))

        XCTAssertFalse(appState.hasNewerNativeUpdate)
        XCTAssertNil(appState.updateReadyText)
    }

    func testNewerVersionUpdateMetadataSurfacesReadyState() {
        let appState = VEXAppState(nativeUpdater: MockNativeUpdaterService())
        appState.applyUpdateCheck(Self.updateCheck(
            updateAvailable: true,
            latestVersion: "999.0.0",
            latestBuild: VEXAppInfo.buildNumber
        ))

        XCTAssertTrue(appState.hasNewerNativeUpdate)
        XCTAssertEqual(appState.updateReadyText, "v999.0.0 готово к установке")
        XCTAssertEqual(appState.availableNativeUpdateVersion, "999.0.0")
    }

    func testSameVersionDoesNotSurfaceHeaderUpdateBadge() {
        let appState = VEXAppState(nativeUpdater: MockNativeUpdaterService())
        appState.applyUpdateCheck(Self.updateCheck(
            updateAvailable: true,
            latestVersion: VEXAppInfo.version,
            latestBuild: VEXAppInfo.buildNumber
        ))

        XCTAssertNil(appState.availableNativeUpdateVersion)
    }

    func testFocusPulseDockSurfacesUpdateStateAndSettingsOwnsUpdateAction() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dock = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/FocusPulseNavigationDock.swift"
            ),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/VEXSettingsView.swift"
            ),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VEXNativeMac/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(dock.contains("availableUpdateVersion"))
        XCTAssertTrue(dock.contains("Доступно обновление"))
        XCTAssertTrue(dock.contains("case settings"))
        XCTAssertTrue(settings.contains("appState.checkForNativeUpdates()"))
        XCTAssertTrue(settings.contains("Проверить обновления"))
        XCTAssertTrue(content.contains("availableUpdateVersion: appState.availableNativeUpdateVersion"))
    }

    func testDockUpdateIndicatorUsesQuietBadgeStyling() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dock = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/FocusPulseNavigationDock.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(dock.contains("Color.vexCyan"))
        XCTAssertTrue(dock.contains(".frame(width: 7, height: 7)"))
        XCTAssertFalse(dock.contains("Text(version)"))
    }

    func testOpenClientPeriodicallyRefreshesUpdateAvailability() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appState = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Stores/VEXAppState.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("startUpdateMonitoring()"))
        XCTAssertTrue(appState.contains("updateMonitorTask"))
        XCTAssertTrue(appState.contains("updateRefreshIntervalNanoseconds"))
        XCTAssertTrue(appState.contains("await self.loadUpdate(reportErrors: false)"))
        XCTAssertTrue(appState.contains("if reportErrors"))
    }

    func testSettingsExposeUserControlForAutomaticUpdateChecks() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settings = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/VEXNativeMac/Views/VEXSettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(settings.contains("Обновлять VEX автоматически"))
        XCTAssertTrue(settings.contains("appState.automaticallyChecksForUpdates"))
    }

    func testLegacyInstallerLaunchPathIsAbsent() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let startup = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VEXNativeMac/Services/StartupService.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VEXNativeMac/Stores/VEXAppState.swift"),
            encoding: .utf8
        )
        let updatePanel = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/VEXNativeMac/Views/UpdateCenterPanel.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(startup.contains("struct UpdateService"))
        XCTAssertFalse(startup.contains("launchInstaller"))
        XCTAssertFalse(appState.contains("restartAndUpdateNow"))
        XCTAssertFalse(appState.contains("downloadUpdate()"))
        XCTAssertFalse(updatePanel.contains("Скачать и открыть установщик"))
        XCTAssertFalse(updatePanel.contains("Открыть ручную ссылку"))
    }

    func testNativeMacBuildScriptContainsSparklePlistContract() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("SUFeedURL"))
        XCTAssertTrue(script.contains("SUPublicEDKey"))
        XCTAssertTrue(script.contains("SUEnableAutomaticChecks"))
        XCTAssertTrue(script.contains("SUAutomaticallyUpdate"))
        XCTAssertTrue(script.contains("<key>SUAllowsAutomaticUpdates</key>"))
        XCTAssertTrue(script.contains("<key>SUVerifyUpdateBeforeExtraction</key>"))
        XCTAssertTrue(
            script.contains("<key>SUAutomaticallyUpdate</key>\n  <true/>")
        )
        XCTAssertTrue(script.contains("VEX_NATIVE_BUILD must be numeric"))
        XCTAssertTrue(script.contains("Contents/Frameworks/Sparkle.framework"))
        XCTAssertTrue(script.contains("cwILAPfDRcrjrAWmD/VrMzIh983R2hncvI44tfEZauI="))
        XCTAssertTrue(script.contains("Sparkle public Ed25519 key must decode to 32 bytes"))
        XCTAssertTrue(script.contains("VEX_SPARKLE_FEED_URL must use HTTPS"))
    }

    func testSparkleDependencyUsesSecurityPatchedRelease() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let package = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(package.contains("exact: \"2.9.6\""))
    }

    func testNativeAppInfoUsesBundleVersionForUpdateContracts() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let modelsURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VEXNativeMac")
            .appendingPathComponent("Models")
            .appendingPathComponent("VEXModels.swift")
        let apiClientURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("VEXNativeMac")
            .appendingPathComponent("Services")
            .appendingPathComponent("VEXAPIClient.swift")
        let models = try String(contentsOf: modelsURL, encoding: .utf8)
        let apiClient = try String(contentsOf: apiClientURL, encoding: .utf8)

        XCTAssertTrue(models.contains("CFBundleShortVersionString"))
        XCTAssertTrue(models.contains("CFBundleVersion"))
        XCTAssertTrue(models.contains("Bundle(identifier: \"app.vex.vpn.native\")"))
        XCTAssertTrue(apiClient.contains("VEXAppInfo.version"))
        XCTAssertTrue(apiClient.contains("String(VEXAppInfo.buildNumber)"))
        XCTAssertFalse(apiClient.contains("request.setValue(\"0.1.0\", forHTTPHeaderField: \"X-Vex-App-Version\")"))
        XCTAssertFalse(apiClient.contains("request.setValue(\"1\", forHTTPHeaderField: \"X-Vex-Build-Number\")"))
    }

    func testNativeMacPkgBuildScriptInstallsHelperDuringPostinstall() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_pkg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("pkgbuild"))
        XCTAssertTrue(script.contains("postinstall"))
        XCTAssertTrue(script.contains("install-vex-vpn-helper.sh"))
        XCTAssertTrue(script.contains("/Applications/VEX Native.app"))
        XCTAssertTrue(script.contains("INSTALL_APP_BUNDLE_NAME=\"VEX Native.app\""))
        XCTAssertTrue(script.contains("config_path"))
    }

    func testNativeMacProductionPreflightChecksReleaseContracts() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/native_macos_production_preflight.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("LSMinimumSystemVersion"))
        XCTAssertTrue(script.contains("SUPublicEDKey"))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("sparkle:edSignature"))
        XCTAssertTrue(script.contains("VEX_NATIVE_REQUIRE_DEVELOPER_ID"))
        XCTAssertTrue(script.contains("Developer ID Application"))
        XCTAssertTrue(script.contains("Developer ID Installer"))
        XCTAssertTrue(script.contains("VEX_NATIVE_DISTRIBUTION_MODE"))
        XCTAssertTrue(script.contains("ad-hoc signed as expected for internal distribution"))
        XCTAssertTrue(script.contains("VEX_NATIVE_VERIFY_INSTALLED_RUNTIME"))
        XCTAssertTrue(script.contains("verify_native_macos_runtime.sh"))
        XCTAssertTrue(script.contains("STRICT=1"))
        XCTAssertTrue(script.contains("for signed_resource in awg amneziawg-go vex-helper; do"))
        XCTAssertTrue(script.contains("codesign --verify --strict \"${resources_dir}/${signed_resource}\""))
    }

    func testNativeMacAppBuildSignsExecutableHelperResourcesBeforeAppBundle() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("for signed_resource in awg amneziawg-go vex-helper; do"))
        XCTAssertTrue(script.contains("codesign \"${CODESIGN_ARGS[@]}\" \"${APP_DIR}/Contents/Resources/resources/${signed_resource}\""))
        XCTAssertTrue(script.contains("codesign --verify --strict \"${APP_DIR}/Contents/Resources/resources/${signed_resource}\""))
    }

    func testNativeMacInternalReleaseScriptDoesNotRequireAppleDeveloperID() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_internal_release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("VEX_NATIVE_REQUIRE_DEVELOPER_ID=0"))
        XCTAssertTrue(script.contains("VEX_NATIVE_PRODUCTION=0"))
        XCTAssertFalse(script.contains("VEX_NATIVE_PRODUCTION=1"))
        XCTAssertTrue(script.contains("VEX_NATIVE_DISTRIBUTION_MODE"))
        XCTAssertTrue(script.contains("build_native_macos_sparkle_release.sh"))
        XCTAssertTrue(script.contains("Internal release cannot use ephemeral Sparkle keys"))
    }

    func testSparkleManifestRecordsCustomUpdateSignatureContract() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_sparkle_release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("signing_authority"))
        XCTAssertTrue(script.contains("\"updateSignatureScheme\": \"sparkle-ed25519\""))
        XCTAssertTrue(script.contains("\"distributionMode\": \"sparkle-ed25519-custom\""))
        XCTAssertTrue(script.contains("\"appleDeveloperSigned\""))
    }

    func testAutonomousNativeMacReleaseKeepsDeploySafetyGatesEnabled() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/release_native_macos_autonomous.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("ALLOW_DIRTY_DEPLOY=\"${ALLOW_DIRTY_DEPLOY:-0}\""))
        XCTAssertTrue(script.contains("ALLOW_NO_UPSTREAM_DEPLOY=\"${ALLOW_NO_UPSTREAM_DEPLOY:-0}\""))
        XCTAssertTrue(script.contains("reuse_primary_worktree_sparkle_cache"))
        XCTAssertTrue(script.contains("--disable-automatic-resolution"))
        XCTAssertTrue(script.contains("ALLOW_RELEASE_ARTIFACT_DIRTY=1"))
        XCTAssertTrue(script.contains("ALLOW_DIRTY_SOURCE"))
        XCTAssertTrue(script.contains("requires a clean tracked source tree"))
        XCTAssertTrue(script.contains("validate_public_release_artifacts"))
        XCTAssertTrue(script.contains("RUN_PUBLIC_PREFLIGHT"))
        XCTAssertTrue(script.contains("RUN_DEPLOY=1 requires RUN_PUBLIC_PREFLIGHT=1"))
        XCTAssertTrue(script.contains("sign_update"))
        XCTAssertTrue(script.contains("--verify"))
        XCTAssertTrue(script.contains("derived_public_key"))
        XCTAssertTrue(script.contains("Sparkle private/public key mismatch"))
        XCTAssertTrue(script.contains("sparkle-ed25519-custom"))
        XCTAssertTrue(script.contains("archiveSHA256"))
        XCTAssertTrue(script.contains("appcastSHA256"))
        XCTAssertTrue(script.contains("archive SHA-256 mismatch"))
        XCTAssertTrue(script.contains("appcast SHA-256 mismatch"))
        XCTAssertTrue(script.contains("sparklePublicEDKey"))
        XCTAssertFalse(script.contains("public release requires Developer ID"))
    }

    func testNativeMacDeployBundleScriptChecksReleaseFiles() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/prepare_native_macos_deploy_bundle.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("release-manifest.json"))
        XCTAssertTrue(script.contains("downloadURL does not end with archive name"))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertTrue(script.contains("appcast.xml"))
        XCTAssertTrue(script.contains("ZIP-only Sparkle distribution"))
        XCTAssertFalse(script.contains("cp \"${pkg_path}\""))
    }

    func testNativeMacAutonomousReleaseScriptOwnsBuildDeployVerifyFlow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/release_native_macos_autonomous.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("resolve_next_release"))
        XCTAssertTrue(script.contains("candidates.append((local_version, local_build))"))
        XCTAssertTrue(script.contains("candidates.append((remote_version, remote_build))"))
        XCTAssertTrue(script.contains("max(candidates, key=lambda candidate: candidate[1]"))
        XCTAssertTrue(script.contains("build_native_macos_internal_release.sh"))
        XCTAssertTrue(script.contains("prepare_native_macos_deploy_bundle.sh"))
        XCTAssertTrue(script.contains("DOWNLOAD_SCOPE=native-macos"))
        XCTAssertTrue(script.contains("production-downloads-deploy"))
        XCTAssertTrue(script.contains("validate_live_appcast"))
        XCTAssertTrue(script.contains("RUN_METADATA_DEPLOY"))
        XCTAssertTrue(script.contains("publish_native_macos_release_metadata.py"))
        XCTAssertTrue(script.contains("refuses ephemeral Sparkle keys"))
    }

    private static func updateCheck(
        updateAvailable: Bool,
        latestVersion: String,
        latestBuild: Int
    ) -> AppUpdateCheckResult {
        AppUpdateCheckResult(
            updateAvailable: updateAvailable,
            required: false,
            currentBuildBlocked: false,
            latestVersion: latestVersion,
            latestBuild: latestBuild,
            minSupportedBuild: 1,
            minConfigSchemaVersion: nil,
            downloadUrl: "https://vexguard.app/downloads/native-macos/VEXNativeMac-test.zip",
            changelog: nil,
            checksumSha256: nil,
            signatureUrl: nil,
            channel: "stable",
            reason: nil,
            rolloutPercent: nil,
            checkedAt: nil
        )
    }
}

@MainActor
private final class MockNativeUpdaterService: NativeUpdaterService {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates: Bool
    let isEnabled = true
    private(set) var checkForUpdatesCallCount = 0
    private(set) var checkForUpdatesInBackgroundCallCount = 0
    private(set) var startUpdaterCallCount = 0

    init(canCheckForUpdates: Bool = true) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func startUpdater() {
        startUpdaterCallCount += 1
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func checkForUpdatesInBackground() {
        checkForUpdatesInBackgroundCallCount += 1
    }
}
