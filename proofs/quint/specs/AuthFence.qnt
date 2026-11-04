// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module AuthFenceTypes {
  type Policy = Refuse | Proceed

  type Cfg = { clustered: bool, policy: Policy, commitBumps: bool }
}

/// The authentication freshness fence (`bondy_auth:security_fence/0` over
/// `bondy_db:ensure_fresh/2`): a node authenticates only while its view of
/// the security tables was confirmed within `MaxLag`.
///
/// A confirmation stamps the node's view with the current time:
///   - a sync, a successful pull from a peer (`bondy_oplog_sync_session`),
///     which merges the peer's view into the node's;
///   - an isolated scheduler round, one with no peer
///     (`maybe_bump_ae_isolated/1`). A node with clustering off always
///     confirms; a clustered one follows `db.oplog.aae.fence.on_isolation`:
///     `Refuse` never confirms, `Proceed` always does;
///   - with `cfg.commitBumps`, an applier commit of local writes
///     (`bump_ae_targets/1` in `bondy_oplog_applier:commit_now/1`).
///
/// `fenceSafe`: once a revocation made at `Revoker` is older than `MaxLag`, a
/// node whose fence passes has seen it.
module AuthFence {
  import AuthFenceTypes.*

  const Nodes: Set[str]
  const Revoker: str
  const MaxLag: int
  const MaxTime: int
  const cfg: Cfg

  assume revokerIsNode = Nodes.contains(Revoker)

  type Revocation = NotRevoked | RevokedAt(int)

  type View = { confirmedAt: int, sawRevocation: bool }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def confirm(v: View, now: int): View = { ...v, confirmedAt: now }

  pure def merge(v: View, peer: View, now: int): View =
    { confirmedAt: now, sawRevocation: v.sawRevocation or peer.sawRevocation }

  pure def passes(v: View, now: int): bool = now - v.confirmedAt <= MaxLag

  // ===========================================================================
  // State machine
  // ===========================================================================

  var now: int
  var linked: bool
  var revocation: Revocation
  var views: str -> View

  action init = all {
    now' = 0,
    linked' = true,
    revocation' = NotRevoked,
    views' = Nodes.mapBy(_ => { confirmedAt: 0, sawRevocation: false }),
  }

  action tick = all {
    now < MaxTime,
    now' = now + 1,
    linked' = linked, revocation' = revocation, views' = views,
  }

  action revoke = all {
    revocation == NotRevoked,
    now > 0,
    revocation' = RevokedAt(now),
    views' = views.setBy(Revoker, v => { ...v, sawRevocation: true }),
    now' = now, linked' = linked,
  }

  action partition = all {
    linked,
    cfg.clustered,
    linked' = false,
    now' = now, revocation' = revocation, views' = views,
  }

  action heal = all {
    not(linked),
    linked' = true,
    now' = now, revocation' = revocation, views' = views,
  }

  /// `n`'s view changes; nothing else does.
  action setView(n: str, v: View): bool = all {
    views' = views.set(n, v),
    now' = now, linked' = linked, revocation' = revocation,
  }

  action sync(n: str, m: str): bool = all {
    n != m,
    linked,
    setView(n, merge(views.get(n), views.get(m), now)),
  }

  action isolated(n: str): bool = all {
    not(linked) or Nodes == Set(n),
    not(cfg.clustered) or cfg.policy == Proceed,
    setView(n, confirm(views.get(n), now)),
  }

  action localCommit(n: str): bool = all {
    cfg.commitBumps,
    setView(n, confirm(views.get(n), now)),
  }

  action step = {
    nondet n = Nodes.oneOf()
    nondet m = Nodes.oneOf()
    any {
      tick, revoke, partition, heal,
      sync(n, m), isolated(n), localCommit(n),
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val fenceSafe = match revocation {
    | NotRevoked => true
    | RevokedAt(t) =>
        now - t > MaxLag implies
          Nodes.forall(n => passes(views.get(n), now) implies views.get(n).sawRevocation)
  }
}
