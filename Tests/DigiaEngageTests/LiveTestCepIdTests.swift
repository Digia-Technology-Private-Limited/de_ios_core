import Foundation
import Testing
@testable import DigiaEngage

@Suite("LiveTestCepId")
struct LiveTestCepIdTests {
    @Test("liveTestCepId is prefixed and recognised by isLiveTestCepId")
    func prefixedAndRecognised() {
        let id = liveTestCepId("test_123")
        #expect(isLiveTestCepId(id))
    }

    @Test("an organic cepCampaignId is not recognised as a live test")
    func organicIdIsNotRecognised() {
        #expect(!isLiveTestCepId("some_other_id"))
    }
}
