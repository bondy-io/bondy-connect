// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module CellContextReapTypes {
  /// Where the reap finds the cells it may reach
  /// (`bondy_oplog_cell_utils:primary_cell_directory/4`).
  type Directory =
    // the adapter's own `cell_keys/2`: every cell the projection holds
    | CellKeys
    // the `cell_apply` keys still in the MST: a cell only while an event
    // of it survives compaction
    | MstWalk

  type Cfg = {
    // `reap_origins/2` may drop a departed origin's context entry
    reap: bool,
    // an op is delivered only once its author's stamped context is applied
    causalDelivery: bool,
    directory: Directory,
  }
}

/// Whether reaping a departed origin's entry from a tier_2 cell's causal
/// context (`bondy_oplog_crdt_aw_map:reap_origins/2`) changes what any
/// replica computes. The automatic driver
/// (`bondy_oplog_origin_retirement:reap_complement/3`) checks only that no
/// current member claims the origin.
///
/// The model has one cell. Its context `cc` is not a delivery filter: every
/// `drop_observed/2` call is passed the operation's stamped context, `put`
/// adds its dot unconditionally, and `cc` is read only to stamp the next
/// local write. Re-delivery is filtered upstream, by the event key already
/// in the local MST (`append_remote_install/3`) and by the applied frontier
/// (`append_remote_below_watermark/3`, `watermark_door/3`), which the reap
/// does not touch.
///
/// Compaction may drop any applied op from the tree, not only an
/// HLC-ordered prefix as truncation does: its states are a superset of the
/// real ones.
module CellContextReap {
  import CellContextReapTypes.*
  import Ints.* from "../lib/Ints"

  const Replicas: Set[str]
  const MaxSeq: int
  const cfg: Cfg

  /// Every replica is also an origin.
  pure val Origins = Replicas

  type Dot = { org: str, seq: int }

  type Kind = Put | Rmv

  /// An operation as it travels: its dot, its kind, and the context its
  /// author stamped at mint time, which every replica applies it against.
  type Op = { dot: Dot, kind: Kind, ctx: str -> int }

  type Replica = {
    // the cell's live dot-store
    dots: Set[Dot],
    // every dot this replica's dot-store has dropped
    removed: Set[Dot],
    cc: str -> int,
    // the applied frontier
    frontier: str -> int,
    // what the MST holds, and so what anti-entropy can still ship
    tree: Set[Op],
    applied: Set[Op],
    minted: int,
  }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  /// `dot_observed/2`.
  pure def observed(d: Dot, ctx: str -> int): bool = ctx.get(d.org) >= d.seq

  /// `put` drops what the writer's context observed and adds its own dot;
  /// `rmv` only drops. Neither reads the cell context.
  pure def newDots(ds: Set[Dot], op: Op): Set[Dot] = {
    val kept = ds.filter(d => not(observed(d, op.ctx)))
    match op.kind {
      | Put => kept.union(Set(op.dot))
      | Rmv => kept
    }
  }

  /// `cc_absorb/3`: the pointwise max of the cell context, the writer's
  /// context and the op's dot.
  pure def absorb(cc: str -> int, ctx: str -> int, d: Dot): str -> int =
    Origins.mapBy(o => {
      val m = max2(cc.get(o), ctx.get(o))
      if (o == d.org) max2(m, d.seq) else m
    })

  /// The fold of `op` into a replica's projection, shared by the local mint
  /// and the remote delivery. The frontier takes the op's seq
  /// (`batch_frontier/1`, `merge_frontier/2`).
  pure def folded(x: Replica, op: Op): Replica = {
    val dots = newDots(x.dots, op)
    {
      ...x,
      dots: dots,
      removed: x.removed.union(x.dots.exclude(dots)),
      cc: absorb(x.cc, op.ctx, op.dot),
      frontier: x.frontier.setBy(op.dot.org, s => max2(s, op.dot.seq)),
      applied: x.applied.union(Set(op)),
      tree: x.tree.union(Set(op)),
    }
  }

  /// Whether the replica's directory lists the cell. Keys are not modelled,
  /// so an op of any origin keeps it listed.
  pure def listed(c: Cfg, x: Replica): bool = match c.directory {
    | CellKeys => x.applied != Set()
    | MstWalk => x.tree != Set()
  }

