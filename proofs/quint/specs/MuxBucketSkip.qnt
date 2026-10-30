// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module MuxBucketSkipTypes {
  /// How the fold forms the applied-frontier claim.
  type ClaimRule =
    // the per-origin max of each group that folded, merged per group
    // (`merge_frontier(Id, batch_frontier(Pairs))`)
    | BatchMax
    // the per-origin contiguous prefix bound of what is applied
    | ContigOfApplied

  /// When a catalogue bootstrap adopts the peer's frontier. A claim derived
  /// from the installed cells is not an option: a shipped cell is
  /// `{Bucket, Key, Frame}`, with no origin and no seq.
  type Adoption =
    // `finalize_catalogue_bootstrap/5` max-merges it whatever the install
    // skipped
    | Unconditional
    // only when the install skipped no cell it received; otherwise the
    // bootstrap completes and adopts nothing
    | IfNothingSkipped

  type Cfg = {
    // an unroutable event is a per-origin contiguity hole in
    // `partition_contiguous/4`, so nothing above it folds and `Held` keeps
    // the replay cursor
    skipIsHole: bool,
    claim: ClaimRule,
    adoption: Adoption,
    // the responder refuses a catalogue snapshot until its own declared
    // tables have registered
    serveGate: bool,
    // a replica syncs, folds and installs only once its own declared
    // tables have registered
    gateOnRegistration: bool,
    // `maybe_frontier_gap/5` raises a deficit even when this replica cannot
    // route something the peer would ship; off, the verdict is withheld
    gapVerdict: bool,
  }

  type Stage =
    // never bootstrapped
    | Joining
    | Serving
    // a frontier gap flagged a catalogue rebootstrap
    | GapPending
}

/// Whether the applied-frontier claim can report an event whose cell was
/// never installed into the projection because its bucket had no
/// cell-apply context on this replica.
///
/// A shard instance multiplexes several tables onto one oplog, each tagged
/// with a bucket. It is founded by the first table opened on it
/// (`bondy_db:start_or_join_shard_instance`), and siblings register later
/// (`bondy_oplog_instance:register_table/4`), so the routable buckets grow
/// while the instance already serves. A restart drops them back to the
/// founding bucket, while the projection, the MST and the frontier
/// checkpoint survive.
///
/// Two channels over-claim. The fold (`apply_cell_pairs_mux/5`) skips a
/// bucket group that does not resolve and merges the frontier per surviving
/// group; with `Held = 0` the replay cursor then advances past the skipped
/// cells. The bootstrap adopts the peer's frontier after an install that
/// skipped what it could not route, and a peer still opening its tables
/// ships from its own registry (`build_targets/2`) while answering
/// `get_frontier` in full.
///
/// Origins are replicas, and every action changes one replica's state.
/// Compaction, the MST, HLCs and network failure are not modelled.
module MuxBucketSkip {
  import MuxBucketSkipTypes.*
  import Ints.* from "../lib/Ints"

  const Replicas: Set[str]
  const MaxSeq: int
  /// The bucket every shard instance is founded with.
  const Founding: str
  /// The replica that is the cluster at the start.
  const Seed: str
  /// The buckets each replica's build declares for the shard: the tables
  /// its catalogue opens. A bucket a build has no table for never
  /// registers there.
  const Declared: str -> Set[str]
  const cfg: Cfg

  assume seedIsReplica = Replicas.contains(Seed)
  assume everyReplicaDeclares = Declared.keys() == Replicas
  assume foundingDeclared = Replicas.forall(r => Declared.get(r).contains(Founding))

  pure val Origins = Replicas
  pure val Seqs = 1.to(MaxSeq)
  pure val Buckets = Replicas.map(r => Declared.get(r)).flatten()

  type Event = { org: str, seq: int, bucket: str }

