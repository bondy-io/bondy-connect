// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module ConfirmedCompactionTypes {
  /// How a replica folds remote events and what its durable frontier is.
  type Backend =
    // a separate replay folds them, and the durable frontier is the
    // checkpointed one
    | Applier
    // a round folds them inline, and the durable frontier is the applied
    // one (a fused instance is ETS only,
    // `bondy_db:assert_fused_requires_ephemeral/2`)
    | Fused
    // as `Fused`, but a round may hold back what it merged and a later
    // replay fold it (`fused_replay_diff/3`); holding the whole round
    // over-approximates the per-event hold
    | FusedHolding

  /// Whose recorded frontier bounds compaction.
  type WitnessRule =
    // every member's, until the member is retired (`member_vvs/2`)
    | EveryMember
    // only rows a round has refreshed within the timeout
    | FreshMembers

  /// What the watermark door drops after a merge (`watermark_door/2`).
  type DoorRule =
    // the applied key prefix at or below the watermark that every witness
    // confirms, as recorded before the round
    | DropsConfirmed
    | DropsNothing
    // the applied keys at or below the watermark whether confirmed or not;
    // a compaction cycle below the watermark then truncates at it
    | DropsApplied

  /// The rebuild a cycle turns to when its walk meets a lost page
  /// (`rebuild_frontier/2`).
  type HealRule =
    | NoHeal
    | Ungated
    // every member's recorded frontier must cover the replica's applied one
    | WhenMembersCover

  type Cfg = {
    backend: Backend,
    witnesses: WitnessRule,
    door: DoorRule,
    // a truncation point stops strictly below the first local key the
    // replica has not applied (`capped_truncation_point/2`)
    capAtUnapplied: bool,
    // a walk that meets a lost page judges only the readable keys, where the
    // code truncates nothing
    walkLost: bool,
    heal: HealRule,
    // the rebuild stops below the first readable key not applied, as
    // compaction does
    healCap: bool,
  }
}

/// Compaction by peer confirmation: what a replica may truncate from its
/// MST once its members have reported what they hold, and whether every
/// member still receives every event.
///
/// A round is a pull: `r` reads `p`'s durable frontier (`get_frontier`),
/// merges `p`'s tree, records that frontier against `p`
/// (`record_sync_complete/3`), and reports its own to `p`
/// (`confirm_frontier`). A witness confirms a key whose seq is at or below
/// its entry for the key's origin (`bondy_oplog_event:covered/2`), and
/// compaction truncates up to the largest key every key at or below which
/// every witness confirms (`compute_frontier_for/2`).
///
/// A lost page keeps its keys under the root, but nothing can read them:
/// the replica cannot fold them and its responder refuses every pull
/// (`root_unservable`), so what it applied reaches a peer only by catalogue
/// rebootstrap. The frontier walk stops at a lost page.
///
/// Keys carry their HLC and order by (hlc, origin, seq), the MST's term
/// order. All replicas are members from the start; rounds are atomic and
/// every report arrives. No crash, `mst_retention`, origin retirement or
/// rebootstrap from a servable peer.
module ConfirmedCompaction {
  import ConfirmedCompactionTypes.*
  import Ints.* from "../lib/Ints"

  /// Replica ids, also the origins; positive, since the bottom key uses 0.
  const Replicas: Set[int]
  const MaxSeq: int
  /// How far past what it has seen a replica's clock may run at a mint.
  const Skew: int
  const MaxCuts: int
  const MaxRetire: int
  /// Pages a behaviour may lose, one key each.
  const MaxLost: int
  const cfg: Cfg

  assume positiveIds = Replicas.forall(r => r > 0)

  pure val Origins = Replicas

  type Event = { hlc: int, org: int, seq: int }
  type Frontier = int -> int

  /// The key below every event: the watermark before any compaction.
  pure val Bottom = { hlc: 0, org: 0, seq: 0 }

