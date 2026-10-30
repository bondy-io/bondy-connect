// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstallTypes {
  type InstallMode =
    // the session writes the source's cells aside and the rederive swaps
    // them in, in the same step as its re-fold, so no fold lands on an
    // installed cell (`bondy_oplog_applier:stage_cells/3`, `commit_stage/4`)
    | Stage
    // the batches are written over the local cells and re-folded later
    | Replace

  /// How compaction confirms a truncation.
  type CompactBy =
    | NoCompaction
    // a root, or a reported claim
    | Receipt
    // every member, the replica included, by its checkpointed claims
    | Durable
    // some set of the other members, as a recency filter on the members
    // would
    | Recorded
    // none, as a retention policy would
    | Own
    // every other member by its claims (`compaction_witnesses/1`)
    | Members

  /// The sweep's stability point.
  type BoundMode =
    // the HLC of the last key before the first uncovered one
    | LastConfirmed
    // the HLC of the first key some member's durable frontier does not
    // cover, or past every event when every held key is covered
    // (`bondy_oplog_instance:clustered_stability_point/2`)
    | FirstUnconfirmed

  /// How the replicas start, and when they may join.
  type JoinRule =
    // every replica a member from the start
    | Clustered
    // every replica alone (`cluster.enabled = off`) until a join, at any
    // time
    | AloneJoinAny
    // every replica alone until a join, taken only while at most one side
    // holds a truncation record; a return after a leave waits the same way
    | AloneJoinClean

  type Cfg = {
    install: InstallMode,
    // after a crash, no local write folds before the replay has re-folded
    // every unclaimed own event (`bondy_oplog_applier` `start_folding`)
    refoldFirst: bool,
    compactBy: CompactBy,
    // a retired origin's events count as confirmed by every member, for
    // truncation and for the bound
    retiredExempt: bool,
    bound: BoundMode,
    // retired origins are reaped from cell contexts (`reap_origins/2`)
    reap: bool,
    join: JoinRule,
    // the sweep waits while the replica holds the install mark
    mark: bool,
    // a marked source serves neither its frontier nor its cells
    serve: bool,
    // a source serves only once its boot replay has run
    replayed: bool,
    // the install ends only once the replica claims the target
    target: bool,
    // a replica does not write its mark while it serves an open cursor,
    // and a session refused for that ends before writing it
    busy: bool,
    // the mark is written when the session begins, not at its first install
    early: bool,
    // the replica refuses a detached session's finalize and target
    // (`bondy_oplog_applier:open_stage/3`)
    token: bool,
    // no truncation while the replica holds the mark
    trunc: bool,
    // a session begins only when the source's frontier claims every event
    // whose truncation the replica recorded
    coverBegin: bool,
    // every restore of the claims keeps the recorded events
    floor: bool,
    // a member may leave, restart alone, and return
    leave: bool,
    // the members still count one that went alone without a Partisan leave
    kept: bool,
  }
}

/// Can the catalogue install, a session that stages the source's cells and
/// swaps them in at its re-fold, leave a cell other than the fold of every
/// event, once cells are deleted by the stabilization sweep, truncated by
/// compaction, or reaped of a retired origin? And can a replica's
/// truncation record strand another member once clustering is turned off
/// and on, or a member leaves and returns?
///
/// The model has one add-wins cell, `{dots, cc}`: an op drops the dots its
/// stamped context observed, adds its own dot when it is an add, and
/// max-merges its context and dot into the cell's (`cc_absorb/3`); the
/// kernel skips an event whose dot the context already covers
/// (`bondy_oplog_cell_kernel:apply/6`). Remote events enter the MST on
/// receipt and reach the cell on a later replay, which skips what the
/// applied frontier claims (`bondy_oplog_cell_apply:drop_claimed/2`) and
/// folds causally (`partition_contiguous/4`, `causal_tops/4`); the replica's
/// own events are never held. A retired origin's events never fold
/// (`drop_retired/2`). An event is known by its HLC, its place in the mint
/// order.
///
/// An install is the code's session (`do_bootstrap_snapshot/6`): it reads
/// the source's frontier, streams the source's cells as they are at each
/// later batch while its cursor is open, re-derives once the stream ends,
/// adopting the frontier it read and re-folding the MST events that
/// frontier does not claim, then reads the source's frontier again, the
/// target the replica's claims must reach. A session is a process apart
/// from its replica: a crash may leave one past its rederive running, and a
/// new session may begin while an earlier one is past its rederive; that
/// one goes on detached.
///
/// A checkpoint reads the claims, then syncs the projection
/// (`write_frontier_checkpoint/2`). A crash keeps the MST and restores the
/// claims the last checkpoint holds (`boot_frontier/2`), and leaves the cell
/// in any state it held since that sync. A truncation records its events,
/// then cuts them, with a checkpoint after the cut for a compaction commit
/// (`do_finalize_catalogue_compaction/4`) and none for the watermark door
/// (`watermark_door/2`).
///
/// Not modelled: several cells, other kernels and `{keep, Reduced}`
/// rewrites, the door's fold of an unapplied event, unroutable buckets,
/// pending claims, nested sub-CRDTs, a crash that loses MST receipts.
module JoinInstall {
  import JoinInstallTypes.*
  import Ints.* from "../lib/Ints"

