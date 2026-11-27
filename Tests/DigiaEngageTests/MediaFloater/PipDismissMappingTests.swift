import Testing
@testable import DigiaEngage

/// `FloaterDismissReason`'s shared-vocabulary mapping, pinned against Android's
/// `FloaterDismissReason.presentationReason` + `completed` and Flutter's
/// `PipDismissReason.presentationReason` + `completed`: only a media end
/// completes the showing.
@Suite("Media floater: dismiss mapping", .tags(.unit, .floater))
struct PipDismissMappingTests {

    @Test("a media end reports completed with completed true")
    func mediaEndIsCompleted() {
        // Fails if: floater_orchestrator.swift `presentationReason` maps
        // `.mediaEnd` to anything but `.completed` (Android/Flutter parity).
        #expect(FloaterDismissReason.mediaEnd.presentationReason == .completed)
        #expect(FloaterDismissReason.mediaEnd.completed == true)
        #expect(FloaterDismissReason.mediaEnd.wire == "media_end")
    }

    @Test("every other reason reports completed false")
    func othersAreNotCompleted() {
        let rest: [FloaterDismissReason] = [
            .userClose, .ctaTaken, .screenExit, .autoTimeout,
            .invalidated, .sessionEnd, .superseded, .hostTeardown,
        ]
        for reason in rest {
            #expect(reason.completed == false, "\(reason.wire) must not complete")
        }
        #expect(FloaterDismissReason.autoTimeout.presentationReason == .autoTimeout)
        #expect(FloaterDismissReason.sessionEnd.presentationReason == .autoTimeout)
        #expect(FloaterDismissReason.userClose.presentationReason == .userClose)
        #expect(FloaterDismissReason.ctaTaken.presentationReason == .ctaAction)
    }
}