  type Replica = {
    // the items under the local root.
    tree: Set[Event],
    // the events folded into the projection.
    applied: Set[Event],
    // the checkpointed frontier; read only on `Applier`.
    checkpoint: Frontier,
    // the compaction watermark key.
    wm: Event,
    // each peer's frontier as last recorded.
    rows: int -> Frontier,
    // peers whose row no round has refreshed within the timeout.
    stale: Set[int],
    // keys of `tree` on a lost page.
    lost: Set[Event],
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def below(e: Event, f: Event): bool =
    e.hlc < f.hlc or (e.hlc == f.hlc and (e.org < f.org or (e.org == f.org and e.seq <= f.seq)))

  pure def under(e: Event, f: Event): bool = below(e, f) and e != f

  pure def maxKey(s: Set[Event]): Event = s.fold(Bottom, (m, e) => if (below(m, e)) e else m)

  pure def has(s: Set[Event], o: int, j: int): bool = s.exists(e => e.org == o and e.seq == j)

  /// What `get_frontier` reports: the per-origin max.
  pure def frontier(s: Set[Event]): Frontier =
    Origins.mapBy(o => s.filter(e => e.org == o).fold(0, (m, e) => max2(m, e.seq)))

  /// The prefix hold (`AaeCausalClosure`): a fold materialises only the
  /// per-origin contiguous closure.
  pure def closure(s: Set[Event]): Set[Event] = s.filter(e => 1.to(e.seq).forall(i => has(s, e.org, i)))

  pure def readable(x: Replica): Set[Event] = x.tree.exclude(x.lost)

  pure def unapplied(x: Replica): Set[Event] = readable(x).exclude(x.applied)

  pure def durable(x: Replica): Frontier = match cfg.backend {
    | Applier => x.checkpoint
    | Fused => frontier(x.applied)
    | FusedHolding => frontier(x.applied)
  }

  pure def folds(b: Backend): bool = b != Applier

  /// The frontier `r` holds for witness `q`: its own durable one, or `q`'s
  /// recorded row.
  pure def witnessed(r: int, x: Replica, q: int): Frontier = if (q == r) durable(x) else x.rows.get(q)

  pure def confirmedByAll(r: int, x: Replica, ws: Set[int], e: Event): bool =
    ws.forall(q => e.seq <= witnessed(r, x, q).get(e.org))

  /// Whether the frontier walk over `t` meets a lost key before the first
  /// key some witness has not confirmed (`bondy_mst:fold/4` with
  /// `{missing, throw}`).
  pure def stops(r: int, x: Replica, ws: Set[int], t: Set[Event]): bool = {
    val open = t.exclude(x.lost).filter(h => not(confirmedByAll(r, x, ws, h)))
    not(cfg.walkLost) and x.lost.exists(l => open.forall(h => below(l, h)))
  }

  /// The readable keys every readable key at or below which every witness
  /// confirms; `compute_frontier_for/2` returns its maximum.
  pure def confirmedPrefix(r: int, x: Replica, ws: Set[int]): Set[Event] =
    readable(x).filter(e => readable(x).forall(f => below(f, e) implies confirmedByAll(r, x, ws, f)))

  /// The keys at or below `k` a truncation may reach: under the cap, those
  /// strictly below the first unapplied key at or below `k`.
  pure def cutAt(x: Replica, k: Event): Set[Event] = {
    val blocked = unapplied(x).filter(h => below(h, k))
    x.tree.filter(e => below(e, k) and (cfg.capAtUnapplied implies blocked.forall(h => under(e, h))))
  }

  /// Truncating `cut` and moving the watermark to `wm`. An applier first
  /// folds what lies above the old watermark.
  pure def truncated(x: Replica, cut: Set[Event], wm: Event): Replica = {
    ...x,
    tree: x.tree.exclude(cut),
    applied:
      if (folds(cfg.backend)) x.applied
      else x.applied.union(cut.exclude(x.lost).filter(e => not(below(e, x.wm)))),
    wm: wm,
    lost: x.lost.exclude(cut),
  }

  /// One compaction cycle, as the cut and the watermark it leaves.
  pure def compaction(r: int, x: Replica, ws: Set[int]): { cut: Set[Event], wm: Event } = {
    val d = confirmedPrefix(r, x, ws)
    val point = maxKey(d)
    val passes = d != Set() and not(below(point, x.wm))
    if (cfg.door != DropsApplied) {
      val cut = if (d == Set()) Set() else cutAt(x, point)
      { cut: cut, wm: if (cut != Set() and not(below(maxKey(cut), x.wm))) maxKey(cut) else x.wm }
    } else if (passes) {
      val cut = cutAt(x, point)
      { cut: cut, wm: if (cut == Set()) x.wm else maxKey(cut) }
    } else {
      { cut: cutAt(x, x.wm), wm: x.wm }
    }
  }

  /// The rebuild: with nothing blocked it takes the whole tree, the lost
  /// keys above the point on a dangling subtree included.
  pure def rebuild(x: Replica): { cut: Set[Event], wm: Event } = {
    val top = maxKey(readable(x).union(Set(x.wm)))
    val blocked = unapplied(x).filter(h => below(h, top))
    { cut: if (cfg.healCap and blocked != Set()) cutAt(x, top) else x.tree, wm: top }
  }

  pure def membersCover(r: int, x: Replica, ws: Set[int]): bool =
    ws.forall(q => Origins.forall(o => witnessed(r, x, q).get(o) >= frontier(x.applied).get(o)))

  /// `r`'s side of a round merging `y`'s tree, with or without the fused
  /// hold, before the frontiers are recorded. The door judges what the
  /// witnesses confirmed before this round; a lost key is neither folded
  /// nor judged, and goes with the key the door truncates at.
  pure def merged(r: int, x: Replica, y: Replica, ws: Set[int], hold: bool): Replica = {
    val merged = x.tree.union(y.tree)
    val visible = merged.exclude(x.lost)
    val applied = if (folds(cfg.backend) and not(hold)) closure(x.applied.union(visible)) else x.applied
    val held = visible.filter(e => below(e, x.wm) and not(applied.contains(e)))
    def door(e) = x.lost.contains(e) or and {
      cfg.door != DropsNothing,
      below(e, x.wm),
      applied.contains(e),
      held.forall(h => under(e, h)),
      cfg.door == DropsConfirmed implies confirmedByAll(r, x, ws, e),
    }
    val points = visible.filter(k => merged.forall(f => below(f, k) implies door(f)))
    val dropped = if (stops(r, x, ws, merged)) Set() else merged.filter(e => points.exists(k => below(e, k)))
    { ...x, tree: merged.exclude(dropped), applied: applied, lost: x.lost.exclude(dropped) }
  }

  pure def heard(x: Replica, q: int, f: Frontier): Replica =
    { ...x, rows: x.rows.set(q, f), stale: x.stale.exclude(Set(q)) }

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: int -> Replica
  var minted: Set[Event]
  /// Unordered pairs of replicas whose link is cut.
  var severed: Set[Set[int]]
  /// Members the operator removed.
  var retired: Set[int]
  var spent: { cuts: int, losses: int }

  val vars = (replicas, minted, severed, retired, spent)

  val members = Replicas.exclude(retired)

  val noDeadlock = enabled(step)

  /// The witnesses of `r`'s confirmation rule; with no peer, nothing is
  /// confirmed.
  def witnessesOf(r: int): Set[int] = {
    val peers = members.exclude(Set(r)).filter(p => match cfg.witnesses {
      | EveryMember => true
      | FreshMembers => not(replicas.get(r).stale.contains(p))
    })
    if (peers == Set()) Set() else peers.union(Set(r))
  }

  def linked(r: int, p: int): bool = not(severed.contains(Set(r, p)))

  action init = all {
    replicas' = Replicas.mapBy(r => {
      tree: Set(),
      applied: Set(),
      checkpoint: Origins.mapBy(_ => 0),
      wm: Bottom,
      rows: Replicas.exclude(Set(r)).mapBy(_ => Origins.mapBy(_ => 0)),
      stale: Set(),
      lost: Set(),
    }),
    minted' = Set(),
    severed' = Set(),
    retired' = Set(),
    spent' = { cuts: 0, losses: 0 },
  }

  action become(r: int, x: Replica): bool = all {
    replicas' = replicas.set(r, x),
    minted' = minted,
    severed' = severed,
    retired' = retired,
    spent' = spent,
  }

  /// The HLCs a mint at `r` may take: above every key `r` has seen and
  /// above its watermark, by at most `Skew` more.
  def clockRange(r: int): Set[int] = {
    val x = replicas.get(r)
    val seen = x.tree.union(x.applied).union(Set(x.wm)).fold(0, (m, e) => max2(m, e.hlc))
    (seen + 1).to(seen + 1 + Skew)
  }

  /// A local event is applied at mint.
  action mintAt(r: int, h: int): bool = {
    val x = replicas.get(r)
    val e = { hlc: h, org: r, seq: minted.filter(e => e.org == r).size() + 1 }
    all {
      members.contains(r),
      e.seq <= MaxSeq,
      clockRange(r).contains(h),
      replicas' = replicas.set(r, { ...x, tree: x.tree.union(Set(e)), applied: x.applied.union(Set(e)) }),
      minted' = minted.union(Set(e)),
      severed' = severed,
      retired' = retired,
      spent' = spent,
    }
  }

  action mint(r: int): bool = {
    nondet h = clockRange(r).oneOf()
    mintAt(r, h)
  }

  /// The end of a round of `r` pulling from `p`, `r`'s side being `x`:
  /// each records the other's durable frontier and refreshes its row.
  action recorded(r: int, p: int, x: Replica): bool = {
    val x2 = heard(x, p, durable(replicas.get(p)))
    all {
      replicas' = replicas.set(r, x2).set(p, heard(replicas.get(p), r, durable(x2))),
      minted' = minted,
      severed' = severed,
      retired' = retired,
      spent' = spent,
    }
  }

  /// A round of `r` pulling from `p`, holding back what it merged when
  /// `hold`. An empty or equal peer tree merges nothing.
  action pull(r: int, p: int, hold: bool): bool = {
    val x = replicas.get(r)
    val y = replicas.get(p)
    all {
      r != p,
      members.contains(r),
      members.contains(p),
      linked(r, p),
      y.lost == Set(),
      hold implies cfg.backend == FusedHolding,
      if (y.tree == Set() or y.tree == x.tree) all { not(hold), recorded(r, p, x) }
      else recorded(r, p, merged(r, x, y, witnessesOf(r), hold)),
    }
  }

  action sync(r: int, p: int): bool = {
    nondet hold = Set(true, false).oneOf()
    pull(r, p, hold)
  }

  action replay(r: int): bool = {
    val x = replicas.get(r)
    val applied = closure(x.applied.union(readable(x)))
    all {
      members.contains(r),
      cfg.backend != Fused,
      applied != x.applied,
      become(r, { ...x, applied: applied }),
    }
  }

  action checkpoint(r: int): bool = {
    val x = replicas.get(r)
    all {
      members.contains(r),
      cfg.backend == Applier,
      x.checkpoint != frontier(x.applied),
      become(r, { ...x, checkpoint: frontier(x.applied) }),
    }
  }

  action compact(r: int): bool = {
    val x = replicas.get(r)
    val ws = witnessesOf(r)
    val c = compaction(r, x, ws)
    all {
      members.contains(r),
      ws != Set(),
      not(stops(r, x, ws, x.tree)),
      c.cut != Set(),
      become(r, truncated(x, c.cut, c.wm)),
    }
  }

  action heal(r: int): bool = {
    val x = replicas.get(r)
    val ws = witnessesOf(r)
    val c = rebuild(x)
    all {
      members.contains(r),
      ws != Set(),
      stops(r, x, ws, x.tree),
      cfg.heal != NoHeal,
      cfg.heal == WhenMembersCover implies membersCover(r, x, ws),
      c.wm != Bottom,
      c.cut != Set(),
      become(r, truncated(x, c.cut, c.wm)),
    }
  }

  /// `r` is behind an unservable `p`: the catalogue rebootstrap installs
  /// `p`'s projection.
  action rebootstrap(r: int, p: int): bool = {
    val x = replicas.get(r)
    val y = replicas.get(p)
    all {
      r != p,
      members.contains(r),
      members.contains(p),
      linked(r, p),
      y.lost != Set(),
      not(y.applied.subseteq(x.applied)),
      become(r, { ...x, applied: x.applied.union(y.applied) }),
    }
  }

  /// A page of `r`'s own tree, holding `e`, goes missing.
  action lose(r: int, e: Event): bool = {
    val x = replicas.get(r)
    all {
      members.contains(r),
      spent.losses < MaxLost,
      readable(x).contains(e),
      replicas' = replicas.set(r, { ...x, lost: x.lost.union(Set(e)) }),
      minted' = minted,
      severed' = severed,
      retired' = retired,
      spent' = { ...spent, losses: spent.losses + 1 },
    }
  }

  action cutLink(r: int, p: int): bool = all {
    r != p,
    linked(r, p),
    spent.cuts < MaxCuts,
    replicas' = replicas,
    minted' = minted,
    severed' = severed.union(Set(Set(r, p))),
    retired' = retired,
    spent' = { ...spent, cuts: spent.cuts + 1 },
  }

  action healLink(r: int, p: int): bool = all {
    r != p,
    not(linked(r, p)),
    replicas' = replicas,
    minted' = minted,
    severed' = severed.exclude(Set(Set(r, p))),
    retired' = retired,
    spent' = spent,
  }

  /// The recency filter's timeout passes with no round between the two.
  action expire(r: int, p: int): bool = {
    val x = replicas.get(r)
    all {
      cfg.witnesses == FreshMembers,
      r != p,
      not(x.stale.contains(p)),
      become(r, { ...x, stale: x.stale.union(Set(p)) }),
    }
  }

  /// The operator removes member `p`; its own unsynced events are given up.
  action retire(p: int): bool = all {
    members.contains(p),
    retired.size() < MaxRetire,
    replicas' = replicas,
    minted' = minted,
    severed' = severed,
    retired' = retired.union(Set(p)),
    spent' = spent,
  }

  action step = {
    nondet r = Replicas.oneOf()
    any {
      mint(r),
      replay(r),
      checkpoint(r),
      compact(r),
      heal(r),
      retire(r),
      { nondet e = readable(replicas.get(r)).oneOf()
        lose(r, e) },
      { nondet p = Replicas.oneOf()
        any { sync(r, p), rebootstrap(r, p), cutLink(r, p), healLink(r, p), expire(r, p) } },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// The events whose origin is a member: retiring a member gives up its
  /// own unsynced events.
  val kept = minted.filter(e => members.contains(e.org))

  /// An event some member has not applied is still in some member's tree.
  val noLoss = members.forall(q => kept.forall(e =>
    not(replicas.get(q).applied.contains(e)) implies members.exists(r => replicas.get(r).tree.contains(e))))

  /// No member is left needing a catalogue rebootstrap: an event one member
  /// applied and truncated, every member has applied or still holds.
  val noGap = members.forall(p => members.forall(q => kept.forall(e => {
    val x = replicas.get(p)
    val y = replicas.get(q)
    (x.applied.contains(e) and not(x.tree.contains(e))) implies (y.applied.contains(e) or y.tree.contains(e))
  })))

  /// With lost pages the projection is a copy too: some member has applied
  /// every event or holds it readable.
  val noErase = kept.forall(e => members.exists(r =>
    replicas.get(r).applied.contains(e) or readable(replicas.get(r)).contains(e)))

  /// The hypothesis the frontier witness rests on (`Dot_Exactness`).
  val prefixClosed = Replicas.forall(r => replicas.get(r).applied.forall(e =>
    1.to(e.seq).forall(i => has(replicas.get(r).applied, e.org, i))))

  /// The lemma `noGap` rests on: a witness that confirms an event holds it
  /// in its tree or has applied it.
  val confirmedHeld = members.forall(r => witnessesOf(r).intersect(members).forall(q => minted.forall(e => {
    val y = replicas.get(q)
    e.seq <= witnessed(r, replicas.get(r), q).get(e.org) implies (y.tree.contains(e) or y.applied.contains(e))
  })))

  val safety = and { noLoss, noGap, prefixClosed, confirmedHeld }

  /// What the lost-page instances check in place of `noLoss` and `noGap`,
  /// which count only trees.
  val lostSafety = and { prefixClosed, confirmedHeld, noErase }

  // A step property reads the next state through these projections:
  // Quint's effect checker rejects a record field read on `next(...)`.
  pure def treesOf(m: int -> Replica): int -> Set[Event] = m.keys().mapBy(r => m.get(r).tree)
  pure def appliedOf(m: int -> Replica): int -> Set[Event] = m.keys().mapBy(r => m.get(r).applied)

  /// Truncation never discards a readable event the replica has not
  /// applied.
  pure def keepsUnapplied(before: int -> Replica, tree: int -> Set[Event], applied: int -> Set[Event]): bool =
    Replicas.forall(r => readable(before.get(r)).exclude(tree.get(r)).subseteq(applied.get(r)))

  /// A truncation of an event the replica applied leaves every member
  /// holding or having applied it. `ms` and `es` are the members and their
  /// events before the step.
  pure def strandsNone(
    before: int -> Replica, tree: int -> Set[Event], applied: int -> Set[Event], ms: Set[int], es: Set[Event]
  ): bool =
    ms.forall(r => before.get(r).tree.exclude(tree.get(r)).intersect(before.get(r).applied).intersect(es).forall(e =>
      ms.forall(q => tree.get(q).contains(e) or applied.get(q).contains(e))))

  /// A reachability control, expected to be violated: a truncation drops an
  /// event the replica has not applied. Only a rebuild can, by dropping a
  /// lost key.
  pure def dropsOnlyApplied(before: int -> Replica, tree: int -> Set[Event], applied: int -> Set[Event]): bool =
    Replicas.forall(r => before.get(r).tree.exclude(tree.get(r)).subseteq(applied.get(r)))

  temporal noDrop = always(orKeep(keepsUnapplied(replicas, next(treesOf(replicas)), next(appliedOf(replicas))), vars))

  temporal noDropNoStrand = always(orKeep(and {
    keepsUnapplied(replicas, next(treesOf(replicas)), next(appliedOf(replicas))),
    strandsNone(replicas, next(treesOf(replicas)), next(appliedOf(replicas)), members, kept),
  }, vars))

  temporal onlyApplied = always(orKeep(dropsOnlyApplied(replicas, next(treesOf(replicas)), next(appliedOf(replicas))), vars))

  /// Once minting is exhausted every tree empties and every replica has
  /// applied everything.
  val converged = and {
    Origins.forall(o => has(minted, o, MaxSeq)),
    Replicas.forall(r => replicas.get(r).tree == Set()),
    Replicas.forall(r => minted.subseteq(replicas.get(r).applied)),
  }

  /// Every scheduled activity keeps running. A compaction tick that finds
  /// nothing to truncate is a stutter, so fairness forces a truncation only
  /// while one is continuously possible.
  temporal fairness = and {
    Replicas.forall(r => and {
      weakFair(mint(r), vars),
      weakFair(replay(r), vars),
      weakFair(checkpoint(r), vars),
      weakFair(compact(r), vars),
      weakFair(heal(r), vars),
    }),
    Replicas.forall(r => Replicas.forall(p => weakFair(sync(r, p), vars) and weakFair(rebootstrap(r, p), vars))),
  }

  temporal live = fairness implies eventually(always(converged))
}
