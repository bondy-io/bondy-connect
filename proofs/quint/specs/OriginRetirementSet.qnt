// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module OriginRetirementSetTypes {
  /// The precondition a replica applies before dropping a retired origin's
  /// frontier entry.
  type ReapGuard =
    // retirement alone
    | RetiredHere
    // every member's claim on the origin equals this replica's, read fresh
    | EveryMemberLevel
    // every member has the origin in its retirement set
    | EveryMemberRetired

  type ReapPolicy =
    // the frontier is never reaped, and nothing retires an origin
    | NoReap
    | ReapWhen(ReapGuard)

  type Cfg = {
    reap: ReapPolicy,
    // a replica refuses events from origins it has retired
    // (`bondy_oplog_origin_bans`)
    banEnforced: bool,
    // a replica may reclaim events from its log
    compaction: bool,
    // a retirement is persisted the moment it is enforced; otherwise it is
    // enforced and never persisted, which is what "insert into the table,
    // then write the file" admits when every write fails
    retirementDurable: bool,
    // once a retirement exists, no member departs and nobody rejoins
    stableMembership: bool,
  }
}

/// Frontier reaping driven by a replicated retirement set rather than by
/// membership.
///
/// Membership is reversible: `bondy_oplog_origin:load_or_create/1` reuses
/// the persisted id, so a departed node returns minting under the origin
/// the survivors reaped, and they skip its new events. The reap needs a
/// decision that every replica agrees on and that a node coming back cannot
/// undo. An operator decommissioning a node retires its origin in a
/// grow-only set, replicated by union, which is both.
///
/// The bet this module checks: a retired origin is banned, so no replica
/// accepts another event from it, so skipping its deficit leaves nothing to
/// be blind to. With `banEnforced` off the bet must fail.
///
/// Without compaction every event can flow by page sync, so the frontier is
/// a pure oracle and the reap needs no guard. With it, an event reclaimed
/// from every holder's log moves only by a catalogue rebootstrap, which only
/// a frontier deficit flags, so a claim dropped too early is data a replica
/// can never obtain again. That is what tells the guards apart.
///
/// Origins are replicas: each replica mints under its own origin. Every
/// action changes one replica's state.
module OriginRetirementSet {
  import OriginRetirementSetTypes.*
  import Ints.* from "../lib/Ints"

  const Replicas: Set[str]
  const MaxSeq: int
  const cfg: Cfg

  pure val Origins = Replicas
  pure val Seqs = 1.to(MaxSeq)

  type Event = { org: str, seq: int }

  pure val Events = Origins.map(o => Seqs.map(s => { org: o, seq: s })).flatten()