  /// Also the origins: each replica mints under its own.
  const Replicas: Set[str]
  const MaxSeq: int
  const MaxEvents: int
  const MaxInstalls: int
  const MaxCrashes: int
  const cfg: Cfg

  pure val Origins = Replicas

  type Dot = { org: str, seq: int }

  /// An op as it travels: its dot, whether it adds, and the context its
  /// writer stamped.
  type Event = { org: str, seq: int, add: bool, ctx: str -> int }

  /// An event's HLC: its place in the mint order, from 1.
  type Hlc = int

  type Cell = { dots: Set[Dot], cc: str -> int }

  type Batch = NoBatch | Fetched(Cell)

  type StreamStep =
    // the source's frontier is read
    | Opened
    // the session has begun installing
    | Begun
    // a batch has been installed
    | Installed

  /// A session up to its rederive: its source, the frontier it read there,
  /// whether its cursor at the source is open, the batch it holds, and,
  /// under `Stage`, the cell it staged.
  type Stream = { step: StreamStep, peer: str, pend: Set[Hlc], cur: bool, batch: Batch, staged: Cell }

  /// `target` is the source's frontier read after the rederive.
  type Targeting = { peer: str, target: Set[Hlc] }

  type Session =
    | Idle
    | Streaming(Stream)
    | Rederived(str)
    | Targeted(Targeting)
    | Adopted(Targeting)

  type Membership =
    // alone before any join
    | Solo
    | Member
    // alone after being a member
    | Alone
    // a member again
    | Back

  type Replica = {
    cell: Cell,
    // the events in the MST
    tree: Set[Hlc],
    // the events whose effect the cell holds: the applied frontier
    applied: Set[Hlc],
    // the events the replay has folded
    folded: Set[Hlc],
    // the claims the last checkpoint holds
    ckpt: Set[Hlc],
    // the claims a checkpoint has read, awaiting its sync
    reading: Set[Hlc],
    // the cells held since the last sync
    sinceSync: Set[Cell],
    // every claim the replica made
    everClaimed: Set[Hlc],
    // the durable install mark
    mark: bool,
    // a checkpoint read the install's claims
    fresh: bool,
    // the install's claims survive in memory
    live: bool,
    // the events truncated from the MST
    truncated: Set[Hlc],
    // the events a truncation will cut
    reserved: Set[Hlc],
    // the truncation record: every event a truncation may have cut, or will
    record: Set[Hlc],
    membership: Membership,
    session: Session,
    // a session past its rederive that a crash or a new session detached
    detached: Session,
    // the boot replay has run
    replayed: bool,
    // a replace wrote a cell no rederive has re-folded since
    dirty: bool,
  }

  type Spent = { installs: int, crashes: int }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure val Zero = Origins.mapBy(_ => 0)

  pure val Bottom: Cell = { dots: Set(), cc: Zero }

  pure def observed(d: Dot, v: str -> int): bool = v.get(d.org) >= d.seq

  pure def dotOf(e: Event): Dot = { org: e.org, seq: e.seq }

  /// The kernel step for one event (`apply_op/4`, guarded).
  pure def stepCell(c: Cell, e: Event): Cell =
    if (observed(dotOf(e), c.cc)) c
    else {
      dots: c.dots.filter(d => not(observed(d, e.ctx))).union(if (e.add) Set(dotOf(e)) else Set()),
      cc: Origins.mapBy(o => {
        val m = max2(c.cc.get(o), e.ctx.get(o))
        if (o == e.org) max2(m, e.seq) else m
      }),
    }

  pure def present(c: Cell): bool = c.dots != Set()

  /// What a replica's last checkpoint claims durably: nothing while it holds
  /// the mark, since a checkpoint written under the mark restores an empty
  /// frontier (`bondy_oplog_instance:restored_frontier/1`); with `floor`,
  /// also every event whose truncation it recorded.
  pure def floorOf(x: Replica): Set[Hlc] = if (cfg.floor) x.record else Set()

  pure def durClaims(x: Replica): Set[Hlc] = (if (x.mark) Set() else x.ckpt).union(floorOf(x))

  /// A peer confirms anything it ever claimed: a recorded report is replaced
  /// only by the next round's (`bondy_oplog_peer_state`), so a stale one
  /// outlives the peer's crash.
  pure def claims(x: Replica): Set[Hlc] = if (MaxCrashes == 0) x.applied else x.everClaimed

