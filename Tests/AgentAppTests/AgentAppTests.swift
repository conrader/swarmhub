import Testing
@testable import AgentApp

@Test func backendKindsAreStable() {
    #expect(BackendKind.allCases.count == 3)
    #expect(BackendKind.hermes.rawValue == "Hermes Agent")
}

@Test func defaultHermesURLUsesV1() {
    #expect(AppConstants.defaultHermesURL.hasSuffix("/v1"))
}
