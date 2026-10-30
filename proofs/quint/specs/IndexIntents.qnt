// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module IndexIntentsTypes {
  /// The version up to which the barrier clears a shard's intents.
  type ClearBound =
    // the version the index records for the shard
    | BySource
    // the highest version the index records for any shard
    | ByWriter
    // the version the shard had dispatched or dropped when the barrier
    // began, which needs no index record
    | ByDispatched
    // the shard's counter, ops not yet dispatched included
    | ByDrawn

  /// How a catalogue install reaches the index.
  type InstallMode =
    // it yields no index ops
    | NoIndexOps
    // it dispatches its ops at once, without syncing the primary
    | DispatchOnly
    // a group syncs the primary at its end, then dispatches its ops
    | Synced
    // a group dispatches its ops at its end without that sync
    | Unsynced

  /// Where a shard's counter restarts after a crash.
  type VersionSource =
    // the highest version its primary or the index records
    | Recorded
    | IntentsOnly
    | Reset

  /// What a crash keeps of a store's unsynced entries: a rolled journal
  /// file is closed without an fsync (`leveled_cdb:close_file`), so a later
  /// file can outlive an earlier one.
  type Keeps = Prefix | AnySubset

  /// A shard's dispatched version at open.
  type OpenDispatched =
    // its intents' clear record, since a shared instance's barrier may run
    // before the replay
    | AtCleared
    | AtCounter

  type Cfg = {
    // index ops are stored as intents in the primary batch and replayed at
    // open; without them every unclean open and writer restart rebuilds
    intents: bool,
    // the intent shares the cells' journal entry
    intentInBatch: bool,
    // the barrier syncs the index before clearing
    syncBeforeClear: bool,
    clearBound: ClearBound,
    // index cells are ordered by the version, not the cell HLC
    orderByVersion: bool,
    // each event of a batch takes its own version
    versionPerEvent: bool,
    installMode: InstallMode,
    versionSource: VersionSource,
    // a restarted writer registers for dispatch before it replays
    stampBeforeReplay: bool,
    // a restarted writer's replay syncs each primary after reading its
    // intents
    replaySyncs: bool,
    // a rebuild marks trusted only when the writer that took its re-fold
    // flushed it
    markNeedsFlush: bool,
    // a request during a rebuild withholds its mark and runs another
    keepRequests: bool,
    crashKeeps: Keeps,
    indexCrashKeeps: Keeps,
    // without intents: a full rebuild at every unclean open
    rebuildAtOpen: bool,
    openDispatched: OpenDispatched,
    // the index is synced before the trust mark is written
    syncBeforeMark: bool,
    // a rebuild syncs the index after removing the trust mark and before
    // wiping it
    syncBeforeWipe: bool,
    // the barrier clears intents while a rebuild is due
    clearMarked: bool,
    // a trusting open flushes the writer before it freshens the index
    openFlushes: bool,
    // an open whose flush failed does not freshen
    freshenNeedsFlush: bool,
    // a best-effort removal of the trust mark may be lost
    unmarkMayFail: bool,
    // a rebuild removes the trust mark itself before the wipe, failing the
    // run if it cannot
    rebuildUnmarks: bool,
    // an install group syncs the primary before its first cell
    syncBeforeInstall: bool,
    // a rebuild clears the index before its re-fold
    rebuildWipes: bool,
    // a rebuild's re-fold of a shard dispatches its ops
    rebuildRefolds: bool,
  }
}

/// Secondary-index maintenance across crashes: whether a node's index
/// equals the index function of its primary once nothing is in flight,
/// with index ops persisted as intents in the primary's own write batch
/// instead of a full rebuild after an unclean shutdown.
///
/// Each primary shard owns one key and has its own applier and store
/// (`bondy_oplog_cell_apply`, `bondy_oplog_applier`). The applier folds a
/// batch of events into one `put_batch`, a later event reading the earlier
/// one's value, and computes each event's index ops from the cell's old and
/// new value (`index_ops_for_one`): a put for every current term, a remove
/// for every term the new value no longer yields. It then dispatches them
/// to the one secondary writer that serves every shard
/// (`bondy_oplog_secondary_writer`), or, with the writer's backlog full,
/// drops them, marks the index and requests a rebuild
/// (`secondary_saturation_drop/5`). The writer writes its buffer to the
/// index in one batch; an index cell is last-writer-wins over
/// `{Order, live > dead}` (`bondy_oplog_crdt_index_entry:merge/2`).
///
/// A store write is one leveled `book_mput`, kept or dropped whole by a
/// crash. Neither store is synced per write; each loses its unsynced
/// entries independently of the other. A checkpoint syncs the stores, then
/// records what the shard has applied, and a crash re-presents every event
/// the checkpoint does not claim (`compute_replay_anchor`). A catalogue
/// install writes cells outside the WAL, at any past HLC. A rebuild marks
/// the index untrusted and clears it, re-folds every primary into the
/// writer, flushes it, and marks the index trusted
/// (`bondy_oplog_index_rebuild:do_rebuild/3`).
///
/// One index; values are whole-value assignments, so the model checks that
/// the index matches the primary, not what the primary should hold. A
/// re-presented event whose value the primary already holds yields only
/// puts, as in the code. Not modelled: a failed index computation.
module IndexIntents {
  import IndexIntentsTypes.*
  import Ints.* from "../lib/Ints"