  pure def holdsDotOf(x: Replica, o: str): bool = x.dots.exists(d => d.org == o)

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica
  /// The origins a current member owns.
  var live: Set[str]

  action init = all {
    replicas' = Replicas.mapBy(_ => {
      dots: Set(),
      removed: Set(),
      cc: Origins.mapBy(_ => 0),
      frontier: Origins.mapBy(_ => 0),
      tree: Set(),
      applied: Set(),
      minted: 0,
    }),
    live' = Origins,
  }

  action become(r: str, x: Replica): bool = all {
    replicas' = replicas.set(r, x),
    live' = live,
  }

  /// A local write, stamped with the cell's current context, which is what
  /// the reap shrinks.
  action mint(r: str, kind: Kind): bool = all {
    val x = replicas.get(r)
    val op = { dot: { org: r, seq: x.minted + 1 }, kind: kind, ctx: x.cc }
    all {
      live.contains(r),
      x.minted < MaxSeq,
      become(r, { ...folded(x, op), minted: op.dot.seq }),
    },
  }

  action deliver(r: str, op: Op): bool = all {
    val x = replicas.get(r)
    all {
      Replicas.exists(p => p != r and replicas.get(p).tree.contains(op)),
      not(x.tree.exists(q => q.dot == op.dot)),
      not(observed(op.dot, x.frontier)),
      cfg.causalDelivery implies Origins.forall(o => op.ctx.get(o) <= x.frontier.get(o)),
      become(r, folded(x, op)),
    },
  }

  action compact(r: str, op: Op): bool = all {
    val x = replicas.get(r)
    all {
      x.tree.contains(op),
      observed(op.dot, x.frontier),
      become(r, { ...x, tree: x.tree.exclude(Set(op)) }),
    },
  }

  /// A deliberate Partisan removal. The origin's events stay in every tree
  /// that holds them.
  action depart(o: str): bool = all {
    live.contains(o),
    live.size() > 1,
    live' = live.exclude(Set(o)),
    replicas' = replicas,
  }

  /// `reap_origins/2` under the membership-only driver, in a cell its
  /// directory lists: no current member claims `o`, and `o` holds no live
  /// dot here.
  action reap(r: str, o: str): bool = all {
    val x = replicas.get(r)
    all {
      cfg.reap,
      listed(cfg, x),
      not(live.contains(o)),
      x.cc.get(o) > 0,
      not(holdsDotOf(x, o)),
      become(r, { ...x, cc: x.cc.set(o, 0) }),
    },
  }

  action step = {
    nondet r = Replicas.oneOf()
    // Each choice is drawn only where it is used, and an op only from the
    // trees that can supply it.
    any {
      { nondet k = Set(Put, Rmv).oneOf()
        mint(r, k) },
      { nondet op = Replicas.map(p => replicas.get(p).tree).flatten().oneOf()
        deliver(r, op) },
      { nondet op = replicas.get(r).tree.oneOf()
        compact(r, op) },
      depart(r),
      { nondet o = Origins.oneOf()
        reap(r, o) },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// A dot a replica dropped never reappears in its dot-store.
  val noResurrection = Replicas.forall(r =>
    replicas.get(r).removed.intersect(replicas.get(r).dots) == Set())

  /// Two replicas that folded the same ops hold the same value.
  val convergence = Replicas.forall(r => Replicas.forall(p =>
    replicas.get(r).applied == replicas.get(p).applied implies
      replicas.get(r).dots == replicas.get(p).dots))

  /// Every live dot belongs to an op folded here.
  val noPhantomDot = Replicas.forall(r =>
    replicas.get(r).dots.forall(d => replicas.get(r).applied.exists(op => op.dot == d)))

  /// The context covers every live dot, so a stamp states the writer's
  /// causal past truthfully.
  val contextCoversDots = Replicas.forall(r =>
    replicas.get(r).dots.forall(d => observed(d, replicas.get(r).cc)))

  /// Every cell the projection holds is one the reap can enumerate.
  val directoryComplete = Replicas.forall(r =>
    replicas.get(r).applied != Set() implies listed(cfg, replicas.get(r)))

  /// A departed origin's unreaped context entry is in a cell the reap can
  /// find.
  val deadContextReachable = Replicas.forall(r => Origins.forall(o =>
    (not(live.contains(o)) and replicas.get(r).cc.get(o) > 0) implies
      listed(cfg, replicas.get(r))))
}
