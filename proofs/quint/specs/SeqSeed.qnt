// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module SeqSeedTypes {
  /// What a restart seeds the sequence counter from, before the WAL replay.
  type SeedRule =
    | LiveTree             // the durable MST root
    | CkptFrontier         // the root and the checkpoint frontier
    | CkptFrontierAndWal   // the root, the checkpoint frontier and the WAL

  /// Which WAL entries the retention sweep may drop.
  type Retention =
    | BelowCheckpointWatermark   // at or below the checkpoint's watermark
    | HeldByDurableRoot          // any the durable root holds

  type Cfg = {
    seedRule: SeedRule,
    retention: Retention,
    frontierBeforeTruncate: bool,
    mintAfterReplay: bool,
  }
}

/// Whether a `bondy_oplog` instance's per-origin sequence counter survives a
/// restart: which durable sources must seed it, and in which order
/// compaction must write them. `Oplog_Model.thy` takes dot uniqueness
/// (`origin_unique`) as a hypothesis; this model checks it against the
/// minter's persistence protocol, with a clean stop and a crash. One replica,
/// one origin.
///
/// The steps, and the code each one stands for:
///   - `reserve`: one seq from the volatile counter (`atomics:add_get`);
///   - `walAppend`: the WAL append and its acknowledgement, lowest reserved seq
///     first, as the WAL process serialises appends;
///   - `apply`: the applier applies the next WAL entry past its cursor,
///     advances the frontier, and the instance installs it in the in-memory
///     MST, raising the counter to it;
///   - `flushRoot`: the staged MST root becomes durable;
///   - `dropWal`: the retention sweep, by `cfg.retention`;
///   - `truncateFlush(w)` then `truncateCheckpoint`: compaction truncates the
///     MST at or below `w` and flushes the root, then writes the checkpoint
///     (frontier and watermark `w`). With `cfg.frontierBeforeTruncate` the
///     frontier is written first, under the old watermark;
///   - `stop` writes the frontier to the checkpoint and loses the volatile
///     state; `crash` loses it and any unfinished truncation's checkpoint;
///   - `restart` seeds the counter by `cfg.seedRule` and resumes the applier
///     at `max(last root key, watermark)`; the replay raises the counter.
///
/// With `cfg.mintAfterReplay` no mint precedes the end of the WAL replay.
///
/// A seq is a positive integer, so 0 stands for "none" in every seq-valued
/// field.
module SeqSeed {
  import SeqSeedTypes.*
  import Ints.* from "../lib/Ints"

  const MaxSeq: int
  const cfg: Cfg

  type Volatile = {
    seqRef: int,
    inflight: Set[int],
    cursor: int,
    fr: int,
    mem: Set[int],
    // the key of a truncation whose root is flushed and whose checkpoint
    // is not yet written
    flushedAt: int,
  }

  type Durable = { wal: Set[int], tree: Set[int], ckpt: int, wm: int }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def maxOf(s: Set[int]): int = s.fold(0, (m, x) => max2(m, x))

  pure def minOf(s: Set[int]): int =
    s.fold(MaxSeq + 1, (m, x) => if (x < m) x else m)

  pure def canMint(c: Cfg, v: Volatile, d: Durable): bool =
    not(c.mintAfterReplay) or v.cursor == maxOf(d.wal)

  pure def unapplied(v: Volatile, d: Durable): Set[int] =
    d.wal.filter(s => s > v.cursor)

  pure def droppable(c: Cfg, d: Durable): Set[int] = match c.retention {
    | BelowCheckpointWatermark => d.wal.filter(s => s <= d.wm)
    | HeldByDurableRoot => d.wal.intersect(d.tree)
  }

  pure def seed(c: Cfg, d: Durable): int = match c.seedRule {
    | LiveTree => maxOf(d.tree)
    | CkptFrontier => max2(d.ckpt, maxOf(d.tree))
    | CkptFrontierAndWal => maxOf(Set(d.ckpt).union(d.tree).union(d.wal))
  }

  /// What a stop or a crash leaves of the volatile state. A restart
  /// overwrites every field.
  pure val lost: Volatile = {
    seqRef: 0, inflight: Set(), cursor: 0, fr: 0, mem: Set(),
    flushedAt: 0,
  }