  pure def held(x: Replica): Set[Hlc] = x.tree.exclude(x.truncated)

  pure def mapValues(rs: str -> Replica, f: (Replica) => Replica): str -> Replica = rs.keys().mapBy(k => f(rs.get(k)))

  pure def isMember(m: Membership): bool = m == Member or m == Back

  pure def pastRederive(s: Session): bool = match s {
    | Rederived(_) => true
    | Targeted(_) => true
    | Adopted(_) => true
    | _ => false
  }

  pure def streams(s: Session): Set[Stream] = match s {
    | Streaming(st) => Set(st)
    | _ => Set()
  }

  pure def fetched(b: Batch): Set[Cell] = match b {
    | Fetched(c) => Set(c)
    | NoBatch => Set()
  }

  pure def rederivedFrom(s: Session): Set[str] = match s {
    | Rederived(p) => Set(p)
    | _ => Set()
  }

  pure def targeted(s: Session): Set[Targeting] = match s {
    | Targeted(t) => Set(t)
    | _ => Set()
  }

  pure def adopted(s: Session): Set[Targeting] = match s {
    | Adopted(t) => Set(t)
    | _ => Set()
  }

  pure def peerOf(s: Session): Set[str] = match s {
    | Idle => Set()
    | Streaming(st) => Set(st.peer)
    | Rederived(p) => Set(p)
    | Targeted(t) => Set(t.peer)
    | Adopted(t) => Set(t.peer)
  }

  /// The session's cursor at `p` is open.
  pure def readsFrom(s: Session, p: str): bool = streams(s).exists(st => st.peer == p and st.cur)

  /// Its cursors at `p` expire once `p` marks itself
  /// (`bondy_oplog_catalogue_cursor:discard_instance/1`).
  pure def expired(s: Session, p: str): Session = match s {
    | Streaming(st) => if (st.peer == p) Streaming({ ...st, cur: false }) else s
    | _ => s
  }

  /// A crash of `p` ends the session up to its target.
  pure def endsWith(s: Session, p: str): bool = match s {
    | Streaming(st) => st.peer == p
    | Rederived(q) => q == p
    | Targeted(t) => t.peer == p
    | _ => false
  }

  /// The replica takes a finalize or a target from a detached session only
  /// without `token`.
  pure def holds(detached: bool): bool = detached implies not(cfg.token)

  pure def withSession(x: Replica, detached: bool, s: Session): Replica =
    if (detached) { ...x, detached: s } else { ...x, session: s }

  pure def cut(x: Replica): Replica = { ...x, truncated: x.truncated.union(x.reserved), reserved: Set() }

  /// `rs` with `r` set to `x` marked, every cursor at `r` expired.
  pure def marked(rs: str -> Replica, r: str, x: Replica): str -> Replica =
    mapValues(rs.set(r, { ...x, mark: true, fresh: false, live: false }), y => { ...y, session: expired(y.session, r) })

  /// Every step but the checkpoint, the truncation, the membership changes
  /// and the crash records the cells it leaves and the claims it makes.
  pure def tracked(rs: str -> Replica): str -> Replica =
    if (MaxCrashes == 0) rs
    else mapValues(rs, x => { ...x, sinceSync: x.sinceSync.union(Set(x.cell)), everClaimed: x.everClaimed.union(x.applied) })

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica
  /// Every event minted, in mint order, with its ops.
  var log: List[Event]
  var retired: Set[str]
  var spent: Spent

  def ev(h: Hlc): Event = log[h - 1]

  val allEvents: Set[Hlc] = 1.to(log.length())

  def has(s: Set[Hlc], o: str, i: int): bool = s.exists(h => ev(h).org == o and ev(h).seq == i)

  /// `s` holds seqs `1..n` of `o`.
  def hasUpTo(s: Set[Hlc], o: str, n: int): bool = 1.to(n).forall(i => has(s, o, i))

  def top(s: Set[Hlc], o: str): int = s.filter(h => ev(h).org == o).fold(0, (m, h) => max2(m, ev(h).seq))

  def ofLive(s: Set[Hlc]): Set[Hlc] = s.filter(h => not(retired.contains(ev(h).org)))

  /// Folds `s` onto `c` in HLC order, which is causal: an event's context
  /// observed only events minted before it.
  def foldAll(c: Cell, s: Set[Hlc]): Cell =
    range(1, log.length() + 1).foldl(c, (acc, h) => if (s.contains(h)) stepCell(acc, ev(h)) else acc)

  /// The value a set of events folds to, independent of order: an add
  /// survives when no event of the set observed it.
  def presentFold(s: Set[Hlc]): bool =
    s.exists(h => ev(h).add and not(s.exists(g => observed(dotOf(ev(h)), ev(g).ctx))))

