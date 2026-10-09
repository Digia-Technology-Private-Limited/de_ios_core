/// Everything an out-of-process renderer needs to draw one guide — today, only the
/// React Native bridge's JS tooltip/spotlight renderer.
///
/// Handed to ``Digia/setOnGuideRenderRequest(_:)``'s callback once native has decided the
/// guide may run: the campaign exists, it targets this screen, and it cleared frequency
/// capping.
///
/// A struct rather than a parameter list on purpose. This is the whole handoff to a
/// renderer that ships on its own release train, and a renderer needing one more field must
/// not force every host of this SDK to recompile against a new arity — an added property
/// here is additive, a fourth parameter would not be.
public struct GuideRenderRequest: Sendable {
    /// The trigger as the CEP delivered it, including its resolved variables.
    public let payload: CEPTriggerPayload

    /// The id of the real presentation the delivering CEP is holding a slot for.
    ///
    /// The only thing that resolves back to it: every lifecycle report the renderer makes
    /// must carry this id through ``Digia/reportExternalGuideLifecycle(presentationId:event:)``,
    /// or the CEP's hold settles on the acceptance watchdog's timeout instead of on what
    /// the user did.
    public let presentationId: String

    /// Digia's own id for the campaign — the `campaign_id` field of every analytics event
    /// the renderer records for it.
    ///
    /// Not on ``payload``, which carries the *CEP's* id for its own campaign instance. The
    /// two are different systems' identifiers and both reach the analytics wire, so a
    /// renderer without this one would have to substitute the campaign key and quietly
    /// change what `campaign_id` means for every JS-rendered guide.
    public let campaignId: String

    /// The campaign's authored guide JSON, verbatim — `{ templateType, steps, variables }`.
    ///
    /// The renderer has no campaign store of its own, so this is where the content comes
    /// from. Passed through unparsed because this core's own guide model is a lossy
    /// projection built for Canvas rendering, and the JS renderer reads fields it drops.
    ///
    /// Nil only for a campaign that reached here with no guide JSON at all, which native
    /// routing already treats as unrenderable; a renderer seeing nil should report
    /// `dropped` rather than wait.
    public let templateConfigJson: String?

    public init(
        payload: CEPTriggerPayload,
        presentationId: String,
        campaignId: String,
        templateConfigJson: String?
    ) {
        self.payload = payload
        self.presentationId = presentationId
        self.campaignId = campaignId
        self.templateConfigJson = templateConfigJson
    }
}
