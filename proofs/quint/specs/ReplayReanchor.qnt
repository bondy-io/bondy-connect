// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module ReplayReanchorTypes {
  /// How the applier handles `advance_replayed_root(NewRoot)`.
  type Reanchor =
    // the cursor moves to the new root
    | Always
    // the cursor moves only when it is anchored and the last replay held
    // nothing; otherwise it is dropped, so the next replay folds the whole
    // tree
    | Guarded
    // the cursor moves whenever the last replay held nothing, anchored or not
    | HeldOnly

  type Cfg = {
    reanchor: Reanchor,
    // the boot replay waits for `open_drain_gate/1`
    gated: bool,
  }
}

/// Whether a compaction can move the applier's replay cursor past an event
/// the applier has not folded, so that no later replay presents it. One
/// replica, one cell; remote events arrive in any order.
///
///   - A replay folds the pairs of the current tree not under the cursor
///     (`last_replayed_root`), or the whole tree when there is no cursor
///     (`bondy_oplog_applier:diff_pairs/3`), with the causal hold: a remote
///     event above its origin's contiguity gap is not folded. The cursor
///     moves to the current root only when nothing was held.
///   - Local writes are folded by the WAL drain and installed in the tree;
///     they never move the cursor.
///   - A remote delivery and a compaction commit each cast to the applier
///     from the instance, so the applier handles them in that order: the
///     mailbox `mbox`.
///   - Compaction truncates a key-order prefix of the tree strictly below
///     the first key the applied frontier does not claim
///     (`capped_truncation_point/2`); peer confirmation is abstracted.
///   - A restart loses the mailbox and anchors on the current root when the
///     frontier claims every tree event, else not at all
///     (`compute_replay_anchor/1`), then replays at init or, gated, at
///     `open_drain_gate/1`.
///
/// `Anchored(Set())` is not the code's `last_replayed_root =/= undefined`:
/// an anchor over an empty tree is a cursor, though the empty tree's root
/// is `undefined`. The code carries "no cursor, or the last replay held" as
/// one flag, `owed`.
///
/// Not modelled: the fused instance, several cells, peers, page GC.
module ReplayReanchor {
  import ReplayReanchorTypes.*

  const Local: int
  const Remotes: Set[int]
  const MaxSeq: int
  const MaxCompact: int
  const MaxRestart: int
  const cfg: Cfg

  assume localIsNotRemote = not(Remotes.contains(Local))

  pure val Origins = Remotes.union(Set(Local))

  type Event = { org: int, seq: int }

  type Cursor = Unanchored | Anchored(Set[Event])

  type Msg = ReplayCast | AdvanceCast(Set[Event])

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure val Events: Set[Event] = tuples(Origins, 1.to(MaxSeq)).map(((o, s)) => { org: o, seq: s })

  pure val RemoteEvents: Set[Event] = Events.filter(e => Remotes.contains(e.org))

  /// Key order. HLCs grow per origin, so a key-order prefix holds a
  /// per-origin prefix; across origins this is one fixed interleaving.
  pure def below(a: Event, b: Event): bool =
    a.seq < b.seq or (a.seq == b.seq and a.org < b.org)

  pure def holdsPrefix(s: Set[Event], o: int, n: int): bool =
    1.to(n).forall(i => s.contains({ org: o, seq: i }))

  /// The applied frontier: per origin, the contiguous prefix of `s`
  /// (`merge_applied/2`).
  pure def claimed(s: Set[Event]): Set[Event] =
    Events.filter(e => holdsPrefix(s, e.org, e.seq))

  pure def anchored(c: Cursor): bool = match c { | Unanchored => false | Anchored(_) => true }

  pure def isAdvance(m: Msg): bool = match m { | ReplayCast => false | AdvanceCast(_) => true }

  /// The root an `AdvanceCast` carries; `advance` reads it only after
  /// `isAdvance`.
  pure def rootOf(m: Msg): Set[Event] = match m { | ReplayCast => Set() | AdvanceCast(r) => r }

  /// What a replay presents.
  pure def presented(c: Cursor, tree: Set[Event]): Set[Event] = match c {
    | Unanchored => tree
    | Anchored(root) => tree.exclude(root)
  }

  /// A fold of `diff` onto `applied`: a local event always, a remote one
  /// only when its whole origin prefix is then present.
  pure def foldDiff(applied: Set[Event], diff: Set[Event]): Set[Event] = {
    val offered = applied.union(diff)
    applied.union(diff.filter(e => e.org == Local or holdsPrefix(offered, e.org, e.seq)))
  }

  pure def isCut(cut: Set[Event], tree: Set[Event], applied: Set[Event]): bool = and {
    cut != Set(),
    cut.forall(e => tree.forall(f => below(f, e) implies cut.contains(f))),
    cut.subseteq(claimed(applied)),
  }

  /// The anchor `compute_replay_anchor/1` computes at boot.
  pure def bootAnchor(tree: Set[Event], applied: Set[Event]): Cursor =
    if (tree.subseteq(claimed(applied))) Anchored(tree) else Unanchored

