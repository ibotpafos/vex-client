import XCTest
@testable import VEXNativeMac

@MainActor
final class SparkleUpdateTests: XCTestCase {
    func testHeaderUpdateActionRoutesToSparkleService() {
        let updater = MockNativeUpdaterService()
        let appState = VEXAppState(nativeUpdater: updater)

        XCTAssertEqual(appState.headerUpdateAction, .sparkleCheck)
        XCTAssertTrue(appState.canCheckForNativeUpdates)

        appState.checkForNativeUpdates()

        XCTAssertEqual(updater.checkForUpdatesCallCount, 1)
        XCTAssertEqual(appState.statusMessage, "Открыли Sparkle проверку обновлений.")
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
        XCTAssertTrue(script.contains("VEX_NATIVE_BUILD must be numeric"))
        XCTAssertTrue(script.contains("Contents/Frameworks/Sparkle.framework"))
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
        XCTAssertTrue(script.contains("VEX_NATIVE_DISTRIBUTION_MODE"))
        XCTAssertTrue(script.contains("ad-hoc signed as expected for internal distribution"))
    }

    func testNativeMacInternalReleaseScriptDoesNotRequireAppleDeveloperID() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build_native_macos_internal_release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("VEX_NATIVE_REQUIRE_DEVELOPER_ID=0"))
        XCTAssertTrue(script.contains("VEX_NATIVE_DISTRIBUTION_MODE"))
        XCTAssertTrue(script.contains("build_native_macos_sparkle_release.sh"))
        XCTAssertTrue(script.contains("Internal release cannot use ephemeral Sparkle keys"))
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
    }

    func testNativeMacAutonomousReleaseScriptOwnsBuildDeployVerifyFlow() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = packageRoot
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/release_native_macos_autonomous.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("resolve_next_release"))
        XCTAssertTrue(script.contains("build_native_macos_internal_release.sh"))
        XCTAssertTrue(script.contains("prepare_native_macos_deploy_bundle.sh"))
        XCTAssertTrue(script.contains("DOWNLOAD_SCOPE=native-macos"))
        XCTAssertTrue(script.contains("production-downloads-deploy"))
        XCTAssertTrue(script.contains("validate_live_appcast"))
        XCTAssertTrue(script.contains("refuses ephemeral Sparkle keys"))
    }
}

@MainActor
private final class MockNativeUpdaterService: NativeUpdaterService {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    private(set) var checkForUpdatesCallCount = 0

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}