  /// A cell's HLC is its highest covered dot's, which a reap lowers.
  def cellHlc(c: Cell): Hlc = allEvents.filter(h => c.cc.get(ev(h).org) == ev(h).seq).fold(0, (m, h) => max2(m, h))

  /// The pointwise least of every member's durable claims, its own included.
  val stableVV = Origins.mapBy(o => Replicas.fold(MaxSeq, (m, q) => {
    val t = top(durClaims(replicas.get(q)), o)
    if (t < m) t else m
  }))

  def covered(h: Hlc): bool = ev(h).seq <= stableVV.get(ev(h).org) or (cfg.retiredExempt and retired.contains(ev(h).org))

  /// The code's point walks the tree in HLC order and stops at the first
  /// key the stable vector does not cover, past every event when there is
  /// none. The code answers no point when that key is the tree's first,
  /// which takes fewer discards than this, never more.
  def sweepBound(x: Replica): Hlc = {
    val first = held(x).filter(h => not(covered(h))).fold(MaxEvents + 1, (m, h) => if (h < m) h else m)
    match cfg.bound {
      | FirstUnconfirmed => first
      | LastConfirmed => held(x).filter(h => h < first).fold(0, (m, h) => max2(m, h))
    }
  }

  /// `known` holds the event's origin's earlier events and every dot of a
  /// live origin its context observed.
  def depsIn(h: Hlc, known: Set[Hlc]): bool =
    hasUpTo(known, ev(h).org, ev(h).seq - 1) and Origins.exclude(retired).forall(o => hasUpTo(known, o, ev(h).ctx.get(o)))

  /// The replay folds each received event once, and causally: a remote one
  /// once its origin's earlier events and every dot its context observed
  /// are applied, an own one once its own earlier events are. An install
  /// does not move the replay cursor, so an event whose effect came with
  /// the source's cell is still folded, and the kernel skips it.
  def foldable(r: str, h: Hlc): bool = {
    val x = replicas.get(r)
    val e = ev(h)
    and {
      ofLive(x.tree.exclude(x.folded.union(x.truncated))).contains(h),
      if (e.org == r) held(x).forall(g => (ev(g).org == r and ev(g).seq < e.seq) implies x.applied.contains(g))
      else depsIn(h, x.applied),
    }
  }

  def caughtUp(r: str): bool = not(replicas.get(r).tree.exists(h => foldable(r, h)))

  /// `r` is a member, and so is `p`.
  def linked(r: str, p: str): bool = isMember(replicas.get(r).membership) and isMember(replicas.get(p).membership)

  /// The other members `r` counts, `kept` keeping one that went alone.
  def members(r: str): Set[str] =
    if (isMember(replicas.get(r).membership))
      Replicas.exclude(Set(r)).filter(q => {
        val m = replicas.get(q).membership
        isMember(m) or (cfg.kept and m == Alone)
      })
    else Set()

  /// A session's source answers neither its frontier nor its cells while
  /// marked (`serve`) or before its boot replay has run (`replayed`).
  def serves(p: str): bool = {
    val y = replicas.get(p)
    and { not(retired.contains(p)), cfg.serve implies not(y.mark), cfg.replayed implies y.replayed }
  }

  /// `r` serves an open cursor.
  def busy(r: str): bool = Replicas.exists(q => readsFrom(replicas.get(q).session, r))

  /// Under `AloneJoinClean`, sides join only while at most one of them holds
  /// a truncation record.
  def cleanJoin(sides: Set[Set[str]]): bool =
    cfg.join == AloneJoinClean implies sides.filter(s => s.exists(q => replicas.get(q).record != Set())).size() <= 1

  /// The re-fold: the claims become `f`, and the MST events `f` does not
  /// claim are folded onto `base`, but for a recorded event the re-fold
  /// reads after its cut (`gone`), the truncation running in another
  /// process. The own events fold before the call returns; a remote one is
  /// held until every dependency is claimed or folded, the own events of
  /// the batch counting for nothing. Apply folds a held event later.
  def refold(x: Replica, r: str, base: Cell, f: Set[Hlc], gone: Set[Hlc]): Replica = {
    val unclaimed = held(x).exclude(f)
    val remote = ofLive(unclaimed.filter(h => ev(h).org != r))
    val s = unclaimed.filter(h => ev(h).org == r).union(remote.powerset().filter(c => c.forall(h => depsIn(h, c.union(f)))).flatten()).exclude(gone)
    { ...x, cell: foldAll(base, s), applied: f.union(s), folded: s }
  }