  type Replica = {
    // the cells materialised in the projection.
    applied: Set[Event],
    // the items reachable from the local MST root.
    tree: Set[Event],
    // the events a replay has diffed past; empty is
    // `last_replayed_root = undefined`.
    cursor: Set[Event],
    // the applied-frontier vector `get_frontier` reports.
    claim: str -> int,
    // the buckets with a cell-apply context.
    reg: Set[str],
    // the seq counter of this replica's origin.
    minted: int,
    stage: Stage,
    // one restart per replica: a rolling restart touches each node once.
    restarted: bool,
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def holds(s: Set[Event], o: str, j: int): bool = s.exists(e => e.org == o and e.seq == j)

  pure def top(s: Set[Event], o: str): int =
    s.filter(e => e.org == o).fold(0, (m, e) => max2(m, e.seq))

  pure def contig(s: Set[Event], o: str): int =
    Seqs.filter(n => 1.to(n).forall(i => holds(s, o, i))).fold(0, (m, n) => max2(m, n))

  pure def ready(r: str, x: Replica): bool = x.reg == Declared.get(r)

  pure def gated(r: str, x: Replica): bool = cfg.gateOnRegistration implies ready(r, x)

  /// The fold of what `r`'s replay presents. `partition_contiguous/3` holds
  /// a remote event above a missing seq of its origin; the remainder is
  /// grouped by bucket and a group with no context is dropped with a
  /// success return. The cursor advances unless something was parked.
  pure def replayed(r: str, x: Replica): Replica = {
    val presented = x.tree.exclude(x.cursor)
    val routable = presented.filter(e => e.org == r or x.reg.contains(e.bucket))
    val visible = if (cfg.skipIsHole) routable else presented
    val held = presented.filter(e => e.org != r and
      (x.claim.get(e.org) + 1).to(e.seq - 1).exists(i => not(holds(visible, e.org, i))))
    val folded = visible.exclude(held).filter(e => x.reg.contains(e.bucket))
    val parked = if (cfg.skipIsHole) presented.exclude(folded) else held
    val applied = x.applied.union(folded)
    {
      ...x,
      applied: applied,
      claim: match cfg.claim {
        | BatchMax => Origins.mapBy(o => max2(x.claim.get(o), top(folded, o)))
        | ContigOfApplied => Origins.mapBy(o => contig(applied, o))
      },
      cursor: if (parked == Set()) x.tree else x.cursor,
    }
  }

  /// One complete anti-entropy round from `y`: the MST merge and the
  /// frontier-gap check. The fold is `replay`, a separate step because the
  /// session casts `replay_cell_events` and does not wait for it.
  pure def merged(x: Replica, y: Replica): Replica = {
    val ahead = Origins.exists(o => y.claim.get(o) > x.claim.get(o))
    val unroutable = y.applied.exists(e => y.reg.contains(e.bucket) and not(x.reg.contains(e.bucket)))
    {
      ...x,
      tree: x.tree.union(y.tree),
      stage: if (ahead and (cfg.gapVerdict or not(unroutable))) GapPending else x.stage,
    }
  }

  /// A catalogue bootstrap of `r` from `y`. The install is additive
  /// (`install_one_cell` keeps the higher HLC) and skips a bucket with no
  /// context here; the re-derive resets the replay cursor. `r`'s own
  /// events survive in its WAL and are re-delivered by the drain.
  pure def bootstrapped(r: str, x: Replica, y: Replica): Replica = {
    val shipped = y.applied.filter(e => y.reg.contains(e.bucket))
    val routed = shipped.filter(e => x.reg.contains(e.bucket))
    val adopts = match cfg.adoption {
      | Unconditional => true
      | IfNothingSkipped => routed == shipped
    }
    {
      ...x,
      applied: x.applied.union(routed),
      tree: y.tree.union(x.tree.filter(e => e.org == r)),
      claim: if (adopts) Origins.mapBy(o => max2(x.claim.get(o), y.claim.get(o))) else x.claim,
      cursor: Set(),
      stage: Serving,
    }
  }

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica

  action init = replicas' = Replicas.mapBy(r => {
    applied: Set(),
    tree: Set(),
    cursor: Set(),
    claim: Origins.mapBy(_ => 0),
    reg: Set(Founding),
    minted: 0,
    stage: if (r == Seed) Serving else Joining,
    restarted: false,
  })

  action become(r: str, x: Replica): bool = replicas' = replicas.set(r, x)

  /// A sibling table opens and registers its bucket. A context is never
  /// withdrawn while the instance lives.
  action register(r: str, b: str): bool = {
    val x = replicas.get(r)
    all {
      Declared.get(r).contains(b),
      not(x.reg.contains(b)),
      become(r, { ...x, reg: x.reg.union(Set(b)) }),
    }
  }

  /// The routing directory drops back to the founding bucket and refills as
  /// the catalogue reopens the tables; the frontier is restored in full by
  /// `boot_frontier/2`, before any table registers.
  action restart(r: str): bool = {
    val x = replicas.get(r)
    all {
      not(x.restarted),
      ready(r, x),
      become(r, {
        ...x,
        reg: Set(Founding),
        stage: if (x.stage == GapPending) Serving else x.stage,
        restarted: true,
      }),
    }
  }

  /// A local write. Its table is open, so its bucket is registered, and it
  /// folds on the WAL drain, never held.
  action mint(r: str, b: str): bool = {
    val x = replicas.get(r)
    val e = { org: r, seq: x.minted + 1, bucket: b }
    val applied = x.applied.union(Set(e))
    all {
      x.stage == Serving,
      x.minted < MaxSeq,
      x.reg.contains(b),
      become(r, {
        ...x,
        applied: applied,
        tree: x.tree.union(Set(e)),
        claim: match cfg.claim {
          | BatchMax => x.claim.set(r, e.seq)
          | ContigOfApplied => Origins.mapBy(o => contig(applied, o))
        },
        minted: e.seq,
      }),
    }
  }

  action sync(r: str, p: str): bool = all {
    r != p,
    replicas.get(r).stage == Serving,
    replicas.get(p).stage != Joining,
    gated(r, replicas.get(r)),
    become(r, merged(replicas.get(r), replicas.get(p))),
  }

  /// Both replay paths wait for the same gate as the sync plane: the WAL
  /// drain defers while `drain_gate = gated`, and the scheduler dispatches
  /// no round to a non-serviceable instance.
  action replay(r: str): bool = {
    val x = replicas.get(r)
    all {
      x.stage != Joining,
      gated(r, x),
      x.tree.exclude(x.cursor) != Set(),
      become(r, replayed(r, x)),
    }
  }

  action bootstrap(r: str, p: str): bool = all {
    r != p,
    replicas.get(r).stage != Serving,
    replicas.get(p).stage != Joining,
    gated(r, replicas.get(r)),
    cfg.serveGate implies ready(p, replicas.get(p)),
    become(r, bootstrapped(r, replicas.get(r), replicas.get(p))),
  }

  action step = {
    nondet r = Replicas.oneOf()
    any {
      restart(r),
      replay(r),
      { nondet b = Buckets.oneOf()
        any { register(r, b), mint(r, b) } },
      { nondet p = Replicas.oneOf()
        any { sync(r, p), bootstrap(r, p) } },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// The oracle contract: `get_frontier` and the `Instances DIVERGED` panel
  /// are sound only if the claim reports no event the replica did not
  /// materialise.
  val noOverClaim = Replicas.forall(r => Origins.forall(o =>
    1.to(replicas.get(r).claim.get(o)).forall(j => holds(replicas.get(r).applied, o, j))))

  /// The loss itself, stated without the frontier: a routable event the
  /// replay diffed past without applying is never presented again.
  val noStrandedCell = Replicas.forall(r => {
    val x = replicas.get(r)
    x.cursor.exclude(x.applied).forall(e => not(x.reg.contains(e.bucket)))
  })

  val safety = noOverClaim and noStrandedCell

  /// Infinitely often, every replica holds every event some replica applied
  /// whose bucket it can route. Quantified over what some replica applied,
  /// not over a replica's own tree, so that a replica that never receives
  /// anything fails it.
  temporal converges = always(eventually(Replicas.forall(r => Replicas.forall(q =>
    replicas.get(q).applied.forall(e => replicas.get(r).reg.contains(e.bucket) implies replicas.get(r).applied.contains(e))))))

  /// Fairness is per pair: the scheduler rotates peers, and a replica that
  /// may forever pick one peer starves the events only another holds.
  temporal fairness = and {
    Replicas.forall(r => Buckets.forall(b => weakFair(register(r, b), replicas))),
    Replicas.forall(r => Replicas.forall(p => weakFair(sync(r, p), replicas) and weakFair(bootstrap(r, p), replicas))),
    Replicas.forall(r => weakFair(replay(r), replicas)),
  }

  temporal live = fairness implies converges
}
