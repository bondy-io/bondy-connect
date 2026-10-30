// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module AaeCausalClosureTypes {
  /// How a replica's applied-frontier claim is formed.
  type ClaimRule =
    // the per-origin max of what it applied, raised to the peer's claim on
    // a sync without a gap
    | AdoptedMax
    // the per-origin contiguous prefix bound of what it applied, never
    // taken from a peer (`contig` in `Dot_Exactness_Gapped.thy`)
    | ContigOfApplied

  type Cfg = {
    // a complete round fails with `{frontier_gap, Origins}` when the peer's
    // claim is still ahead, and flags a catalogue rebootstrap
    gapCheck: bool,
    // compaction truncates only what every replica applied; off, it
    // truncates by local policy (`mst_retention`, the recency-filtered
    // peer-confirmed frontier)
    gatedCompaction: bool,
    // a sync applies only the per-origin contiguous closure of what is
    // applied and what the peer's tree holds
    prefixHold: bool,
    claimRule: ClaimRule,
  }
}

/// Whether `bondy_db`'s anti-entropy delivers a per-origin prefix-closed
/// set of events to each replica. `Dot_Exactness.compact_test_exact` takes
/// it as a hypothesis, and the applied-frontier vector identifies the
/// applied prefix by its per-origin max only if it holds.
///
/// Replication is pull-only (`bondy_oplog_sync_session`), and a round
/// integrates the peer's root only once every page is fetched
/// (`pull_until_complete`), so a round either integrates the peer's whole
/// tree or delivers nothing. The model has only complete rounds.
///
/// A replica's `claim` (what `get_frontier` reports) is kept apart from its
/// `applied` set (what it folded), so an over-claim can be expressed.
/// Compaction removes a per-origin prefix from the replica's tree: keys
/// order by (hlc, origin, seq) and HLCs are per-origin monotone.
module AaeCausalClosure {
  import AaeCausalClosureTypes.*
  import Ints.* from "../lib/Ints"

  const Replicas: Set[str]
  const MaxSeq: int
  /// The replica that is the cluster at the start; every other replica
  /// joins by a catalogue bootstrap before it syncs.
  const Seed: str
  const cfg: Cfg

  assume seedIsReplica = Replicas.contains(Seed)

  /// Every replica is also an origin.
  pure val Origins = Replicas

  type Event = { org: str, seq: int }

