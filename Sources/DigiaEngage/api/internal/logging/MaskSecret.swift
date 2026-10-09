/// Renders `secret` safe to put in a log line: first four characters, `....`,
/// last four.
///
/// ```swift
/// maskSecret("dg_a1b2c3d4e5f9b2")  // dg_a....f9b2
/// ```
///
/// Anything shorter than twelve characters masks **fully**, to `****` — with
/// eight of them shown, a short key would be more revealed than hidden. Nil and
/// empty mask the same way, so a call site never has to check first.
///
/// Use this for every secret that reaches a log line, not just the ones that
/// look sensitive. A dev console gets pasted into support tickets and
/// screenshots, and the SDK's default verbosity outside release is `debug` — so
/// anything logged is, in practice, logged everywhere.
func maskSecret(_ secret: String?) -> String {
    guard let secret, secret.count >= 12 else { return "****" }
    return "\(secret.prefix(4))....\(secret.suffix(4))"
}
