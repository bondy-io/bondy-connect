// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module RibReadingTypes {
  /// When the owner's self-heal writes a reading after a merge of its own
  /// cell. It always writes when the cell's value differs from `live`.
  type HealRule =
    // on every merge (`bondy_registry_rib`'s `restate/4`)
    | HealAlways
    | HealWhenWrong({
        // also when the owner's cell is empty
        onAbsent: bool,
        // also when the top reading carries another origin
        onForeignTop: bool,
      })

  type Cfg = {
    // a reboot's physical clock is still past every stamp a replica holds
    assumeWallAhead: bool,
    // the DB keeps its origin, seqs and state across a reboot; otherwise it
    // is empty and takes a fresh origin
    durable: bool,
    // the DB's storage can be lost in a running VM
    reopen: bool,
    selfHeal: bool,
    heal: HealRule,
    reap: bool,
    // a swept origin is never rescanned
    sweepOnce: bool,
    // a sweep also zeroes a stub whose cell is gone
    stubFollowsCell: bool,
  }
}

/// A registry RIB cell's count (`bondy_oplog_crdt_owned_reading`): the
/// owner replicates its latest reading of the live count, a stamp and a
/// count, and a replica's value is the count of the highest-stamped reading
/// it holds. Nothing corrects the count by arithmetic.
///
/// A local writer (a registration or unregistration, a self-heal, a
/// restore) takes three interleavable steps: a stamp from the owner's
/// clock, a read of the live count, a write of the reading under the DB's
/// current origin. The row op that changes `live` precedes the stamp.
///
/// A reboot ends the sessions (`live` becomes 0, in-flight writers are
/// lost) and restarts the HLC at 0; the physical clock moves on, or back by
/// up to `StepBack`. A reopen loses the DB's storage in a running VM:
/// sessions survive, the DB takes a fresh origin, and a restore writer
/// restates the cell. Self-heal runs on the owner after a merge of its own
/// cell. A replica reaps an origin no member advertises once it is in that
/// replica's frontier. A peer's stub, its routing view, changes only on a
/// merge on that peer.
///
/// The properties hold on settled states, where no action is enabled,
/// except a run cut short by the stamp bound.
module RibReading {
  import RibReadingTypes.*
  import Ints.* from "../lib/Ints"

  const Peers: Set[str]
  const MaxOps: int
  const MaxResets: int
  const MaxStamp: int
  /// HLC values per physical tick.
  const K: int
  const MaxWall: int
  const StepBack: int
  const cfg: Cfg

  pure val Owner = "owner"
  pure val Replicas = Peers.union(Set(Owner))
  pure val Writers = 1.to(2)
  pure val Origins = 1.to(MaxResets + 1)

  type Reading = { org: int, seq: int, stamp: int, count: int }

  type Writer = Idle | Stamping | Stamped(int)

  type OwnerState = {
    // the DB's current origin
    org: int,
    // the owner's live registrations: the truth
    live: int,
    ops: int,
    resets: int,
    // the HLC, packed as physical * K + logical
    clock: int,
    // the physical clock
    wall: int,
    minted: int -> int,
    writers: int -> Writer,
    healPending: bool,
  }