  type Replica = {
    applied: Set[Event],
    // what the local MST root reaches
    tree: Set[Event],
    claim: str -> int,
    minted: int,
    // a catalogue rebootstrap is pending
    gapFlag: bool,
    booted: bool,
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def ev(o: str, s: int): Event = { org: o, seq: s }

  pure def ofOrigin(s: Set[Event], o: str): Set[Event] = s.filter(e => e.org == o)

  /// The highest seq of `o` in `s`, or 0; it says nothing about the seqs
  /// below it.
  pure def maxSeqOf(s: Set[Event], o: str): int =
    ofOrigin(s, o).fold(0, (m, e) => max2(m, e.seq))

  pure def holdsPrefix(s: Set[Event], o: str, n: int): bool =
    1.to(n).forall(i => s.contains(ev(o, i)))

  /// The largest `n` with every seq of `o` up to `n` in `s`. The `n` that
  /// satisfy `holdsPrefix` are downward closed, so the max is the bound.
  pure def contigOf(s: Set[Event], o: str): int =
    0.to(MaxSeq).filter(n => holdsPrefix(s, o, n)).fold(0, (m, n) => max2(m, n))

  /// The events of `s` whose origin's earlier seqs are all in `s`.
  pure def contigClosure(s: Set[Event]): Set[Event] =
    s.filter(e => holdsPrefix(s, e.org, e.seq))

  pure def claimFrom(s: Set[Event]): str -> int = Origins.mapBy(o => contigOf(s, o))

  pure def pointwiseMax(a: str -> int, b: str -> int): str -> int =
    Origins.mapBy(o => max2(a.get(o), b.get(o)))

  pure def fresh(r: str): Replica = {
    applied: Set(),
    tree: Set(),
    claim: Origins.mapBy(_ => 0),
    minted: 0,
    gapFlag: false,
    booted: r == Seed,
  }

  /// The catalogue install of `peer`'s snapshot and frontier
  /// (`finalize_catalogue_bootstrap`).
  pure def bootstrapped(c: Cfg, x: Replica, peer: Replica): Replica = {
    ...x,
    applied: peer.applied,
    tree: peer.tree,
    claim: match c.claimRule {
      | AdoptedMax => peer.claim
      | ContigOfApplied => claimFrom(peer.applied)
    },
    booted: true,
  }

  pure def minted(c: Cfg, r: str, x: Replica): Replica = {
    val e = ev(r, x.minted + 1)
    val applied = x.applied.union(Set(e))
    {
      ...x,
      applied: applied,
      tree: x.tree.union(Set(e)),
      claim: match c.claimRule {
        | AdoptedMax => x.claim.set(r, e.seq)
        | ContigOfApplied => claimFrom(applied)
      },
      minted: e.seq,
    }
  }

  /// A complete round from `peer`: integrate its whole tree, then the gap
  /// check, then the claim.
  pure def synced(c: Cfg, x: Replica, peer: Replica): Replica = {
    val offered = x.applied.union(peer.tree)
    val applied = if (c.prefixHold) contigClosure(offered) else offered
    val pulled = { ...x, applied: applied, tree: x.tree.union(peer.tree) }
    match c.claimRule {
      | AdoptedMax => {
          val base = Origins.mapBy(o => max2(x.claim.get(o), maxSeqOf(applied, o)))
          if (c.gapCheck and Origins.exists(o => peer.claim.get(o) > base.get(o)))
            { ...pulled, claim: base, gapFlag: true }
          else
            { ...pulled, claim: pointwiseMax(base, peer.claim) }
        }
      // The bound stops at a hole, so a peer seq above one of the
      // replica's holes counts as a deficit.
      | ContigOfApplied => {
          val claim = claimFrom(applied)
          {
            ...pulled,
            claim: claim,
            gapFlag: c.gapCheck and Origins.exists(o => peer.claim.get(o) > claim.get(o)),
          }
        }
    }
  }

  /// Compaction below `cut`. The events stay applied; they can no longer
  /// be shipped.
  pure def compacted(x: Replica, cut: str -> int): Replica =
    { ...x, tree: x.tree.filter(e => e.seq > cut.get(e.org)) }

  /// The catalogue rebootstrap from `peer` supplies its data and frontier.
  /// The replica's own events survive in its WAL and are re-delivered after
  /// the clobber, so they are kept.
  pure def rebootstrapped(c: Cfg, r: str, x: Replica, peer: Replica): Replica = {
    val applied = peer.applied.union(ofOrigin(x.applied, r))
    {
      ...x,
      applied: applied,
      tree: peer.tree.union(ofOrigin(x.tree, r)),
      claim: match c.claimRule {
        | AdoptedMax => peer.claim.set(r, max2(peer.claim.get(r), x.claim.get(r)))
        | ContigOfApplied => claimFrom(applied)
      },
      gapFlag: false,
    }
  }

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica

  action init = all {
    replicas' = Replicas.mapBy(r => fresh(r)),
  }

  action become(r: str, x: Replica): bool = all {
    replicas' = replicas.set(r, x),
  }

  action bootstrap(r: str, p: str): bool = all {
    r != p,
    not(replicas.get(r).booted),
    replicas.get(p).booted,
    become(r, bootstrapped(cfg, replicas.get(r), replicas.get(p))),
  }

  action mint(r: str): bool = all {
    val x = replicas.get(r)
    all {
      x.booted,
      not(x.gapFlag),
      x.minted < MaxSeq,
      become(r, minted(cfg, r, x)),
    },
  }

  action sync(r: str, p: str): bool = all {
    r != p,
    replicas.get(r).booted,
    not(replicas.get(r).gapFlag),
    replicas.get(p).booted,
    become(r, synced(cfg, replicas.get(r), replicas.get(p))),
  }

  action compact(r: str, cut: str -> int): bool = all {
    cfg.gatedCompaction implies Origins.forall(o =>
      1.to(cut.get(o)).forall(j => Replicas.forall(q =>
        replicas.get(q).applied.contains(ev(o, j))))),
    become(r, compacted(replicas.get(r), cut)),
  }

  action rebootstrap(r: str, p: str): bool = all {
    r != p,
    replicas.get(r).gapFlag,
    become(r, rebootstrapped(cfg, r, replicas.get(r), replicas.get(p))),
  }

  action step = {
    nondet r = Replicas.oneOf()
    // Each choice is drawn only where it is used; drawn up front, every
    // action would be tried once per peer and per cut.
    any {
      mint(r),
      { nondet cut = Origins.setOfMaps(0.to(MaxSeq)).oneOf()
        compact(r, cut) },
      { nondet p = Replicas.oneOf()
        any { bootstrap(r, p), sync(r, p), rebootstrap(r, p) } },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val noDeadlock = enabled(step)

  val prefixClosed = Replicas.forall(r => Origins.forall(o =>
    holdsPrefix(replicas.get(r).applied, o, maxSeqOf(replicas.get(r).applied, o))))

  /// The frontier never claims an event the replica has not applied.
  val noOverClaim = Replicas.forall(r => Origins.forall(o =>
    holdsPrefix(replicas.get(r).applied, o, replicas.get(r).claim.get(o))))

  /// Two replicas that report the same frontier hold the same data. A
  /// per-origin bound, max or contiguous, is a lossy summary of the applied
  /// set; no instance checks this.
  val oracleAgrees = Replicas.forall(r => Replicas.forall(q =>
    replicas.get(r).claim == replicas.get(q).claim implies
      replicas.get(r).applied == replicas.get(q).applied))
}
