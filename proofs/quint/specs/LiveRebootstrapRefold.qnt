// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module LiveRebootstrapRefoldTypes {
  type InstallRule =
    // every shipped cell replaces the local one
    | ReplaceAlways
    // skip-if-older by cell HLC, else replace
    // (`bondy_oplog_applier:handle_cell/12`)
    | KeepNewer

  /// When the full re-fold (`rederive_projection`) runs.
  type RefoldTiming =
    // after the install, before the frontier is adopted
    | BeforeFinalize
    // after a successful trailing round only
    // (`bondy_oplog_sync_session:finish_bootstrap/4`)
    | AfterTrail

  /// What a failed projection write during the install
  /// (`Adapter:put_batch/2` in `bondy_oplog_applier:install_cell/9`) does.
  type WriteFailRule =
    // the batch returns the error and the session takes its failed-stream
    // path: a re-fold when the mark is set, no finalize, no new
    // re-bootstrap flag
    | FailsBatch
    // logged, and the cell counted installed
    | CountedInstalled

  type Cfg = {
    install: InstallRule,
    refold: RefoldTiming,
    // a durable "re-fold owed" mark in the checkpoint, written before the
    // first install batch and cleared only by the checkpoint of a frontier
    // a full re-fold rebuilt after the install; a restart that finds it
    // trusts neither the cells nor the checkpointed frontier
    durableMark: bool,
    // a source owing a re-fold refuses to serve
    serveGuard: bool,
    // a source's install expires the snapshot sessions open on it
    sessionExpiry: bool,
    // the re-fold resets the frontier before it re-folds, so after the
    // install it claims only the local MST and, at finalize, the peer
    // frontier
    resetFrontier: bool,
    writeFail: WriteFailRule,
  }
}

/// Does a live catalogue re-bootstrap leave a cell missing the effect of an
/// event the replica holds, or a frontier claiming an event no cell
/// reflects?
///
///   - The session reads the peer's frontier (`request_peer_frontier/4`)
///     before streaming, and the stream is a live range scan of the peer's
///     projection (`bondy_oplog_responder`), served whatever the peer is
///     doing, its own re-bootstrap included.
///   - `finalize_catalogue_bootstrap/5` max-merges the peer frontier
///     whether or not the cell was skipped, and checkpoints it.
///   - The install and the re-fold run inside the applier process, as the
///     WAL drain does, so a local write is folded and inserted into the MST
///     in one step.
///   - The frontier is durable only in the checkpoint, written by a clean
///     stop, the finalize and a compaction commit, at any time. On restart
///     the frontier is the checkpoint's (`boot_frontier/2`), and the replay
///     cursor is the current root when that frontier claims every MST
///     event, else undefined: a full re-fold (`compute_replay_anchor/1`).
///     The re-bootstrap flag lives in the scheduler's ETS and is lost.
///
/// A cell is the set of events folded into it, and folding an event it
/// already reflects is a no-op: for the dotted kernels, the guarded fold of
/// `proofs/isabelle/Aw_Kernel.thy` under causal delivery
/// (`guarded_redelivery_noop`, `putn_is_orset`). A cell's HLC is the
/// highest HLC of its events.
///
/// What starts a re-bootstrap is an environment fault, bounded by
/// `MaxFaults`, so no repair may rely on the trigger firing again.
///
/// Not modelled: compaction, a peer reading the frontier outside a session
/// start, holds, several cells, chunked installs, the frontier-gap verdict,
/// the loss of MST pages or of projection writes on a crash.
module LiveRebootstrapRefold {
  import LiveRebootstrapRefoldTypes.*
  import Ints.* from "../lib/Ints"

  /// Also the origins: each replica mints under its own.
  const Replicas: Set[str]
  const MaxSeq: int
  const MaxFaults: int
  const MaxTrailFails: int
  const MaxCrashes: int
  const MaxWriteFails: int
  const cfg: Cfg

  pure val Origins = Replicas

  /// HLCs are read only by `KeepNewer`, so under `ReplaceAlways` every
  /// event is stamped 0.
  type Event = { org: str, seq: int, hlc: int }

  /// The session of a re-bootstrap: the source, and the frontier read from
  /// it before streaming.
  type Session = { peer: str, pfront: str -> int }

  type Phase =
    | Idle
    // `sep` is the source's install count when the session began
    | Streaming({ peer: str, pfront: str -> int, sep: int })
    | Installed(Session)
    // the install failed under `FailsBatch`
    | Failed
    | Rederived(Session)
    // only the trailing round is left, against `peer`
    | Finalized(str)