  /// Compaction's confirmation of `h` for `r`, `witnesses` the members a
  /// recency filter keeps.
  def confirms(r: str, witnesses: Set[str], h: Hlc): bool = match cfg.compactBy {
    | Durable => (cfg.retiredExempt and retired.contains(ev(h).org)) or Replicas.forall(q => durClaims(replicas.get(q)).contains(h))
    | Recorded => witnesses.forall(q => claims(replicas.get(q)).contains(h))
    | Members => members(r).forall(q => claims(replicas.get(q)).contains(h))
    | Own => true
    | Receipt => Replicas.exclude(Set(r)).forall(q => replicas.get(q).tree.contains(h) or claims(replicas.get(q)).contains(h))
    | NoCompaction => false
  }

  /// `r`'s own session (`detached = false`) or its detached one.
  def sessionOf(r: str, detached: bool): Session =
    if (detached) replicas.get(r).detached else replicas.get(r).session

  action move(rs: str -> Replica): bool = all { replicas' = tracked(rs), log' = log, retired' = retired, spent' = spent }

  action become(r: str, x: Replica): bool = move(replicas.set(r, x))

  /// An untracked step of `r`.
  action settle(r: str, x: Replica): bool = all { replicas' = replicas.set(r, x), log' = log, retired' = retired, spent' = spent }