  type Replica = {
    // the frontier
    applied: Set[Reading],
    // what the cell holds after reaps
    cell: Set[Reading],
    swept: Set[int],
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def ranks(a: Reading, b: Reading): bool =
    a.stamp < b.stamp or (a.stamp == b.stamp and a.count <= b.count)

  /// The top reading: the highest stamp, then the highest count, then the
  /// highest origin and seq, so the result does not depend on the order the
  /// fold visits the set. Only `onForeignTop` reads the top's origin.
  pure def top(s: Set[Reading]): Reading =
    s.fold({ org: 0, seq: 0, stamp: -1, count: 0 }, (m, e) =>
      if (ranks(e, m) and not(ranks(m, e))) m
      else if (ranks(m, e) and not(ranks(e, m))) e
      else if (e.org > m.org or (e.org == m.org and e.seq > m.seq)) e
      else m)

  pure def value(s: Set[Reading]): int = if (s == Set()) 0 else top(s).count

  pure def topStamp(s: Set[Reading]): int = if (s == Set()) 0 else top(s).stamp

  /// `bondy_connect_hlc:now/1`: the physical clock if it is ahead, else the
  /// next logical value; a logical overflow carries into the physical part,
  /// which the packing makes `+ 1`.
  pure def hlcNow(wall: int, c: int): int = if (wall * K > c) wall * K else c + 1

  pure def heals(c: Cfg, o: OwnerState, cell: Set[Reading]): bool = match c.heal {
    | HealAlways => true
    | HealWhenWrong(w) => or {
        cell == Set() and w.onAbsent,
        cell != Set() and value(cell) != o.live,
        cell != Set() and w.onForeignTop and top(cell).org != o.org,
      }
  }

  pure def maxOf(s: Set[int]): int = s.fold(0, (m, x) => max2(m, x))

  // ===========================================================================
  // State machine
  // ===========================================================================

  var owner: OwnerState
  var replicas: str -> Replica
  /// Each peer's routing view of the count.
  var stub: str -> int

  pure val empty: Replica = { applied: Set(), cell: Set(), swept: Set() }

  action init = all {
    owner' = {
      org: 1, live: 0, ops: 0, resets: 0, clock: 0, wall: 1,
      minted: Origins.mapBy(_ => 0),
      writers: Writers.mapBy(_ => Idle),
      healPending: false,
    },
    replicas' = Replicas.mapBy(_ => empty),
    stub' = Peers.mapBy(_ => 0),
  }

  action setOwner(o: OwnerState): bool = all {
    owner' = o, replicas' = replicas, stub' = stub,
  }

  pure def spawn(o: OwnerState, w: int): OwnerState = { ...o, writers: o.writers.set(w, Stamping) }

  /// A registration (`d = 1`) or an unregistration (`d = -1`): the row op,
  /// then a writer.
  action rowOp(d: int, w: int): bool = all {
    owner.ops < MaxOps,
    owner.live + d >= 0,
    owner.writers.get(w) == Idle,
    setOwner({ ...spawn(owner, w), ops: owner.ops + 1, live: owner.live + d }),
  }

  action stamp(w: int): bool = all {
    owner.writers.get(w) == Stamping,
    val s = hlcNow(owner.wall, owner.clock)
    all {
      s <= MaxStamp,
      setOwner({ ...owner, clock: s, writers: owner.writers.set(w, Stamped(s)) }),
    },
  }

