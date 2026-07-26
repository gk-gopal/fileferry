import Testing
@testable import ADBKit

@Test("ADBError carries a user-facing message")
func errorHasDescription() {
    let error = ADBError.binaryTooOld(found: "33.0.0", required: "34.0.0")
    #expect(error.errorDescription?.contains("33.0.0") == true)
    #expect(error.errorDescription?.contains("34.0.0") == true)
}