  /// One key per primary shard.
  const Keys: Set[str]
  /// Cell values; `None` yields no term.
  const Vals: Set[str]
  const MaxEvents: int
  const MaxBatch: int
  const MaxInstalls: int
  const MaxCrashes: int
  const MaxWriterCrashes: int
  const MaxSaturations: int
  /// Clean closes, each followed by a trusting open.
  const MaxCleanReopens: int
  /// Runs whose index journal would grow past this are not taken.
  const MaxIndexEntries: int
  const cfg: Cfg

  pure val None = "none"

  type Event = { v: str, h: int }
  /// An index op on term `t` of key `k`, ordered by `ord`, carrying the
  /// version `iv` its batch records for `k`.
  type Op = { t: str, k: str, live: bool, ord: int, iv: int }

  type PEntry =
    // a cell write, with its intent when it has ops
    | Cells({ v: str, h: int, iv: int, ops: Set[Op] })
    // an intent written in the entry after its cells
    | Intent({ iv: int, ops: Set[Op] })
    // the barrier's clear of the shard's intents up to a version
    | Clear(int)

  type IEntry =
    // a writer batch, or the trust mark
    | Batch({ ops: Set[Op], mark: bool })
    // a rebuild's clear, which leaves the trust mark: the marker cell is
    // outside the index keyspace (`bondy_oplog_index_key:trust_marker_loc/3`)
    | Wipe
    // the removal of the trust mark
    | Unmark

  /// An install group's ops, open until the group settles
  /// (`install_catalogue_group`).
  type Group = NoGroup | InGroup(Set[Op])

  type Shard = {
    wal: List[Event],
    // WAL events the checkpoint claims
    ckpt: int,
    // events a crash re-presents, in order
    redo: List[Event],
    journal: List[PEntry],
    synced: int,
    // ops written but not yet dispatched
    pend: Set[Op],
    group: Group,
    ver: int,
    // the highest version dispatched or dropped
    disp: int,
    // opened, its leftover intents not yet replayed
    replaying: bool,
  }

  type Index = { journal: List[IEntry], synced: int }

  type Spent = {
    events: int, installs: int, crashes: int, writerCrashes: int, saturations: int, cleanReopens: int,
  }

  type WriterState =
    | Down
    // in `init/1`: registered for dispatch, its replay not yet done, or
    // (ablation) the other way round
    | Starting
    | Up

  type Writer = { state: WriterState, buf: Set[Op] }

  type Rebuild =
    | Idle
    | Requested
    // `restarted`: the writer re-registered since the run began; `again`:
    // a request arrived meanwhile
    | Running({ restarted: bool, folded: Set[str], again: bool })
    // the trust mark is written, its removal not yet
    | Remarking

  type OpenPhase =
    | Settled
    // an open with intents has not yet freshened the index: the ops it
    // replayed, and the index length at the open
    | Freshening({ owed: Set[Op], at: int })

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def terms(v: str): Set[str] = if (v == None) Set() else Set(v)

  pure def maxOf(s: Set[int]): int = s.fold(0, (a, b) => max2(a, b))

  /// The value of the shard's cell, and its HLC.
  pure def value(p: List[PEntry]): str = p.foldl(None, (v, e) => match e { | Cells(c) => c.v | _ => v })

  pure def hlc(p: List[PEntry]): int = p.foldl(0, (h, e) => match e { | Cells(c) => c.h | _ => h })

  pure def clearedUpTo(p: List[PEntry]): int = p.foldl(0, (m, e) => match e { | Clear(a) => max2(m, a) | _ => m })