  action readAndWrite(w: int): bool = {
    val s = match owner.writers.get(w) { | Stamped(s) => s | Idle => -1 | Stamping => -1 }
    val e = {
      org: owner.org, seq: owner.minted.get(owner.org) + 1, stamp: s, count: owner.live,
    }
    all {
      s >= 0,
      owner' = {
        ...owner,
        minted: owner.minted.set(owner.org, e.seq),
        writers: owner.writers.set(w, Idle),
      },
      replicas' = replicas.setBy(Owner, x => {
        ...x, applied: x.applied.union(Set(e)), cell: x.cell.union(Set(e)),
      }),
      stub' = stub,
    }
  }

  /// Every stamp a surviving reading carries, and the running clock. A
  /// reading no replica holds orders nothing.
  val issued: Set[int] =
    Replicas.map(r => replicas.get(r).applied.map(e => e.stamp)).flatten().union(Set(owner.clock))

  action reboot(wall: int): bool = all {
    owner.resets < MaxResets,
    wall >= owner.wall + 1 - StepBack,
    wall <= owner.wall + 1,
    wall >= 0,
    wall <= MaxWall,
    cfg.assumeWallAhead implies wall * K > maxOf(issued),
    val o = {
      ...owner,
      resets: owner.resets + 1, live: 0, clock: 0, wall: wall,
      writers: Writers.mapBy(_ => Idle),
    }
    if (cfg.durable) all {
      setOwner({ ...o, healPending: true }),
    } else all {
      owner' = { ...o, org: owner.org + 1, healPending: false },
      replicas' = replicas.set(Owner, empty),
      stub' = stub,
    },
  }

  action reopen(w: int): bool = all {
    cfg.reopen,
    not(cfg.durable),
    owner.resets < MaxResets,
    owner.writers.get(w) == Idle,
    owner' = {
      ...spawn(owner, w),
      resets: owner.resets + 1, org: owner.org + 1, healPending: false,
    },
    replicas' = replicas.setBy(Owner, x => { ...x, applied: Set(), cell: Set() }),
    stub' = stub,
  }

  /// A merge of `e` from `src` into `r`, after every earlier reading of
  /// its origin that `src` holds.
  action deliver(r: str, src: str, e: Reading): bool = all {
    r != src,
    val x = replicas.get(r)
    all {
      replicas.get(src).applied.contains(e),
      replicas.get(src).applied.forall(f =>
        (f.org == e.org and f.seq < e.seq) implies x.applied.contains(f)),
      not(x.applied.contains(e)),
      replicas' = replicas.set(r, {
        ...x, applied: x.applied.union(Set(e)), cell: x.cell.union(Set(e)),
      }),
      if (r == Owner) all {
        owner' = { ...owner, healPending: true }, stub' = stub,
      } else all {
        owner' = owner, stub' = stub.set(r, top(x.cell.union(Set(e))).count),
      },
    },
  }

  /// The owner's reaction to a merge of its own cell: its clock absorbs the
  /// cell's top stamp, as an HLC absorbs a received timestamp, and it
  /// writes a reading when `heals`.
  pure def absorbed(o: OwnerState, cell: Set[Reading]): OwnerState =
    { ...o, healPending: false, clock: max2(o.clock, topStamp(cell)) }

  action selfHealWrite(w: int): bool = all {
    cfg.selfHeal,
    owner.healPending,
    heals(cfg, owner, replicas.get(Owner).cell),
    owner.writers.get(w) == Idle,
    setOwner(spawn(absorbed(owner, replicas.get(Owner).cell), w)),
  }

  action selfHealQuiet = all {
    cfg.selfHeal,
    owner.healPending,
    not(heals(cfg, owner, replicas.get(Owner).cell)),
    setOwner(absorbed(owner, replicas.get(Owner).cell)),
  }

  action reap(r: str, o: int): bool = all {
    val x = replicas.get(r)
    all {
      cfg.reap,
      o != owner.org,
      x.applied.exists(e => e.org == o),
      not(cfg.sweepOnce and x.swept.contains(o)),
      x.cell.exists(e => e.org == o),
      replicas' = replicas.set(r, {
        ...x, cell: x.cell.filter(e => e.org != o), swept: x.swept.union(Set(o)),
      }),
      owner' = owner, stub' = stub,
    },
  }

  action tick = all {
    owner.wall < MaxWall,
    setOwner({ ...owner, wall: owner.wall + 1 }),
  }

  action stubSweep(p: str): bool = all {
    cfg.stubFollowsCell,
    replicas.get(p).cell == Set(),
    stub.get(p) != 0,
    stub' = stub.set(p, 0),
    owner' = owner, replicas' = replicas,
  }

  action step = any {
    { nondet d = Set(1, -1).oneOf()
      nondet w = Writers.oneOf()
      rowOp(d, w) },
    { nondet w = Writers.oneOf()
      any { stamp(w), readAndWrite(w), reopen(w), selfHealWrite(w) } },
    { nondet wall = 0.to(MaxWall).oneOf()
      reboot(wall) },
    { nondet r = Replicas.oneOf()
      nondet src = Replicas.oneOf()
      nondet e = replicas.get(src).applied.oneOf()
      deliver(r, src, e) },
    selfHealQuiet,
    { nondet r = Replicas.oneOf()
      nondet o = Origins.oneOf()
      reap(r, o) },
    { nondet p = Peers.oneOf()
      stubSweep(p) },
    tick,
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val settled = not(enabled(step))

  /// A writer blocked only by the stamp bound: a truncated run, not a
  /// settled one.
  val truncated = Writers.exists(w =>
    owner.writers.get(w) == Stamping and hlcNow(owner.wall, owner.clock) > MaxStamp)

  val settledCellIsTruth = (settled and not(truncated)) implies
    Replicas.forall(r => value(replicas.get(r).cell) == owner.live)

  val settledStubIsTruth = (settled and not(truncated)) implies
    Peers.forall(p => stub.get(p) == owner.live)

  val cellWithinFrontier = Replicas.forall(r => replicas.get(r).cell.subseteq(replicas.get(r).applied))
}
