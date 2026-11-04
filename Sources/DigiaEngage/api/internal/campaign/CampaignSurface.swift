import Foundation

/// One place a campaign can occupy the screen: nudge, survey, guide, PiP
/// (floater), story floater or inline.
///
/// The SDK holds one of each in a fixed order and asks every one in turn, so
/// a question about the screen — what is on it, take this off it — is a loop
/// rather than a branch per kind. Starting is the exception: each surface
/// takes its own typed config, picked by one exhaustive switch over
/// ``CampaignConfigModel`` in ``SDKInstance/startCampaign(_:)``, so adding a
/// config subtype fails to compile until it is routed.
///
/// Mirrors Flutter's `CampaignSurface` (`campaign_surface.dart`). The one
/// structural difference: iOS cancel and timeout share a single teardown path
/// (``SDKInstance/dismissSurfaces(for:)-style`` delivery-identity matching),
/// so there is one `dismiss` here instead of Flutter's `dismissCampaign` plus
/// `dismissTimedOut`.
@MainActor
protocol CampaignSurface: AnyObject {
    /// What this surface holds that has not settled yet, including a campaign
    /// routed but still waiting to draw.
    var occupants: [SurfaceOccupant] { get }

    /// Takes what this surface holds off the screen as superseded, when
    /// `occupant`'s kind is one it shows. Ignores any other kind.
    func supersede(_ occupant: SurfaceOccupant)

    /// Takes the delivery `payload` triggered off this surface; the caller then
    /// settles the presentation as cancelled or timed out. Matches by delivery
    /// identity, so a newer delivery of the same campaign stays, and emits
    /// nothing: the watchdog already settled or reported it.
    func dismiss(_ payload: CEPTriggerPayload)
}