  pure def intents(p: List[PEntry]): Set[{ iv: int, ops: Set[Op] }] = p.foldl(Set(), (s, e) => match e {
    | Cells(c) => if (c.ops != Set()) s.union(Set({ iv: c.iv, ops: c.ops })) else s
    | Intent(i) => if (i.ops != Set()) s.union(Set(i)) else s
    | Clear(_) => s
  })

  /// The ops of the intents above the clear record.
  pure def intentOps(p: List[PEntry]): Set[Op] =
    intents(p).filter(i => i.iv > clearedUpTo(p)).map(i => i.ops).flatten()

  pure def recordedVersion(p: List[PEntry]): int =
    maxOf(intents(p).map(i => i.iv).union(Set(clearedUpTo(p))))

  pure def opsOf(e: IEntry): Set[Op] = match e { | Batch(b) => b.ops | _ => Set() }

  /// The length of the index journal up to its last wipe.
  pure def wipedUpTo(j: List[IEntry]): int =
    j.indices().fold(0, (m, i) => if (j[i] == Wipe) max2(m, i + 1) else m)

  pure def rank(o: Op): int = 2 * o.ord + (if (o.live) 1 else 0)

  /// The ranks the index holds for term `t` of key `k` since its last wipe.
  pure def ranks(j: List[IEntry], t: str, k: str): Set[int] =
    j.indices().filter(i => i >= wipedUpTo(j)).map(i => opsOf(j[i])).flatten()
      .filter(o => o.t == t and o.k == k)
      .map(rank)

  pure def live(j: List[IEntry], t: str, k: str): bool = {
    val s = ranks(j, t, k)
    s != Set() and maxOf(s) % 2 == 1
  }

  /// The index holds op `o` or a later op on its term, or was wiped after
  /// position `at`: a trusted index wiped since then was rebuilt from the
  /// primary.
  pure def reflected(j: List[IEntry], o: Op, at: int): bool = {
    val s = ranks(j, o.t, o.k)
    (s != Set() and maxOf(s) >= rank(o)) or wipedUpTo(j) > at
  }

  /// The per-shard high-water every index batch records; a wipe keeps it.
  pure def indexVersion(j: List[IEntry], k: str): int =
    maxOf(j.indices().map(i => opsOf(j[i])).flatten().filter(o => o.k == k).map(o => o.iv))

  pure def trusted(j: List[IEntry]): bool =
    j.foldl(true, (t, e) => match e { | Unmark => false | Batch(b) => b.mark or t | Wipe => t })

  pure def diff(k: str, old: str, new: str, ord: int, iv: int): Set[Op] =
    terms(old).exclude(terms(new)).map(t => { t: t, k: k, live: false, ord: ord, iv: iv })
      .union(terms(new).map(t => { t: t, k: k, live: true, ord: ord, iv: iv }))

  pure def order(iv: int, h: int): int = if (cfg.orderByVersion) iv else h

  /// Event `i` (from 1) of a batch takes version `base + i`, or (ablation)
  /// `base + 1` for the whole batch.
  pure def evVersion(base: int, i: int): int = if (cfg.versionPerEvent) base + i else base + 1

  /// The value a batch leaves in shard `k`'s cell and the ops it yields.
  pure def batchFold(k: str, p: List[PEntry], evs: List[Event], base: int): { v: str, ops: Set[Op] } =
    range(0, evs.length()).foldl({ v: value(p), ops: Set() }, (r, i) => {
      val iv = evVersion(base, i + 1)
      { v: evs[i].v, ops: r.ops.union(diff(k, r.v, evs[i].v, order(iv, evs[i].h), iv)) }
    })

  /// One primary write: the cell and, when it has ops, the intent in the
  /// same entry or (ablation) the next one.
  pure def appended(p: List[PEntry], v: str, h: int, iv: int, ops: Set[Op]): List[PEntry] =
    if (cfg.intents and ops != Set()) {
      if (cfg.intentInBatch) p.append(Cells({ v: v, h: h, iv: iv, ops: ops }))
      else p.append(Cells({ v: v, h: h, iv: iv, ops: Set() })).append(Intent({ iv: iv, ops: ops }))
    } else p.append(Cells({ v: v, h: h, iv: iv, ops: Set() }))

  /// Shard `k` applying a batch of events.
  pure def applied(k: str, s: Shard, evs: List[Event]): Shard = {
    val r = batchFold(k, s.journal, evs, s.ver)
    val top = evVersion(s.ver, evs.length())
    { ...s, journal: appended(s.journal, r.v, evs[evs.length() - 1].h, top, r.ops), pend: r.ops, ver: top }
  }

