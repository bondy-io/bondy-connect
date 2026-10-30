// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// One key of a per-shard read cache in front of a projection
/// (`bondy_oplog_cache_ets`, `bondy_oplog_core`).
///
/// Writers write the projection, then invalidate the cache entry in two
/// halves: advance the shard's generation, and delete the entry, in the order
/// `cfg.bumpFirst` picks. A reader on a miss takes the generation as a ticket,
/// reads the projection and fills the cache. With `cfg.useTicket` it then
/// re-checks the generation and removes the entry if the generation moved;
/// with `cfg.deleteOwnObject` only when the entry is the value it filled.
/// Eviction may drop the entry at any time.
module ReadCache {
  type Cfg = { useTicket: bool, bumpFirst: bool, deleteOwnObject: bool }

  const Readers: Set[str]
  const Writers: Set[str]
  const MaxW: int
  const cfg: Cfg

  type Entry = None | Some(int)

  type Shard = { src: int, written: int, gen: int, cache: Entry }

  type Fill = { ticket: int, seen: int }

  type Reader = RIdle | Reading(int) | Filling(Fill) | Checking(Fill)

  type Writer = WIdle | Written | HalfInvalidated

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def write(s: Shard): Shard =
    { ...s, written: s.written + 1, src: s.written + 1 }

  /// The first or the second half of an invalidation.
  pure def invalidate(c: Cfg, s: Shard, firstHalf: bool): Shard =
    if (firstHalf == c.bumpFirst) { ...s, gen: s.gen + 1 }
    else { ...s, cache: None }

  pure def recheck(c: Cfg, s: Shard, f: Fill): Shard =
    val moved = s.gen != f.ticket
    val mine = not(c.deleteOwnObject) or s.cache == Some(f.seen)
    if (moved and mine) { ...s, cache: None } else s

  // ===========================================================================
  // State machine
  // ===========================================================================

  var shard: Shard
  var readers: str -> Reader
  var writers: str -> Writer

  action init = all {
    shard' = { src: 0, written: 0, gen: 0, cache: None },
    readers' = Readers.mapBy(_ => RIdle),
    writers' = Writers.mapBy(_ => WIdle),
  }

  action writer(w: str): bool = all {
    readers' = readers,
    match writers.get(w) {
      | WIdle => all {
          shard.written < MaxW,
          shard' = write(shard),
          writers' = writers.set(w, Written),
        }
      | Written => all {
          shard' = invalidate(cfg, shard, true),
          writers' = writers.set(w, HalfInvalidated),
        }
      | HalfInvalidated => all {
          shard' = invalidate(cfg, shard, false),
          writers' = writers.set(w, WIdle),
        }
    },
  }

  action reader(r: str): bool = all {
    writers' = writers,
    match readers.get(r) {
      | RIdle => all {
          shard.cache == None,
          shard' = shard,
          readers' = readers.set(r, Reading(shard.gen)),
        }
      | Reading(ticket) => all {
          shard' = shard,
          readers' = readers.set(r, Filling({ ticket: ticket, seen: shard.src })),
        }
      | Filling(f) => all {
          shard' = { ...shard, cache: Some(f.seen) },
          readers' = readers.set(r, if (cfg.useTicket) Checking(f) else RIdle),
        }
      | Checking(f) => all {
          shard' = recheck(cfg, shard, f),
          readers' = readers.set(r, RIdle),
        }
    },
  }

  action evict = all {
    shard.cache != None,
    shard' = { ...shard, cache: None },
    readers' = readers,
    writers' = writers,
  }

  action step = {
    nondet w = Writers.oneOf()
    nondet r = Readers.oneOf()
    any { writer(w), reader(r), evict }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val noDeadlock = enabled(step)

  val coherent = shard.cache == None or shard.cache == Some(shard.src)

  val writersIdle = writers.keys().forall(w => writers.get(w) == WIdle)

  val readersIdle = readers.keys().forall(r => readers.get(r) == RIdle)

  /// Once every process is idle, the cache holds nothing or the projection's
  /// value.
  val settledCoherent = (writersIdle and readersIdle) implies coherent

  /// Read-after-write: once writers are idle, a hit never returns an older
  /// value, whatever readers are doing.
  val writersIdleCoherent = writersIdle implies coherent
}