  // ===========================================================================
  // State machine
  // ===========================================================================

  var tree: Set[Event]
  /// What the projection has folded.
  var applied: Set[Event]
  /// What compaction truncated.
  var gone: Set[Event]
  var delivered: Set[Event]
  var cursor: Cursor
  /// The last replay held an event.
  var holding: bool
  var mbox: List[Msg]
  /// The boot replay waits behind the drain gate.
  var gate: bool
  var minted: int
  var compactions: int
  var restarts: int

  action init = all {
    tree' = Set(), applied' = Set(), gone' = Set(), delivered' = Set(),
    cursor' = Anchored(Set()), holding' = false, mbox' = List(), gate' = false,
    minted' = 0, compactions' = 0, restarts' = 0,
  }

  action mint = all {
    minted < MaxSeq,
    val e = { org: Local, seq: minted + 1 }
    all { tree' = tree.union(Set(e)), applied' = applied.union(Set(e)) },
    minted' = minted + 1,
    gone' = gone, delivered' = delivered, cursor' = cursor, holding' = holding,
    mbox' = mbox, gate' = gate, compactions' = compactions, restarts' = restarts,
  }

  action deliver(e: Event): bool = all {
    Remotes.contains(e.org),
    not(delivered.contains(e)),
    delivered' = delivered.union(Set(e)),
    tree' = tree.union(Set(e)),
    mbox' = mbox.append(ReplayCast),
    applied' = applied, gone' = gone, cursor' = cursor, holding' = holding,
    gate' = gate, minted' = minted, compactions' = compactions, restarts' = restarts,
  }

  /// The applier takes the next cast; nothing else changes but `applied`.
  action receive(a: Set[Event], c: Cursor, h: bool): bool = all {
    mbox' = mbox.tail(),
    applied' = a, cursor' = c, holding' = h,
    tree' = tree, gone' = gone, delivered' = delivered, gate' = gate,
    minted' = minted, compactions' = compactions, restarts' = restarts,
  }

  action replay = all {
    mbox.length() > 0,
    mbox.head() == ReplayCast,
    val diff = presented(cursor, tree)
    val folded = foldDiff(applied, diff)
    val held = diff.exclude(folded)
    receive(folded, if (held == Set()) Anchored(tree) else cursor, held != Set()),
  }

  action advance = all {
    mbox.length() > 0,
    isAdvance(mbox.head()),
    val keep = match cfg.reanchor {
      | Always => true
      | Guarded => anchored(cursor) and not(holding)
      | HeldOnly => not(holding)
    }
    receive(applied, if (keep) Anchored(rootOf(mbox.head())) else Unanchored, holding),
  }

  action compact(cut: Set[Event]): bool = all {
    compactions < MaxCompact,
    isCut(cut, tree, applied),
    tree' = tree.exclude(cut),
    gone' = gone.union(cut),
    mbox' = mbox.append(AdvanceCast(tree.exclude(cut))),
    compactions' = compactions + 1,
    applied' = applied, delivered' = delivered, cursor' = cursor, holding' = holding,
    gate' = gate, minted' = minted, restarts' = restarts,
  }

  action restart = all {
    restarts < MaxRestart,
    mbox' = if (cfg.gated) List() else List(ReplayCast),
    gate' = cfg.gated,
    cursor' = bootAnchor(tree, applied),
    holding' = false,
    restarts' = restarts + 1,
    tree' = tree, applied' = applied, gone' = gone, delivered' = delivered,
    minted' = minted, compactions' = compactions,
  }

  action openGate = all {
    gate,
    gate' = false,
    mbox' = mbox.append(ReplayCast),
    tree' = tree, applied' = applied, gone' = gone, delivered' = delivered,
    cursor' = cursor, holding' = holding, minted' = minted,
    compactions' = compactions, restarts' = restarts,
  }

  action step = any {
    mint,
    { nondet e = RemoteEvents.oneOf()
      deliver(e) },
    replay,
    advance,
    { nondet cut = tree.powerset().oneOf()
      compact(cut) },
    restart,
    openGate,
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// Once the mailbox is drained and the gate open, the next replay
  /// presents every tree event the projection lacks.
  val presentable =
    (mbox == List() and not(gate)) implies tree.exclude(applied).subseteq(presented(cursor, tree))

  val vars = (tree, applied, gone, delivered, cursor, holding, mbox, gate, minted, compactions, restarts)

  /// The environment delivers every remote event and the applier drains
  /// its mailbox; a restart is never forced.
  temporal fairness = and {
    weakFair(mint, vars),
    RemoteEvents.forall(e => weakFair(deliver(e), vars)),
    weakFair(replay, vars),
    weakFair(advance, vars),
    weakFair(openGate, vars),
  }

  /// Every event received or minted is eventually folded.
  temporal eventuallyApplied = eventually(always(
    delivered.union(Events.filter(e => e.org == Local and e.seq <= minted)).subseteq(applied)))

  temporal live = fairness implies eventuallyApplied
}