  pure def groupOps(g: Group): Set[Op] = match g { | NoGroup => Set() | InGroup(ops) => ops }

  pure def appliedCount(s: Shard): int = s.wal.length() - s.redo.length()

  /// What a crash may leave of a journal synced up to `synced`.
  pure def survivors(l: List[a], synced: int, keeps: Keeps): Set[List[a]] = match keeps {
    | Prefix => synced.to(l.length()).map(n => l.slice(0, n))
    | AnySubset => synced.to(l.length() - 1).powerset().map(kept =>
        range(0, l.length()).foldl([], (acc, i) => if (i < synced or kept.contains(i)) acc.append(l[i]) else acc))
  }

  pure def request(rb: Rebuild): Rebuild = match rb {
    | Idle => Requested
    | Running(r) => Running({ ...r, again: true })
    | _ => rb
  }

  pure def restarted(rb: Rebuild): Rebuild = match rb {
    | Running(r) => Running({ ...r, restarted: true })
    | _ => rb
  }

  /// The outcomes of a best-effort removal of the trust mark
  /// (`remove_trust_marker`).
  pure def unmarked(j: List[IEntry]): Set[List[IEntry]] =
    if (cfg.unmarkMayFail) Set(j.append(Unmark), j) else Set(j.append(Unmark))

  /// Only the first mark removes it (`index_mark_rebuild/1`): while a
  /// rebuild is due, a mark finds it already removed or lost.
  pure def markUnmarked(rb: Rebuild, j: List[IEntry]): Set[List[IEntry]] = if (rb == Idle) unmarked(j) else Set(j)

  pure def flushed(j: List[IEntry], buf: Set[Op]): List[IEntry] =
    if (buf == Set()) j else j.append(Batch({ ops: buf, mark: false }))

  /// Lists of one to `n` values: the batches a write may carry.
  pure def batches(n: int): Set[List[str]] =
    1.to(n).map(m => range(0, m).foldl(Set([]), (acc, _) => acc.map(l => Vals.map(v => l.append(v))).flatten()))
      .flatten()

  // ===========================================================================
  // State machine
  // ===========================================================================

  var shards: str -> Shard
  var index: Index
  var writer: Writer
  var rebuild: Rebuild
  var opening: OpenPhase
  /// The open freshened an index missing an op it replayed.
  var stale: bool
  var clock: int
  var spent: Spent

  val vars = (shards, index, writer, rebuild, opening, stale, clock, spent)

  val primaries = Keys.mapBy(k => shards.get(k).journal)

  /// The leftover intents of every shard.
  val allIntentOps = Keys.map(k => intentOps(shards.get(k).journal)).flatten()

  /// The shards after the writer's replay: it reads every primary's
  /// intents, then syncs each primary, so whatever it replays is durable
  /// there; an open install group's intents are not yet synced, and its
  /// cells are not in the WAL.
  val replaySynced =
    if (cfg.replaySyncs) shards.keys().mapBy(k => { ...shards.get(k), synced: shards.get(k).journal.length() })
    else shards

  /// A cast reaches a registered writer; one to a dead pid is lost.
  val writerTakes = writer.state == Up or (writer.state == Starting and cfg.stampBeforeReplay)

  def toWriter(ops: Set[Op]): Set[Op] = if (writerTakes) writer.buf.union(ops) else writer.buf