  action init = all {
    replicas' = Replicas.mapBy(_ => {
      cell: Bottom,
      tree: Set(),
      applied: Set(),
      folded: Set(),
      ckpt: Set(),
      reading: Set(),
      sinceSync: Set(Bottom),
      everClaimed: Set(),
      mark: false,
      fresh: false,
      live: false,
      truncated: Set(),
      reserved: Set(),
      record: Set(),
      membership: if (cfg.join == Clustered) Member else Solo,
      session: Idle,
      detached: Idle,
      replayed: true,
      dirty: false,
    }),
    log' = List(),
    retired' = Set(),
    spent' = { installs: 0, crashes: 0 },
  }

  /// A local write, folded on the WAL drain, its context the cell's as the
  /// writer reads it. Under `refoldFirst` the drain folds nothing before
  /// the boot replay has folded the replica's own events; the write is then
  /// folded by the replay that re-presents it.
  action mint(r: str, add: bool): bool = {
    val x = replicas.get(r)
    val e = { org: r, seq: top(x.tree, r) + 1, add: add, ctx: x.cell.cc }
    val h = log.length() + 1
    val foldsNow = cfg.refoldFirst implies x.tree.forall(g => ev(g).org == r implies x.applied.contains(g))
    all {
      not(retired.contains(r)),
      e.seq <= MaxSeq,
      log.length() < MaxEvents,
      add or present(x.cell),
      replicas' = tracked(replicas.set(r,
        if (foldsNow) {
          ...x,
          cell: stepCell(x.cell, e),
          tree: x.tree.union(Set(h)),
          applied: x.applied.union(Set(h)),
          folded: x.folded.union(Set(h)),
        }
        else { ...x, tree: x.tree.union(Set(h)) })),
      log' = log.append(e),
      retired' = retired,
      spent' = spent,
    }
  }

  /// An anti-entropy round merges the peer's whole MST, so what a replica
  /// has received is causally closed; a retired origin's events are
  /// refused.
  action pull(r: str, p: str): bool = {
    val x = replicas.get(r)
    val y = replicas.get(p)
    val fresh = ofLive(y.tree.exclude(x.tree.union(y.truncated)))
    all { r != p, linked(r, p), fresh != Set(), become(r, { ...x, tree: x.tree.union(fresh) }) }
  }

  action apply(r: str, h: Hlc): bool = {
    val x = replicas.get(r)
    all {
      foldable(r, h),
      become(r, {
        ...x,
        cell: if (x.applied.contains(h)) x.cell else stepCell(x.cell, ev(h)),
        applied: x.applied.union(Set(h)),
        folded: x.folded.union(Set(h)),
      }),
    }
  }

  /// The stabilization sweep deletes an empty cell below the bound, once
  /// the replay has caught up (`ensure_remote_caught_up/1`), and waits while
  /// the replica holds the mark (`mark`).
  action discard(r: str): bool = {
    val x = replicas.get(r)
    all {
      x.cell != Bottom,
      caughtUp(r),
      not(present(x.cell)),
      cfg.mark implies not(x.mark),
      cellHlc(x.cell) < sweepBound(x),
      become(r, { ...x, cell: Bottom }),
    }
  }

  /// The operator retires an origin every replica has fully applied; with
  /// crashes, one every replica's durable claims hold.
  action retire(o: str): bool = all {
    cfg.reap,
    not(retired.contains(o)),
    Replicas.exclude(Set(o)).forall(q => {
      val y = replicas.get(q)
      allEvents.filter(h => ev(h).org == o).subseteq(if (MaxCrashes > 0) durClaims(y) else y.applied)
    }),
    replicas' = tracked(replicas),
    log' = log,
    retired' = retired.union(Set(o)),
    spent' = spent,
  }

  action reapCell(r: str, o: str): bool = {
    val x = replicas.get(r)
    all {
      retired.contains(o),
      r != o,
      x.cell.cc.get(o) != 0,
      not(x.cell.dots.exists(d => d.org == o)),
      become(r, { ...x, cell: { ...x.cell, cc: x.cell.cc.set(o, 0) } }),
    }
  }

  /// The session reads the source's frontier (`request_peer_frontier/4`);
  /// a session of `r`'s past its rederive goes on detached.
  action readFrontier(r: str, p: str): bool = {
    val x = replicas.get(r)
    all {
      linked(r, p),
      spent.installs < MaxInstalls,
      r != p,
      not(retired.contains(r)),
      serves(p),
      replicas' = tracked(replicas.set(r, {
        ...x,
        session: Streaming({ step: Opened, peer: p, pend: replicas.get(p).applied, cur: true, batch: NoBatch, staged: Bottom }),
        detached: if (pastRederive(x.session)) x.session else x.detached,
      })),
      log' = log,
      retired' = retired,
      spent' = { ...spent, installs: spent.installs + 1 },
    }
  }

  /// The source serves its cell as it is now, while the cursor is open
  /// (`bondy_oplog_catalogue_snapshot:next/2`).
  action fetch(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    all {
      s.step != Opened,
      s.cur,
      s.batch == NoBatch,
      become(r, { ...x, session: Streaming({ ...s, batch: Fetched(replicas.get(s.peer).cell) }) }),
    }
  }

  /// The session begins installing; `early` writes the mark here.
  action begin(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    val y = { ...x, session: Streaming({ ...s, step: Begun }) }
    all {
      s.step == Opened,
      cfg.coverBegin implies x.record.subseteq(s.pend),
      if (cfg.early) all { cfg.busy implies not(busy(r)), move(marked(replicas, r, y)) }
      else become(r, y),
    }
  }

  /// Under `busy`, a session whose replica serves an open cursor ends
  /// before writing the mark, and releases its own cursor at its source, so
  /// the two sides of a mutual re-bootstrap do not hold each other busy.
  action refuse(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    all { cfg.busy, s.step == Opened, busy(r), become(r, { ...x, session: Idle }) }
  }

  /// The session installs the batch it fetched, after writing the mark. A
  /// replace writes only a cell the source holds: a discarded cell is a
  /// deleted row, which the range scan does not return
  /// (`bondy_oplog_projection_ets:range/5`). A stage is meant to install
  /// the snapshot whole, an absent cell included, since the frontier it
  /// adopts claims that cell's events.
  action installCell(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    nondet src = fetched(s.batch).oneOf()
    val y = {
      ...x,
      cell: if (cfg.install == Stage or src == Bottom) x.cell else src,
      session: Streaming({ ...s, step: Installed, batch: NoBatch, staged: if (cfg.install == Stage) src else s.staged }),
      dirty: x.dirty or cfg.install == Replace,
    }
    all {
      s.step != Opened,
      if (cfg.early) become(r, y)
      else all { cfg.busy implies not(busy(r)), move(marked(replicas, r, y)) },
    }
  }

  /// The session re-derives once the stream has ended, adopting the
  /// frontier it read; a stage swaps in what it staged. `gone` are the
  /// reserved events cut before the re-fold reads them.
  action rederive(r: str, gone: Set[Hlc]): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    all {
      gone.subseteq(x.reserved),
      s.step == Installed,
      s.cur,
      s.batch == NoBatch,
      become(r, {
        ...refold(x, r, if (cfg.install == Stage) s.staged else x.cell, s.pend, gone),
        session: Rederived(s.peer),
        dirty: false,
      }),
    }
  }

  /// It then reads the source's frontier, the target, which the source
  /// answers only while it serves (`fetch_peer_frontiers/4`).
  action readTarget(r: str, detached: bool): bool = {
    nondet p = rederivedFrom(sessionOf(r, detached)).oneOf()
    all { serves(p), become(r, withSession(replicas.get(r), detached, Targeted({ peer: p, target: replicas.get(p).applied }))) }
  }

  /// The session adopted the frontier it read at its rederive; finalize
  /// records the target.
  action adopt(r: str, detached: bool): bool = {
    nondet t = targeted(sessionOf(r, detached)).oneOf()
    all { holds(detached), become(r, withSession(replicas.get(r), detached, Adopted(t))) }
  }

  /// A session can fail after its rederive, on any transport error, keeping
  /// the mark.
  action failRederived(r: str, detached: bool): bool = {
    val s = sessionOf(r, detached)
    all { rederivedFrom(s) != Set() or targeted(s) != Set(), become(r, withSession(replicas.get(r), detached, Idle)) }
  }

  /// The install ends once the replica claims the target (`target`): every
  /// effect the cells took from the source is then claimed here.
  action finish(r: str, detached: bool): bool = {
    val x = replicas.get(r)
    nondet t = adopted(sessionOf(r, detached)).oneOf()
    all {
      holds(detached),
      cfg.target implies t.target.subseteq(x.applied),
      become(r, withSession({ ...x, live: true }, detached, Idle)),
    }
  }

  /// A session whose cursor expired fails, leaving the mark it wrote; a
  /// marked replace re-derives; a stage only drops what it staged, as its
  /// cell and claims are untouched (`bondy_oplog_instance:abort_install/2`).
  /// A stage session can also fail at any point, on any transport error,
  /// releasing its cursor and the batch it holds.
  action abort(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streams(x.session).oneOf()
    val y = { ...x, session: Idle }
    all {
      cfg.install == Stage or (not(s.cur) and s.batch == NoBatch),
      become(r,
        if (cfg.install == Replace and x.mark) { ...refold(y, r, x.cell, floorOf(x), Set()), dirty: false }
        else y),
    }
  }

  /// The boot replay has run once nothing it could fold remains.
  action replayDone(r: str): bool = {
    val x = replicas.get(r)
    all { not(x.replayed), caughtUp(r), become(r, { ...x, replayed: true }) }
  }

  /// A truncation's first step: it syncs the projection and records every
  /// event its own claims and every confirming member's do, and reserves
  /// the held events up to an HLC `k` that the record covers; `witnesses`
  /// are the members confirming under `Recorded`, and empty otherwise. The
  /// code runs it and the cut in one instance call
  /// (`truncate_below_or_equal/4`), one of the interleavings checked here.
  action reserve(r: str, k: Hlc, witnesses: Set[str]): bool = {
    val x = replicas.get(r)
    val confirmed = x.applied.filter(h => confirms(r, witnesses, h))
    val cut = x.tree.exclude(x.truncated.union(x.reserved)).filter(h => h <= k)
    all {
      cfg.compactBy != NoCompaction,
      allEvents.contains(k),
      witnesses.subseteq(Replicas.exclude(Set(r))),
      (cfg.compactBy == Recorded) == (witnesses != Set()),
      cfg.trunc implies not(x.mark),
      cut != Set(),
      cut.subseteq(confirmed),
      settle(r, { ...x, reserved: x.reserved.union(cut), record: x.record.union(confirmed), sinceSync: Set(x.cell) }),
    }
  }

  /// The compaction commit: the cut, then a checkpoint of the claims
  /// (`finalize_catalogue_compaction_commit/6`).
  action compact(r: str): bool = {
    val x = replicas.get(r)
    all {
      x.reserved != Set(),
      settle(r, {
        ...cut(x),
        ckpt: x.applied,
        reading: x.applied,
        sinceSync: Set(x.cell),
        fresh: x.live,
        mark: x.mark and not(x.live),
      }),
    }
  }

  /// The watermark door's cut, with no checkpoint after it.
  action door(r: str): bool = all { replicas.get(r).reserved != Set(), settle(r, cut(replicas.get(r))) }

  /// A checkpoint reads the claims; its sync later makes them durable along
  /// with the cell as it is at the sync, and clears the mark if it read the
  /// install's claims.
  action readClaims(r: str): bool = {
    val x = replicas.get(r)
    settle(r, { ...x, reading: x.applied, fresh: x.live })
  }

  action sync(r: str): bool = {
    val x = replicas.get(r)
    settle(r, { ...x, ckpt: x.reading, sinceSync: Set(x.cell), mark: x.mark and not(x.fresh) })
  }

  action join: bool = all {
    Replicas.forall(r => replicas.get(r).membership == Solo),
    cleanJoin(Replicas.map(r => Set(r))),
    replicas' = mapValues(replicas, x => { ...x, membership: Member }),
    log' = log,
    retired' = retired,
    spent' = spent,
  }

  /// Under `leave`, a member leaves and restarts alone once, truncating on
  /// its own frontier, and may return later. The leave is the change of
  /// membership alone, taken with no session in flight; the restart's loss
  /// of memory is the crash's.
  action leave(r: str): bool = {
    val x = replicas.get(r)
    all {
      cfg.leave,
      x.membership == Member,
      x.session == Idle,
      x.detached == Idle,
      Replicas.forall(q => not(peerOf(replicas.get(q).session).union(peerOf(replicas.get(q).detached)).contains(r))),
      settle(r, { ...x, membership: Alone }),
    }
  }

  action rejoin(r: str): bool = all {
    replicas.get(r).membership == Alone,
    cleanJoin(Set(Set(r), Replicas.filter(q => isMember(replicas.get(q).membership)))),
    settle(r, { ...replicas.get(r), membership: Back }),
  }

  /// A crash keeps the MST, restores the durable claims, and leaves the cell
  /// in any state it held since the last sync: the sweep's delete and every
  /// fold are acknowledged before they are durable. It ends the sessions
  /// `r` serves up to their target, and `r`'s own; past its rederive, that
  /// one may go on detached, since the restarted replica holds no install
  /// token and refuses its stage before the rederive.
  action crash(r: str, c: Cell, detach: bool): bool = {
    val x = replicas.get(r)
    val d = durClaims(x)
    all {
      spent.crashes < MaxCrashes,
      x.sinceSync.contains(c),
      replicas' = mapValues(replicas, y => if (endsWith(y.session, r)) { ...y, session: Idle } else y).set(r, {
        ...x,
        cell: c,
        applied: d,
        folded: x.folded.intersect(d),
        reading: d,
        fresh: false,
        live: false,
        session: Idle,
        detached: if (detach and pastRederive(x.session)) x.session else x.detached,
        dirty: x.dirty and not(x.mark),
        replayed: not(cfg.replayed),
      }),
      log' = log,
      retired' = retired,
      spent' = { ...spent, crashes: spent.crashes + 1 },
    }
  }

  action step = any {
    join,
    { nondet r = Replicas.oneOf()
      any {
        { nondet add = Set(true, false).oneOf()
          mint(r, add) },
        { nondet h = replicas.get(r).tree.oneOf()
          apply(r, h) },
        { nondet p = Replicas.oneOf()
          any { pull(r, p), readFrontier(r, p), reapCell(r, p) } },
        { nondet detached = Set(true, false).oneOf()
          any { adopt(r, detached), finish(r, detached), readTarget(r, detached), failRederived(r, detached) } },
        { nondet c = replicas.get(r).sinceSync.oneOf()
          nondet detach = Set(true, false).oneOf()
          crash(r, c, detach) },
        { nondet gone = replicas.get(r).reserved.powerset().oneOf()
          rederive(r, gone) },
        { nondet k = allEvents.oneOf()
          nondet witnesses = (if (cfg.compactBy == Recorded) Replicas.exclude(Set(r)).powerset().exclude(Set(Set())) else Set(Set())).oneOf()
          reserve(r, k, witnesses) },
        discard(r), retire(r), fetch(r), begin(r), refuse(r), installCell(r), abort(r),
        replayDone(r), compact(r), door(r), readClaims(r), sync(r), leave(r), rejoin(r),
      } },
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// Once a replica has received every event and folded each one, its value
  /// is the fold of them all. A replace session's cells are the source's
  /// until its rederive re-folds the MST; readers see them in that window,
  /// and the mark keeps them from being served.
  val settledSound = Replicas.exclude(retired).forall(r => {
    val x = replicas.get(r)
    val settled = ofLive(allEvents).subseteq(x.tree) and held(x).subseteq(x.folded)
    (settled and not(x.dirty)) implies present(x.cell) == presentFold(allEvents)
  })

  /// While two replicas or more are live, some replica can still serve a
  /// session or clear its mark: one is unmarked, its install's claims
  /// survive in memory, or it has adopted. A lone survivor owing an install
  /// waits for a new member.
  val someoneServes = Replicas.exclude(retired).size() >= 2 implies
    Replicas.exclude(retired).exists(r => {
      val x = replicas.get(r)
      not(x.mark) or x.live or adopted(x.session) != Set()
    })

  /// An emptied cell the sweep can never delete: every event is minted and
  /// received, each held one is covered by every member's durable claims,
  /// nothing is left to fold, the mark is clear, and the cell's HLC is not
  /// below the bound.
  val noStuckTombstone = Replicas.exclude(retired).forall(r => {
    val x = replicas.get(r)
    not(and {
      log.length() == MaxEvents,
      x.cell != Bottom,
      not(present(x.cell)),
      ofLive(allEvents).subseteq(x.tree),
      held(x).forall(h => covered(h)),
      caughtUp(r),
      cfg.mark implies not(x.mark),
      cellHlc(x.cell) >= sweepBound(x),
    })
  })

  /// A truncated event stays claimed from the moment its truncation is
  /// recorded: nothing re-presents it once cut, and its origin's later
  /// events fold only after it.
  val compactedClaimed = Replicas.forall(r => replicas.get(r).record.subseteq(replicas.get(r).applied))

  /// Every event a replica's truncation record holds is, at every other
  /// member of its cluster, claimed, or still in its tree, or reachable by
  /// an install from that replica, which `coverBegin` admits while its
  /// claims cover the member's own record.
  val noStrandedRecord = Replicas.exclude(retired).forall(r => members(r).exclude(retired).forall(q => {
    val x = replicas.get(r)
    val y = replicas.get(q)
    x.record.forall(h => claims(y).contains(h) or held(y).contains(h) or y.record.subseteq(claims(x)))
  }))

  val safety = settledSound and someoneServes and compactedClaimed and noStrandedRecord
}
