import XCTest

final class VEXAPIResponseContractTests: XCTestCase {
    func testLocationCapabilitiesAndEligibilityStayConsistent() async throws {
        try await APIContractScenarios.locationCapabilities()
    }

    func testDefaultGETReturnsRedirectWithoutVisitingItsTarget() async throws {
        try await APIContractScenarios.redirects(method: "GET")
    }
    func testDefaultPOSTNeverReplaysItsBodyThroughRedirects() async throws {
        try await APIContractScenarios.redirects(method: "POST")
    }
    func testDefaultLoaderBoundsAStalledResponseBody() async throws {
        try await APIContractScenarios.bodyDeadline()
    }
    func testDefaultLoaderCancelsAStalledResponseBodyWithoutRetry() async throws {
        try await APIContractScenarios.bodyCancellation()
    }
    func testErrorFieldsAreNarrowedIndependentlyWithoutEchoingStructuredBodies() async throws {
        try await APIContractScenarios.errorBodies()
    }
    func testInvalidBaseURLFailsBeforeTransportAndWithoutOutageClassification() async throws {
        try await APIContractScenarios.invalidBaseURLs()
    }
    func testConfiguredAPIBasePreservesDefaultsCustomOriginsAndPathPrefixes() async throws {
        try await APIContractScenarios.baseURLConfiguration()
    }
    func testMalformedMessageCannotDiscardMaintenanceCode() async throws {
        try await APIContractScenarios.maintenanceClassification()
    }
}