  pure def booted(c: Cfg, d: Durable): Volatile = {
    seqRef: seed(c, d),
    inflight: Set(),
    cursor: max2(maxOf(d.tree), d.wm),
    fr: max2(d.ckpt, maxOf(d.tree)),
    mem: Set(),
    flushedAt: 0,
  }

  // ===========================================================================
  // State machine
  // ===========================================================================

  /// The instance process is running.
  var up: bool
  var vol: Volatile
  var disk: Durable
  /// Every seq whose append was acknowledged.
  var acked: Set[int]

  action init = all {
    up' = true,
    vol' = lost,
    disk' = { wal: Set(), tree: Set(), ckpt: 0, wm: 0 },
    acked' = Set(),
  }

  action become(v: Volatile, d: Durable, a: Set[int]): bool = all {
    up' = up, vol' = v, disk' = d, acked' = a,
  }

  action reserve = all {
    up,
    canMint(cfg, vol, disk),
    vol.seqRef < MaxSeq,
    val s = vol.seqRef + 1
    become({ ...vol, seqRef: s, inflight: vol.inflight.union(Set(s)) }, disk, acked),
  }

  action walAppend = all {
    up,
    vol.inflight != Set(),
    val s = minOf(vol.inflight)
    become(
      { ...vol, inflight: vol.inflight.exclude(Set(s)) },
      { ...disk, wal: disk.wal.union(Set(s)) },
      acked.union(Set(s)),
    ),
  }

  action apply = all {
    up,
    unapplied(vol, disk) != Set(),
    val s = minOf(unapplied(vol, disk))
    become(
      {
        ...vol,
        cursor: s,
        fr: max2(vol.fr, s),
        mem: vol.mem.union(Set(s)),
        seqRef: max2(vol.seqRef, s),
      },
      disk,
      acked,
    ),
  }

  action flushRoot = all {
    up,
    vol.mem != Set(),
    become({ ...vol, mem: Set() }, { ...disk, tree: disk.tree.union(vol.mem) }, acked),
  }

  action dropWal = all {
    up,
    droppable(cfg, disk) != Set(),
    become(vol, { ...disk, wal: disk.wal.exclude(droppable(cfg, disk)) }, acked),
  }

  action truncateFlush(w: int): bool = all {
    up,
    vol.flushedAt == 0,
    val mst = disk.tree.union(vol.mem)
    all {
      mst.contains(w),
      become(
        { ...vol, mem: Set(), flushedAt: w },
        {
          ...disk,
          tree: mst.filter(s => s > w),
          ckpt: if (cfg.frontierBeforeTruncate) vol.fr else disk.ckpt,
        },
        acked,
      ),
    },
  }

  action truncateCheckpoint = all {
    up,
    vol.flushedAt != 0,
    become({ ...vol, flushedAt: 0 }, { ...disk, ckpt: vol.fr, wm: vol.flushedAt }, acked),
  }

  action stop = all {
    up,
    vol.flushedAt == 0,
    up' = false, vol' = lost, disk' = { ...disk, ckpt: vol.fr }, acked' = acked,
  }

  action crash = all {
    up,
    up' = false, vol' = lost, disk' = disk, acked' = acked,
  }

  action restart = all {
    not(up),
    up' = true, vol' = booted(cfg, disk), disk' = disk, acked' = acked,
  }

  action step = {
    nondet w = 1.to(MaxSeq).oneOf()
    any {
      reserve, walAppend, apply, flushRoot, dropWal,
      truncateFlush(w), truncateCheckpoint, stop, crash, restart,
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val noDeadlock = enabled(step)

  /// Dot uniqueness for one origin: a seq about to be handed out never
  /// already carries an acknowledged event.
  val dotUnique = vol.inflight.intersect(acked) == Set()

  /// Wherever a mint is possible, the counter is exactly the acknowledged
  /// and reserved seqs, so the sequence has no gap. It fails before
  /// `dotUnique` does, as soon as a mint is possible.
  val seedExact =
    (up and canMint(cfg, vol, disk)) implies acked.union(vol.inflight) == 1.to(vol.seqRef)

  /// The durable sources never hold a seq that was not acknowledged.
  val durableSound = and {
    disk.wal.subseteq(acked),
    disk.tree.subseteq(acked),
    vol.mem.subseteq(acked),
    disk.ckpt <= maxOf(acked),
  }
}