  action init = all {
    shards' = Keys.mapBy(_ => {
      wal: [], ckpt: 0, redo: [], journal: [], synced: 0, pend: Set(), group: NoGroup,
      ver: 0, disp: 0, replaying: false,
    }),
    index' = { journal: [], synced: 0 },
    writer' = { state: Up, buf: Set() },
    rebuild' = Idle,
    opening' = Settled,
    stale' = false,
    clock' = 0,
    spent' = { events: 0, installs: 0, crashes: 0, writerCrashes: 0, saturations: 0, cleanReopens: 0 },
  }

  /// Every write of the index goes through here: a run that would grow its
  /// journal past `MaxIndexEntries` is not taken.
  action move(sh: str -> Shard, ix: Index, w: Writer, rb: Rebuild): bool = all {
    ix.journal.length() <= MaxIndexEntries,
    shards' = sh,
    index' = ix,
    writer' = w,
    rebuild' = rb,
    opening' = opening,
    stale' = stale,
    clock' = clock,
    spent' = spent,
  }

  action moveShard(k: str, s: Shard, w: Writer): bool = move(shards.set(k, s), index, w, rebuild)

  /// Shard `k` takes a write: none while it replays, has ops to dispatch,
  /// an open install group or events to re-present.
  def writable(s: Shard): bool = not(s.replaying) and s.pend == Set() and s.group == NoGroup and s.redo == []

  action write(k: str, vs: List[str]): bool = {
    val s = shards.get(k)
    val evs = range(0, vs.length()).foldl([], (l, i) => l.append({ v: vs[i], h: clock + i + 1 }))
    all {
      writable(s),
      spent.events + vs.length() <= MaxEvents,
      shards' = shards.set(k, applied(k, { ...s, wal: s.wal.concat(evs) }, evs)),
      index' = index,
      writer' = writer,
      rebuild' = rebuild,
      opening' = opening,
      stale' = stale,
      clock' = clock + vs.length(),
      spent' = { ...spent, events: spent.events + vs.length() },
    }
  }

  /// The applier re-presents the next event a crash left unclaimed.
  action redo(k: str): bool = {
    val s = shards.get(k)
    all {
      not(s.replaying), s.pend == Set(), s.group == NoGroup, s.redo != [],
      moveShard(k, applied(k, { ...s, redo: s.redo.tail() }, [s.redo.head()]), writer),
    }
  }

  /// A catalogue install of value `v` at HLC `h0` (`install_cell/6`). In a
  /// group, the first cell syncs the primary first, and the ops wait for
  /// the group to settle. The applier runs the group in one call, so no
  /// other write of the shard runs meanwhile.
  action install(k: str, v: str, h0: int): bool = {
    val s = shards.get(k)
    val iv = s.ver + 1
    val ops = if (cfg.installMode == NoIndexOps) Set() else diff(k, value(s.journal), v, order(iv, h0), iv)
    val grouped = cfg.installMode == Synced or cfg.installMode == Unsynced
    val s2 = {
      ...s,
      journal: appended(s.journal, v, h0, iv, ops),
      ver: iv,
      synced: if (cfg.syncBeforeInstall and s.group == NoGroup and grouped) s.journal.length() else s.synced,
      group: if (grouped) InGroup(groupOps(s.group).union(ops)) else s.group,
      pend: if (grouped) s.pend else ops,
    }
    all {
      not(s.replaying), s.pend == Set(), s.redo == [],
      spent.installs < MaxInstalls,
      1 <= h0, h0 <= clock,
      shards' = shards.set(k, s2),
      index' = index,
      writer' = writer,
      rebuild' = rebuild,
      opening' = opening,
      stale' = stale,
      clock' = clock,
      spent' = { ...spent, installs: spent.installs + 1 },
    }
  }

  /// The end of an install group (`settle_install/3`): when it has ops,
  /// sync the primary (unless `Unsynced`), then dispatch them.
  action installSettle(k: str): bool = {
    val s = shards.get(k)
    val ops = groupOps(s.group)
    all {
      s.group != NoGroup,
      moveShard(k, {
        ...s,
        synced: if (cfg.installMode == Synced and ops != Set()) s.journal.length() else s.synced,
        disp: s.ver,
        group: NoGroup,
      }, { ...writer, buf: toWriter(ops) }),
    }
  }

  action dispatch(k: str): bool = {
    val s = shards.get(k)
    all {
      s.pend != Set(),
      moveShard(k, { ...s, pend: Set(), disp: s.ver }, { ...writer, buf: toWriter(s.pend) }),
    }
  }

  /// The writer's backlog is full: the ops are dropped, the index marked
  /// and a rebuild requested.
  action saturationDrop(k: str): bool = {
    val s = shards.get(k)
    nondet j = markUnmarked(rebuild, index.journal).oneOf()
    all {
      s.pend != Set(),
      spent.saturations < MaxSaturations,
      j.length() <= MaxIndexEntries,
      shards' = shards.set(k, { ...s, pend: Set(), disp: s.ver }),
      index' = { ...index, journal: j },
      writer' = writer,
      rebuild' = request(rebuild),
      opening' = opening,
      stale' = stale,
      clock' = clock,
      spent' = { ...spent, saturations: spent.saturations + 1 },
    }
  }

  /// `do_flush`: the writer's buffer as one index batch.
  action flush: bool = all {
    writer.state == Up,
    writer.buf != Set(),
    move(shards, { ...index, journal: flushed(index.journal, writer.buf) }, { ...writer, buf: Set() }, rebuild),
  }

  action writerCrash: bool = all {
    writer.state != Down,
    spent.writerCrashes < MaxWriterCrashes,
    shards' = shards,
    index' = index,
    writer' = { state: Down, buf: Set() },
    rebuild' = rebuild,
    opening' = opening,
    stale' = stale,
    clock' = clock,
    spent' = { ...spent, writerCrashes: spent.writerCrashes + 1 },
  }

  /// The first half of `init/1`. With intents the writer registers, or
  /// (ablation) replays the leftover intents first; a dispatch before the
  /// second half reaches it only when it registered. Without intents a
  /// restarted writer requests a rebuild.
  action writerRegister: bool = all {
    writer.state == Down,
    if (cfg.intents)
      move(if (cfg.stampBeforeReplay) shards else replaySynced, index, {
        state: Starting,
        buf: if (cfg.stampBeforeReplay) writer.buf else allIntentOps,
      }, restarted(rebuild))
    else move(shards, index, { ...writer, state: Up }, request(restarted(rebuild))),
  }

  action writerReplay: bool = all {
    writer.state == Starting,
    move(if (cfg.stampBeforeReplay) replaySynced else shards, index, {
      state: Up,
      buf: if (cfg.stampBeforeReplay) writer.buf.union(allIntentOps) else writer.buf,
    }, rebuild),
  }

  /// The rebuild removes the trust mark, syncs the index, wipes it and
  /// resets the writer's buffer.
  action rebuildStart: bool = {
    val u = if (cfg.rebuildUnmarks) [Unmark] else []
    val j = index.journal.concat(u).concat(if (cfg.rebuildWipes) [Wipe] else [])
    all {
      rebuild == Requested,
      writer.state == Up,
      move(shards, {
        journal: j,
        synced: if (cfg.syncBeforeWipe) index.journal.length() + u.length() else index.synced,
      }, { ...writer, buf: Set() }, Running({ restarted: false, folded: Set(), again: false })),
    }
  }

  /// The rebuild's re-fold of shard `k`, run in its applier between two of
  /// its batches.
  action rebuildFold(k: str): bool = {
    val s = shards.get(k)
    val iv = s.ver + 1
    val ops = terms(value(s.journal)).map(t => { t: t, k: k, live: true, ord: order(iv, hlc(s.journal)), iv: iv })
    all {
      match rebuild { | Running(r) => not(r.folded.contains(k)) | _ => false },
      not(s.replaying), s.pend == Set(), s.group == NoGroup,
      move(shards.set(k, { ...s, ver: iv, disp: iv }), index,
        { ...writer, buf: if (cfg.rebuildRefolds) toWriter(ops) else writer.buf },
        match rebuild { | Running(r) => Running({ ...r, folded: r.folded.union(Set(k)) }) | _ => rebuild }),
    }
  }

  /// The orchestrator flushes the writer, then writes the trust mark. A
  /// request that arrived during the run removes it again.
  action rebuildMark: bool = {
    val ok = writer.state == Up and match rebuild { | Running(r) => not(r.restarted) | _ => false }
    val j = if (ok) flushed(index.journal, writer.buf) else index.journal
    val mark = ok or not(cfg.markNeedsFlush)
    val again = match rebuild { | Running(r) => r.again | _ => false }
    all {
      match rebuild { | Running(r) => r.folded == Keys | _ => false },
      writer.state != Starting,
      move(shards, {
        journal: if (mark) j.append(Batch({ ops: Set(), mark: true })) else j,
        synced: if (mark and cfg.syncBeforeMark) j.length() else index.synced,
      }, { ...writer, buf: if (ok) Set() else writer.buf },
        if (not(mark)) Requested else if (again and cfg.keepRequests) Remarking else Idle),
    }
  }

  action rebuildRemark: bool = {
    nondet j = unmarked(index.journal).oneOf()
    all {
      rebuild == Remarking,
      move(shards, { ...index, journal: j }, writer, Requested),
    }
  }

  /// A checkpoint without the barrier: sync, then record what was applied.
  action checkpoint(k: str): bool = {
    val s = shards.get(k)
    all {
      s.synced < s.journal.length() or index.synced < index.journal.length() or s.ckpt < appliedCount(s),
      move(shards.set(k, { ...s, synced: s.journal.length(), ckpt: appliedCount(s) }),
        { ...index, synced: index.journal.length() }, writer, rebuild),
    }
  }

  /// The barrier of shard `k` (`drive_secondary_indexes/1`): flush the
  /// writer, or with the writer down mark for rebuild; sync and checkpoint;
  /// then clear the shard's intents up to the bound, as its own primary
  /// write, which this barrier does not sync.
  action barrier(k: str): bool = {
    val s = shards.get(k)
    val s2 = { ...s, synced: s.journal.length(), ckpt: appliedCount(s) }
    all {
      writer.state != Starting,
      or {
        writer.buf != Set(),
        s.synced < s.journal.length(),
        index.synced < index.journal.length(),
        s.ckpt < appliedCount(s),
        cfg.intents and s.disp > clearedUpTo(s.journal),
      },
      if (writer.state == Up) {
        val j = flushed(index.journal, writer.buf)
        val a = match cfg.clearBound {
          | BySource => indexVersion(j, k)
          | ByWriter => maxOf(Keys.map(q => indexVersion(j, q)))
          | ByDispatched => s.disp
          | ByDrawn => s.ver
        }
        val clears = cfg.intents and a > clearedUpTo(s.journal) and (cfg.clearMarked or rebuild == Idle)
        move(shards.set(k, { ...s2, journal: if (clears) s.journal.append(Clear(a)) else s.journal }),
          { journal: j, synced: if (cfg.syncBeforeClear) j.length() else index.synced },
          { ...writer, buf: Set() }, rebuild)
      } else {
        nondet j = markUnmarked(rebuild, index.journal).oneOf()
        move(shards.set(k, s2), { ...index, journal: j }, writer, request(rebuild))
      },
    }
  }

  /// An open after a close or a crash, with primaries `p` and index `j`.
  /// Each shard's counter starts at the highest version recorded. With
  /// intents the writers start before the primary shards
  /// (`open_table_provision`), each shard replays its leftover intents
  /// before its applier starts, and an index without the trust mark is
  /// rebuilt.
  action opened(sh: str -> Shard, j: Index, clean: bool, sp: Spent): bool = {
    def ver(k) = match cfg.versionSource {
      | Recorded => max2(recordedVersion(sh.get(k).journal), indexVersion(j.journal, k))
      | IntentsOnly => recordedVersion(sh.get(k).journal)
      | Reset => 0
    }
    all {
      j.journal.length() <= MaxIndexEntries,
      shards' = Keys.mapBy(k => {
        ...sh.get(k),
        ver: ver(k),
        disp: if (cfg.intents and cfg.openDispatched == AtCleared) clearedUpTo(sh.get(k).journal) else ver(k),
        replaying: cfg.intents,
      }),
      index' = j,
      writer' = { state: Up, buf: Set() },
      rebuild' =
        if (not(trusted(j.journal)) or (not(cfg.intents) and cfg.rebuildAtOpen and not(clean))) Requested else Idle,
      opening' = if (cfg.intents and trusted(j.journal)) Freshening({ owed: Set(), at: j.journal.length() }) else Settled,
      stale' = false,
      clock' = clock,
      spent' = sp,
    }
  }

  /// A crash, then an open, the primaries keeping `p` and the index `j`.
  /// Each store keeps its synced entries and, of the rest, what its `Keeps`
  /// allows; every event the checkpoint does not claim is re-presented.
  action crash(p: str -> List[PEntry], j: List[IEntry]): bool = all {
    spent.crashes < MaxCrashes,
    Keys.forall(k => survivors(shards.get(k).journal, shards.get(k).synced, cfg.crashKeeps).contains(p.get(k))),
    survivors(index.journal, index.synced, cfg.indexCrashKeeps).contains(j),
    opened(Keys.mapBy(k => {
      val s = shards.get(k)
      {
        ...s,
        journal: p.get(k),
        synced: p.get(k).length(),
        redo: s.wal.slice(s.ckpt, s.wal.length()),
        pend: Set(),
        group: NoGroup,
      }
    }), { journal: j, synced: j.length() }, false, { ...spent, crashes: spent.crashes + 1 }),
  }

  action crashAndOpen: bool = {
    val kept = Keys.mapBy(k => survivors(shards.get(k).journal, shards.get(k).synced, cfg.crashKeeps))
    nondet p = Keys.setOfMaps(Keys.map(k => kept.get(k)).flatten())
      .filter(m => Keys.forall(k => kept.get(k).contains(m.get(k))))
      .oneOf()
    nondet j = survivors(index.journal, index.synced, cfg.indexCrashKeeps).oneOf()
    crash(p, j)
  }

  /// A clean close, then an open. The close stops the primaries with
  /// nothing left to apply or dispatch, syncs both stores and checkpoints.
  /// Without intents it first flushes the writer and, the index being
  /// trusted, stamps the clean flag, which the open finds, so it runs no
  /// rebuild. With intents the close discards the writer's buffer
  /// (`bondy_oplog_secondary_writer:reset/1`) and the open replays it.
  action cleanReopen: bool = {
    val j = if (cfg.intents) index.journal else flushed(index.journal, writer.buf)
    all {
      spent.cleanReopens < MaxCleanReopens,
      Keys.forall(k => shards.get(k).redo == [] and shards.get(k).pend == Set() and shards.get(k).group == NoGroup),
      writer.state == Up,
      rebuild == Idle,
      trusted(index.journal),
      opened(Keys.mapBy(k => {
        val s = shards.get(k)
        { ...s, synced: s.journal.length(), ckpt: appliedCount(s) }
      }), { journal: j, synced: j.length() }, true, { ...spent, cleanReopens: spent.cleanReopens + 1 }),
    }
  }

  /// Shard `k` replays its leftover intents through the dispatch path,
  /// after its row is registered and before its applier starts. A barrier
  /// of a shared instance may run meanwhile.
  action replayOpen(k: str): bool = {
    val s = shards.get(k)
    val ops = intentOps(s.journal)
    all {
      s.replaying,
      shards' = shards.set(k, { ...s, disp: maxOf(ops.map(o => o.iv).union(Set(s.disp))), replaying: false }),
      index' = index,
      writer' = { ...writer, buf: toWriter(ops) },
      rebuild' = rebuild,
      opening' = match opening {
        | Freshening(f) => Freshening({ ...f, owed: f.owed.union(ops) })
        | Settled => Settled
      },
      stale' = stale,
      clock' = clock,
      spent' = spent,
    }
  }

  /// A trusting open, once every shard has replayed, flushes the writer
  /// and freshens the index, which lets a bounded-lag read through
  /// (`bondy_db:cold_start_indexes/3`). A call to a writer still in
  /// `init/1` waits for it. A call to a dead writer fails, and the open
  /// then leaves the index unfreshened: the restarted writer replays the
  /// intents.
  action freshen: bool = {
    val f = match opening { | Freshening(f) => f | Settled => { owed: Set(), at: 0 } }
    val didFlush = cfg.openFlushes and writer.state == Up
    val j = if (didFlush) flushed(index.journal, writer.buf) else index.journal
    all {
      opening != Settled,
      Keys.forall(k => not(shards.get(k).replaying)),
      not(cfg.openFlushes and writer.state == Starting),
      j.length() <= MaxIndexEntries,
      shards' = shards,
      rebuild' = rebuild,
      opening' = Settled,
      clock' = clock,
      spent' = spent,
      if (cfg.openFlushes and not(didFlush) and cfg.freshenNeedsFlush)
        all { index' = index, writer' = writer, stale' = stale }
      else all {
        index' = { ...index, journal: j },
        writer' = { ...writer, buf: if (didFlush) Set() else writer.buf },
        stale' = (trusted(j) and f.owed.exists(o => not(reflected(j, o, f.at)))),
      },
    }
  }

  action step = any {
    {
      nondet k = Keys.oneOf()
      any {
        { nondet vs = batches(MaxBatch).oneOf()
          write(k, vs) },
        { nondet v = Vals.oneOf()
          nondet h0 = 1.to(clock).oneOf()
          install(k, v, h0) },
        redo(k),
        dispatch(k),
        saturationDrop(k),
        rebuildFold(k),
        checkpoint(k),
        barrier(k),
        replayOpen(k),
        installSettle(k),
      }
    },
    flush,
    writerCrash,
    writerRegister,
    writerReplay,
    rebuildStart,
    rebuildMark,
    rebuildRemark,
    crashAndOpen,
    cleanReopen,
    freshen,
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val quiescent = and {
    Keys.forall(k => {
      val s = shards.get(k)
      s.redo == [] and s.pend == Set() and s.group == NoGroup and not(s.replaying)
    }),
    writer.buf == Set(),
    writer.state == Up,
    rebuild == Idle,
    trusted(index.journal),
  }

  /// Once nothing is in flight and the index is trusted, it holds exactly
  /// the terms of the primary.
  val indexMatchesPrimary = quiescent implies Keys.forall(k => Vals.forall(t =>
    live(index.journal, t, k) == terms(value(shards.get(k).journal)).contains(t)))

  /// An index the open freshened holds every op the open replayed.
  val freshMeansComplete = not(stale)

  val syncedWithin = index.synced <= index.journal.length()

  val safety = and { syncedWithin, indexMatchesPrimary, freshMeansComplete }
}