  type Replica = {
    // the events whose effect is in the cell
    cell: Set[Event],
    // the events in the local MST
    tree: Set[Event],
    // the events the replay has diffed past
    cursor: Set[Event],
    // the in-memory applied frontier
    claim: str -> int,
    // the checkpointed frontier
    durable: str -> int,
    minted: int,
    // a re-bootstrap is flagged
    gap: bool,
    phase: Phase,
    // the durable re-fold mark
    owed: bool,
    // installs this replica has started
    epoch: int,
  }

  type Spent = { faults: int, trailFails: int, crashes: int, writeFails: int }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def top(s: Set[Event], o: str): int = s.filter(e => e.org == o).fold(0, (m, e) => max2(m, e.seq))

  pure def stamp(s: Set[Event]): int = s.fold(0, (m, e) => max2(m, e.hlc))

  pure def claims(vv: str -> int, e: Event): bool = e.seq <= vv.get(e.org)

  /// `vv` raised to cover the top seq of every origin in `s`.
  pure def covering(vv: str -> int, s: Set[Event]): str -> int = Origins.mapBy(o => max2(vv.get(o), top(s, o)))

  pure def merged(a: str -> int, b: str -> int): str -> int = Origins.mapBy(o => max2(a.get(o), b.get(o)))

  pure val Zero = Origins.mapBy(_ => 0)

  /// `serves(x)` when the source `x` may serve a snapshot session.
  pure def serves(x: Replica): bool = not(cfg.serveGuard and x.owed)

  pure def streaming(ph: Phase): Set[{ peer: str, pfront: str -> int, sep: int }] = match ph {
    | Streaming(s) => Set(s)
    | _ => Set()
  }

  pure def installed(ph: Phase): Set[Session] = match ph {
    | Installed(s) => Set(s)
    | _ => Set()
  }

  /// The session awaiting finalize: re-folded first under `BeforeFinalize`,
  /// only installed under `AfterTrail`.
  pure def finalizable(ph: Phase): Set[Session] = match ph {
    | Rederived(s) => Set(s)
    | _ => if (cfg.refold == AfterTrail) installed(ph) else Set()
  }

  pure def trailing(ph: Phase): Set[str] = match ph {
    | Finalized(p) => Set(p)
    | _ => Set()
  }

  /// The diff replay: fold `tree \ cursor` and move the cursor to the
  /// root. One that started from an undefined cursor outside a session is
  /// a full re-fold, and pays the mark with a checkpoint of the frontier it
  /// rebuilt.
  pure def replayed(x: Replica): Replica = {
    val c = covering(x.claim, x.tree)
    val pays = x.owed and x.cursor == Set() and x.phase == Idle
    {
      ...x,
      cell: x.cell.union(x.tree.exclude(x.cursor)),
      cursor: x.tree,
      claim: c,
      durable: if (pays) c else x.durable,
      owed: x.owed and not(pays),
    }
  }

  /// `rederive_projection`: the cursor is reset, so the whole MST is folded
  /// onto the cells as they are. While the mark is set, it pays it as the
  /// boot re-fold does.
  pure def rederived(x: Replica, after: Phase): Replica = {
    val c = covering(if (cfg.resetFrontier) Zero else x.claim, x.tree)
    {
      ...x,
      cell: x.cell.union(x.tree),
      cursor: x.tree,
      claim: c,
      durable: if (x.owed) c else x.durable,
      owed: false,
      phase: after,
    }
  }

  /// A crash keeps the cell, the MST, the checkpoint and the mark, and
  /// loses the session and the flag. A node crash loses the in-memory
  /// frontier; a one_for_all subtree restart (`keep`) keeps it, since the
  /// registry row survives (`bondy_oplog_instance_dyn_sup` drops it only on
  /// `stop_instance`), and `boot_frontier/2` max-merges the checkpoint into
  /// it. With the mark set, the frontier is reset and the cursor undefined,
  /// so the full re-fold rebuilds both from the MST.
  pure def crashed(x: Replica, keep: bool): Replica = {
    val c = if (x.owed) Zero else if (keep) merged(x.claim, x.durable) else x.durable
    {
      ...x,
      claim: c,
      cursor: if (not(x.owed) and x.tree.forall(e => claims(c, e))) x.tree else Set(),
      phase: Idle,
      gap: false,
    }
  }

  // ===========================================================================
  // State machine
  // ===========================================================================

  var replicas: str -> Replica
  /// The last HLC minted anywhere.
  var clock: int
  var spent: Spent

  val vars = (replicas, clock, spent)

