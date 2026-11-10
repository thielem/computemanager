import Testing
@testable import GateCore
import Shared

@Test func placeholderAnswersNotImplemented() async {
    let r = await GateService().handle(.status)
    #expect(r == .failure(.notImplemented("status")))
}