  type Replica = {
    applied: Set[Event],
    // reclaimed from the log but still in the projection: a catalogue
    // rebootstrap ships them and page sync does not.
    compacted: Set[Event],
    // the applied-frontier vector.
    claim: str -> int,
    // the seq counter of this replica's origin.
    minted: int,
    member: bool,
    // this replica's view of the replicated retirement set.
    retired: Set[str],
    // a frontier deficit flagged a catalogue rebootstrap.
    gap: bool,
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def top(s: Set[Event], o: str): int =
    s.filter(e => e.org == o).fold(0, (m, e) => max2(m, e.seq))

  pure def admissible(x: Replica, e: Event): bool =
    not(cfg.banEnforced and x.retired.contains(e.org))

  /// `x`'s claim on `o` raised to `n`. A retired origin's claim never
  /// rises: max-merging it while the ban filters the events would leave
  /// the vector asserting events `x` refused.
  pure def raise(x: Replica, o: str, n: int): int =
    if (x.retired.contains(o)) x.claim.get(o) else max2(x.claim.get(o), n)

  /// Whether `x` reads a deficit against `y` on `o`. The check skips a
  /// retired origin; every replica converges on the same set, so the skip
  /// is symmetric.
  pure def behind(x: Replica, y: Replica, o: str): bool =
    not(x.retired.contains(o)) and y.claim.get(o) > x.claim.get(o)

  pure def taken(x: Replica, shipped: Set[Event]): Set[Event] =
    x.applied.union(shipped.filter(e => admissible(x, e)))

  /// `x` holding `applied` and adopting `y`'s vector. The claim also rises
  /// from what `x` holds (`batch_frontier/1` -> `merge_frontier/2`): a peer
  /// that has reaped advertises less than it just shipped.
  pure def adopted(x: Replica, applied: Set[Event], y: Replica): Replica = {
    ...x,
    applied: applied,
    claim: Origins.mapBy(o => raise(x, o, max2(top(applied, o), y.claim.get(o)))),
    gap: false,
  }

  /// One complete AAE round from `y`. Adoption is gated on the gap check
  /// (`maybe_frontier_gap/5` makes a residual deficit a session error, so
  /// `maybe_record/6` never adopts): adopting through a deficit is the
  /// over-claim the check exists to prevent.
  pure def synced(x: Replica, y: Replica): Replica = {
    val applied = taken(x, y.applied.exclude(y.compacted))
    val folded = { ...x, applied: applied, claim: Origins.mapBy(o => raise(x, o, top(applied, o))) }
    if (Origins.exists(o => behind(folded, y, o))) { ...folded, gap: true } else adopted(x, applied, y)
  }

  /// A catalogue rebootstrap: `y` ships its projection, which is complete
  /// whatever its log has reclaimed, and the finalize adopts its frontier.
  pure def rebootstrapped(x: Replica, y: Replica): Replica = adopted(x, taken(x, y.applied), y)

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica

  def members: Set[str] = Replicas.filter(q => replicas.get(q).member)

  val noRetirementYet = Replicas.forall(q => replicas.get(q).retired == Set())

  /// Whether the reap policy lets `r` drop its entry for `o`.
  def licensed(r: str, o: str): bool = match cfg.reap {
    | NoReap => false
    | ReapWhen(g) => match g {
        | RetiredHere => true
        | EveryMemberLevel => members.forall(q => replicas.get(q).claim.get(o) == replicas.get(r).claim.get(o))
        | EveryMemberRetired => members.forall(q => replicas.get(q).retired.contains(o))
      }
  }

  action init = replicas' = Replicas.mapBy(_ => {
    applied: Set(),
    compacted: Set(),
    claim: Origins.mapBy(_ => 0),
    minted: 0,
    member: true,
    retired: Set(),
    gap: false,
  })

  action become(r: str, x: Replica): bool = replicas' = replicas.set(r, x)

  action mint(r: str): bool = {
    val x = replicas.get(r)
    val s = x.minted + 1
    all {
      x.member, not(x.gap), x.minted < MaxSeq,
      become(r, {
        ...x,
        applied: x.applied.union(Set({ org: r, seq: s })),
        claim: x.claim.set(r, s),
        minted: s,
      }),
    }
  }

  /// `mst_retention` truncates by local policy and the durable
  /// peer-confirmed frontier is recency-filtered, so a replica can reclaim
  /// an event a peer has not seen.
  action compact(r: str, e: Event): bool = {
    val x = replicas.get(r)
    all {
      cfg.compaction,
      x.applied.exclude(x.compacted).contains(e),
      become(r, { ...x, compacted: x.compacted.union(Set(e)) }),
    }
  }

  action depart(r: str): bool = all {
    replicas.get(r).member,
    members.size() > 1,
    cfg.stableMembership implies noRetirementYet,
    become(r, { ...replicas.get(r), member: false }),
  }

  /// A node returns with the disk it left with, so it resumes minting
  /// under its persisted origin: the action every membership-derived reap
  /// fails on.
  action join(r: str): bool = all {
    not(cfg.stableMembership),
    not(replicas.get(r).member),
    become(r, { ...replicas.get(r), member: true }),
  }

  /// The operator decommissions departed node `o`, at replica `r`.
  action retire(r: str, o: str): bool = {
    val x = replicas.get(r)
    all {
      cfg.reap != NoReap,
      x.member,
      not(replicas.get(o).member),
      not(x.retired.contains(o)),
      become(r, { ...x, retired: x.retired.union(Set(o)) }),
    }
  }

  /// Replication of the retirement set: `r` pulls a member's set over the
  /// sync transport and unions it in.
  action propagate(r: str, p: str): bool = {
    val x = replicas.get(r)
    val y = replicas.get(p)
    all {
      r != p, x.member, y.member,
      not(y.retired.subseteq(x.retired)),
      become(r, { ...x, retired: x.retired.union(y.retired) }),
    }
  }

  action sync(r: str, p: str): bool = all {
    r != p, replicas.get(r).member, replicas.get(p).member, not(replicas.get(r).gap),
    become(r, synced(replicas.get(r), replicas.get(p))),
  }

  /// Drop the frontier entry of retired origin `o`.
  action reap(r: str, o: str): bool = {
    val x = replicas.get(r)
    all {
      x.member,
      x.retired.contains(o),
      x.claim.get(o) > 0,
      licensed(r, o),
      become(r, { ...x, claim: x.claim.set(o, 0) }),
    }
  }

  action rebootstrap(r: str, p: str): bool = all {
    replicas.get(r).gap,
    r != p, replicas.get(p).member,
    become(r, rebootstrapped(replicas.get(r), replicas.get(p))),
  }

  /// A restart keeps only what was persisted. `applied`, `claim` and the
  /// seq counter survive by other means (compaction checkpoint, MST, WAL
  /// replay), so the retirement set is all a restart can take away: all of
  /// it when none was persisted, nothing when all of it was.
  action restart(r: str): bool = all {
    not(cfg.retirementDurable),
    replicas.get(r).retired != Set(),
    become(r, { ...replicas.get(r), retired: Set() }),
  }

  action step = {
    nondet r = Replicas.oneOf()
    any {
      mint(r),
      restart(r),
      { nondet e = Events.oneOf()
        compact(r, e) },
      depart(r),
      join(r),
      { nondet p = Replicas.oneOf()
        any { retire(r, p), reap(r, p), rebootstrap(r, p), propagate(r, p), sync(r, p) } },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val compactedWithinApplied = Replicas.forall(r => replicas.get(r).compacted.subseteq(replicas.get(r).applied))

  val noOverClaim = Replicas.forall(r => Origins.forall(o =>
    1.to(replicas.get(r).claim.get(o)).forall(s => replicas.get(r).applied.contains({ org: o, seq: s }))))

  /// No replica is told it is missing data it already holds.
  val noSpuriousGap = members.forall(r => members.forall(p => r != p implies Origins.forall(o =>
    behind(replicas.get(r), replicas.get(p), o)
      implies top(replicas.get(r).applied, o) < top(replicas.get(p).applied, o))))

  /// What the skip must earn: once a member has retired and reaped an
  /// origin, it would refuse every event of it that a member holds.
  val retiredSkipIsSafe = members.forall(r => members.forall(p => Origins.forall(o => {
    val x = replicas.get(r)
    (x.retired.contains(o) and x.claim.get(o) == 0)
      implies replicas.get(p).applied.forall(e => e.org == o implies not(admissible(x, e)))
  })))

  /// A positive claim is backed by an event at least that high.
  val noDataLoss = Replicas.forall(r => Origins.forall(o => {
    val x = replicas.get(r)
    x.claim.get(o) > 0 implies top(x.applied, o) >= x.claim.get(o)
  }))

  val safety = and { compactedWithinApplied, noOverClaim, noDataLoss, noSpuriousGap, retiredSkipIsSafe }

  /// `e` is stuck at `q` when every route to it is closed: `q` would accept
  /// it, some member holds it, every holder has reclaimed it from its log
  /// so page sync cannot ship it, and no member's frontier is ahead of
  /// `q`'s on its origin, so no deficit will flag the rebootstrap that
  /// could. Dropping a claim closes that last route, which is why the reap
  /// needs a guard.
  def stuck(q: str, e: Event): bool = {
    val x = replicas.get(q)
    val holders = members.filter(p => replicas.get(p).applied.contains(e))
    and {
      x.member,
      not(x.applied.contains(e)),
      admissible(x, e),
      holders != Set(),
      holders.forall(p => replicas.get(p).compacted.contains(e)),
      members.forall(p => not(behind(x, replicas.get(p), e.org))),
    }
  }

  val noStuckEvent = Replicas.forall(q => Events.forall(e => not(stuck(q, e))))

  /// A reachability probe, stated as an invariant so that a violation is
  /// the evidence: a run in which every member, more than one, dropped an
  /// entry for an origin whose events it held. A rule that holds this
  /// cannot clear the entry cluster-wide.
  val notAllMembersReaped = not(Origins.exists(o => and {
    members.size() > 1,
    members.forall(r => {
      val x = replicas.get(r)
      and { x.retired.contains(o), x.claim.get(o) == 0, x.applied.contains({ org: o, seq: 1 }) }
    }),
  }))
}