  /// The source of `r`'s session can still serve its next batch.
  def valid(s: { peer: str, pfront: str -> int, sep: int }): bool = {
    val y = replicas.get(s.peer)
    serves(y) and (cfg.sessionExpiry implies y.epoch == s.sep)
  }

  action init = all {
    replicas' = Replicas.mapBy(_ => {
      cell: Set(),
      tree: Set(),
      cursor: Set(),
      claim: Zero,
      durable: Zero,
      minted: 0,
      gap: false,
      phase: Idle,
      owed: false,
      epoch: 0,
    }),
    clock' = 0,
    spent' = { faults: 0, trailFails: 0, crashes: 0, writeFails: 0 },
  }

  action become(r: str, x: Replica): bool = all { replicas' = replicas.set(r, x), clock' = clock, spent' = spent }

  /// A local write, folded on the WAL drain: it reaches the cell and the
  /// MST and claims its own seq, but does not move the replay cursor.
  action mint(r: str): bool = {
    val x = replicas.get(r)
    val h = if (cfg.install == KeepNewer) clock + 1 else clock
    val e = { org: r, seq: x.minted + 1, hlc: h }
    all {
      x.minted < MaxSeq,
      replicas' = replicas.set(r, {
        ...x,
        cell: x.cell.union(Set(e)),
        tree: x.tree.union(Set(e)),
        claim: x.claim.set(r, e.seq),
        minted: e.seq,
      }),
      clock' = h,
      spent' = spent,
    }
  }

  /// A live anti-entropy round merges `p`'s MST. None is dispatched while
  /// a session is in flight.
  action pull(r: str, p: str): bool = {
    val x = replicas.get(r)
    all {
      r != p, x.phase == Idle, not(x.gap),
      not(replicas.get(p).tree.subseteq(x.tree)),
      become(r, { ...x, tree: x.tree.union(replicas.get(p).tree) }),
    }
  }

  action replay(r: str): bool = all {
    replicas.get(r).tree.exclude(replicas.get(r).cursor) != Set(),
    become(r, replayed(replicas.get(r))),
  }

  /// A checkpoint by a clean stop or a compaction commit.
  action checkpoint(r: str): bool = {
    val x = replicas.get(r)
    all { x.durable != x.claim, become(r, { ...x, durable: x.claim }) }
  }

  /// Whatever makes the scheduler flag a re-bootstrap.
  action fault(r: str): bool = {
    val x = replicas.get(r)
    all {
      spent.faults < MaxFaults, x.phase == Idle, not(x.gap),
      replicas' = replicas.set(r, { ...x, gap: true }),
      clock' = clock,
      spent' = { ...spent, faults: spent.faults + 1 },
    }
  }

  /// The flag is consumed at dispatch, and the peer's frontier read.
  action begin(r: str, p: str): bool = {
    val x = replicas.get(r)
    val y = replicas.get(p)
    all {
      r != p, x.gap, x.phase == Idle, serves(y),
      become(r, { ...x, gap: false, phase: Streaming({ peer: p, pfront: y.claim, sep: y.epoch }) }),
    }
  }

  /// The install of the source's cell as the live scan reads it now. The
  /// mark is written before the first batch.
  action install(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streaming(x.phase).oneOf()
    val pc = replicas.get(s.peer).cell
    all {
      valid(s),
      become(r, {
        ...x,
        cell: if (cfg.install == ReplaceAlways or stamp(pc) > stamp(x.cell)) pc else x.cell,
        phase: Installed({ peer: s.peer, pfront: s.pfront }),
        owed: x.owed or cfg.durableMark,
        epoch: x.epoch + 1,
      }),
    }
  }

  /// The install write fails and the cell keeps its events. The mark and
  /// the session expiry come first (`begin_install/3`).
  action installWriteFail(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streaming(x.phase).oneOf()
    all {
      spent.writeFails < MaxWriteFails,
      valid(s),
      replicas' = replicas.set(r, {
        ...x,
        phase: match cfg.writeFail {
          | FailsBatch => Failed
          | CountedInstalled => Installed({ peer: s.peer, pfront: s.pfront })
        },
        owed: x.owed or cfg.durableMark,
        epoch: x.epoch + 1,
      }),
      clock' = clock,
      spent' = { ...spent, writeFails: spent.writeFails + 1 },
    }
  }

  /// The failed-stream path with no mark to pay: the session just ends.
  action failedIdle(r: str): bool = {
    val x = replicas.get(r)
    all { x.phase == Failed, not(x.owed), become(r, { ...x, phase: Idle }) }
  }

  /// The source refused or expired the session (`cursor_expired`) before
  /// anything was installed, and the scheduler flags a retry.
  action abort(r: str): bool = {
    val x = replicas.get(r)
    nondet s = streaming(x.phase).oneOf()
    all { not(valid(s)), become(r, { ...x, phase: Idle, gap: true }) }
  }

  /// The early re-fold after an install, or the failed-stream path's
  /// re-fold, which runs only while the mark is set and ends the session.
  action rederive(r: str): bool = {
    val x = replicas.get(r)
    any {
      all { x.phase == Failed, x.owed, become(r, rederived(x, Idle)) },
      all {
        cfg.refold == BeforeFinalize,
        { nondet s = installed(x.phase).oneOf()
          become(r, rederived(x, Rederived(s))) },
      },
    }
  }

  /// `finalize_catalogue_bootstrap/5`: max-merge the frontier read at
  /// `begin` and checkpoint it, which clears the mark in the same write.
  action finalize(r: str): bool = {
    val x = replicas.get(r)
    nondet s = finalizable(x.phase).oneOf()
    val c = merged(x.claim, s.pfront)
    become(r, { ...x, claim: c, durable: c, owed: false, phase: Finalized(s.peer) })
  }

  /// The trailing round succeeds: pull, replay and, under `AfterTrail`,
  /// re-fold.
  action trailOk(r: str): bool = {
    val x = replicas.get(r)
    nondet p = trailing(x.phase).oneOf()
    val t = x.tree.union(replicas.get(p).tree)
    become(r, {
      ...x,
      tree: t,
      cursor: t,
      cell: x.cell.union(if (cfg.refold == BeforeFinalize) t.exclude(x.cursor) else t),
      claim: covering(x.claim, t),
      phase: Idle,
    })
  }

  /// The trailing round fails (`{partisan_call_failed, timeout}`, ...).
  action trailFail(r: str): bool = {
    val x = replicas.get(r)
    all {
      spent.trailFails < MaxTrailFails,
      trailing(x.phase) != Set(),
      replicas' = replicas.set(r, { ...x, phase: Idle }),
      clock' = clock,
      spent' = { ...spent, trailFails: spent.trailFails + 1 },
    }
  }

  action crash(r: str, keep: bool): bool = all {
    spent.crashes < MaxCrashes,
    replicas' = replicas.set(r, crashed(replicas.get(r), keep)),
    clock' = clock,
    spent' = { ...spent, crashes: spent.crashes + 1 },
  }

  action step = {
    nondet r = Replicas.oneOf()
    any {
      mint(r), replay(r), checkpoint(r), fault(r), install(r), installWriteFail(r),
      failedIdle(r), abort(r), rederive(r), finalize(r), trailOk(r), trailFail(r),
      { nondet keep = Set(true, false).oneOf()
        crash(r, keep) },
      { nondet p = Replicas.oneOf()
        any { pull(r, p), begin(r, p) } },
    }
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  /// Every minted event: each is in its origin's MST, which only grows.
  val allMinted = Replicas.map(r => replicas.get(r).tree).flatten()

  /// Outside a session, the cell holds every event the replay has diffed
  /// past: no replay will present such an event again.
  val noStrandedEvent = Replicas.forall(r => {
    val x = replicas.get(r)
    x.phase == Idle implies x.cursor.subseteq(x.cell)
  })

  /// Outside a session, the frontier claims only events the cell reflects
  /// or that a pending full re-fold (an undefined cursor over a non-empty
  /// MST) will fold: the restart re-anchor and the convergence oracle both
  /// read a claimed event as folded.
  val claimSound = Replicas.forall(r => {
    val x = replicas.get(r)
    val refoldPending = x.cursor == Set() and x.tree != Set()
    x.phase == Idle implies allMinted.filter(e => claims(x.claim, e))
      .subseteq(x.cell.union(if (refoldPending) x.tree else Set()))
  })

  val safety = noStrandedEvent and claimSound

  /// Every replica's cell eventually holds every minted event, and keeps
  /// it.
  temporal converges = eventually(always(Replicas.forall(r => allMinted.subseteq(replicas.get(r).cell))))

  /// The session and the anti-entropy steps eventually happen; faults,
  /// crashes, checkpoints, mints and failures need not.
  temporal fairness = and {
    Replicas.forall(r => Replicas.forall(p => weakFair(pull(r, p), vars) and weakFair(begin(r, p), vars))),
    Replicas.forall(r => and {
      weakFair(replay(r), vars),
      weakFair(install(r), vars),
      weakFair(abort(r), vars),
      weakFair(rederive(r), vars),
      weakFair(failedIdle(r), vars),
      weakFair(finalize(r), vars),
      weakFair(trailOk(r), vars),
    }),
  }

  temporal live = fairness implies converges
}
