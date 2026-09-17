/// The one seam a future background-delivery extension plugs into.
///
/// This client is foreground-only: it has no push entitlement
/// (`App/ParanoID/ParanoID.entitlements` carries no `aps-environment`), no
/// `BGAppRefresh` and no PushKit, so nothing wakes the lanes but the
/// application becoming active (`docs/clients/ios/README.md`). The hook exists
/// so that the wake-up path has exactly one named entry: whatever delivers a
/// wake later calls `wake()`, and nothing else in the realtime code has to
/// change for it.
///
/// It carries no payload by construction. A wake is a request to run a cycle,
/// never a message, never authority and never anything the state is derived
/// from: everything the client knows still comes from the core over the
/// authenticated transport. A hook that tried to hand data in would have
/// nowhere to put it.
public protocol PushHook: Sendable {
    /// Asks the realtime loop to run a cycle now, from outside the lanes.
    ///
    /// It must return immediately and must never block: it is called from the
    /// state owner, which never waits for anything.
    func wake()
}

/// The hook this client ships: it does nothing.
///
/// It is what `StateOwner` installs by default, and it is the honest
/// description of today's client — a wake can only come from the foreground
/// lifecycle, so there is nothing for a hook to do.
public struct NoPushHook: PushHook {
    public init() {}

    public func wake() {}
}
