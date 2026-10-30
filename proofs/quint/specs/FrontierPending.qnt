// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module FrontierPendingTypes {
  /// How a batch's fold raises the frontier entry.
  type ClaimRule =
    // `bondy_oplog_cell_apply:claim/2`: the highest materialised seq
    // strictly below the lowest seq this batch saw fail, max-merged into the
    // entry (`merge_frontier/2`)
    | MaxCap
    // the prefix bound alone, walked up through this batch's materialised
    // seqs
    | Contig
    // the prefix bound, plus the applied seqs above it
    | Pending

  /// The compaction door (`watermark_door/3`, `capped_truncation_point/2`).
  type DoorRule =
    | NoDoor
    | Truncating({
        // truncation stops below the smallest key the frontier does not
        // claim, as both sites do; off, it is per entry
        prefixOnly: bool,
        // `never_applied/2` also reads the pending set
        readsPending: bool,
      })

  type Cfg = {
    claimRule: ClaimRule,
    // an origin's seqs arrive in order
    inOrderDelivery: bool,
    // a batch is the whole inbox
    wholeBatchOnly: bool,
    // the missing table may register (`register_table/4`)
    canHeal: bool,
    // the applier may re-present the whole oplog to the fold
    // (`replay_cell_events/1`, or a boot whose `replay_anchor/1` is
    // `undefined`)
    canRefold: bool,
    // the instance may restart, losing in-flight work and the pending set
    canRestart: bool,
    door: DoorRule,
  }
}

/// Can one replica's applied frontier be kept by one integer per origin,
/// when it is raised once per batch and nobody chooses the batch
/// boundaries? A fact one batch establishes, such as "seq 2 folded", is
/// lost if the integer cannot hold it, and it cannot while seq 1 is
/// missing. `proofs/isabelle/Frontier_Pending.thy` proves that no writer
/// whose state is one integer per origin is both sound and eventually
/// complete (`no_scalar_writer_sound_and_complete`); this module checks
/// three concrete rules under concurrency, restarts and the compaction
/// door, which the theory does not model.
///
///   - Receipt is not application: `oplog` is what `install_event/5`
///     recorded, `applied` what the projection folded.
///   - A batch is any per-origin prefix of the inbox. With out-of-order
///     delivery that over-approximates the applier, which drains in
///     arrival order.
///   - A batch drops, rather than holds, the events of a bucket with no
///     cell-apply context (`apply_cell_batch_mux/3`); they return only if
///     something re-presents them.
///   - The door judges against the frontier, so an over-claim licenses
///     truncating the event it lied about. A truncated event never arrives
///     again.
///
/// Not modelled: the MST, HLCs, compaction checkpoints, more than one
/// replica.
module FrontierPending {
  import FrontierPendingTypes.*
  import Ints.* from "../lib/Ints"

  /// The remote origins whose events this replica folds.
  const Origins: Set[str]
  /// The entity types multiplexed onto the shard instance.
  const Buckets: Set[str]
  const MaxSeq: int
  /// The bucket with no cell-apply context at boot; outside `Buckets` when
  /// every bucket routes.
  const Unroutable: str
  const cfg: Cfg

  pure val Seqs = 1.to(MaxSeq)

  type Event = { org: str, seq: int, bucket: str }

  /// An origin's frontier entry. `pending` stays empty unless the rule is
  /// `Pending`.
  type Entry = { prefix: int, pending: Set[int] }

  // ===========================================================================
  // Functional layer
  // ===========================================================================

  pure def seqsOf(s: Set[Event], o: str): Set[int] = s.filter(e => e.org == o).map(e => e.seq)

  pure def maxOf(s: Set[int]): int = s.fold(0, (m, x) => max2(m, x))

  /// The prefix bound `p` advanced through `s`: the largest `c >= p` with
  /// every seq in `p+1..c` in `s`.
  pure def absorb(p: int, s: Set[int]): int =
    maxOf(p.to(MaxSeq).filter(c => (p + 1).to(c).forall(k => s.contains(k))))

  /// The entry after a batch materialised `mat` and failed on `failed`. `Pending`
  /// reads no failures: it reports what folded and nothing else.
  pure def raised(r: ClaimRule, x: Entry, mat: Set[int], failed: Set[int]): Entry = match r {
    | MaxCap => { ...x, prefix: max2(x.prefix, maxOf(mat.filter(s => failed.forall(t => s < t)))) }
    | Contig => { ...x, prefix: absorb(x.prefix, mat) }
    | Pending => {
        val held = x.pending.union(mat)
        val p = absorb(x.prefix, held)
        { prefix: p, pending: held.filter(s => s > p) }
      }
  }

  /// Whether the door counts `s` as applied: `never_applied/2` is
  /// `key_seq(K) > VV[Origin]`.
  pure def doorClaims(readsPending: bool, x: Entry, s: int): bool =
    s <= x.prefix or (readsPending and x.pending.contains(s))

  pure def truncatable(d: DoorRule, claim: str -> Entry, oplog: Set[Event], e: Event): bool = match d {
    | NoDoor => false
    | Truncating(t) => and {
        doorClaims(t.readsPending, claim.get(e.org), e.seq),
        t.prefixOnly implies oplog.forall(f =>
          (f.org == e.org and f.seq < e.seq) implies doorClaims(t.readsPending, claim.get(f.org), f.seq)),
      }
  }

  // ===========================================================================
  // State machine
  // ===========================================================================

  /// Every seq ever received, per origin; truncation does not shrink it.
  var seen: str -> Set[int]
  var oplog: Set[Event]
  /// Drained, not yet presented to the fold.
  var inbox: Set[Event]
  /// The projection: the ground truth.
  var applied: str -> Set[int]
  /// The frontier, as `get_frontier` ships it.
  var claim: str -> Entry
  /// The buckets with a cell-apply context.
  var routable: Set[str]
  /// Truncated by the door: unrecoverable.
  var gone: Set[Event]

  val vars = (seen, oplog, inbox, applied, claim, routable, gone)

  action init = all {
    seen' = Origins.mapBy(_ => Set()),
    oplog' = Set(),
    inbox' = Set(),
    applied' = Origins.mapBy(_ => Set()),
    claim' = Origins.mapBy(_ => { prefix: 0, pending: Set() }),
    routable' = Buckets.exclude(Set(Unroutable)),
    gone' = Set(),
  }

  /// Anti-entropy hands the instance an event.
  action receive(o: str, s: int, b: str): bool = all {
    not(seen.get(o).contains(s)),
    cfg.inOrderDelivery implies (s == 1 or seen.get(o).contains(s - 1)),
    val e = { org: o, seq: s, bucket: b }
    all { oplog' = oplog.union(Set(e)), inbox' = inbox.union(Set(e)) },
    seen' = seen.setBy(o, x => x.union(Set(s))),
    applied' = applied, claim' = claim, routable' = routable, gone' = gone,
  }

  /// One call of `apply_cell_batch_mux/3` on `batch`; the claim is made
  /// once, after every group has reported.
  action applyBatch(batch: Set[Event]): bool = all {
    batch != Set(),
    batch.subseteq(inbox),
    cfg.inOrderDelivery implies batch.forall(e => inbox.forall(f =>
      (f.org == e.org and f.seq < e.seq) implies batch.contains(f))),
    cfg.wholeBatchOnly implies batch == inbox,
    val mat = batch.filter(e => routable.contains(e.bucket))
    val failed = batch.exclude(mat)
    all {
      applied' = Origins.mapBy(o => applied.get(o).union(seqsOf(mat, o))),
      claim' = Origins.mapBy(o => raised(cfg.claimRule, claim.get(o), seqsOf(mat, o), seqsOf(failed, o))),
    },
    inbox' = inbox.exclude(batch),
    seen' = seen, oplog' = oplog, routable' = routable, gone' = gone,
  }

  action register = all {
    cfg.canHeal,
    Buckets.contains(Unroutable),
    not(routable.contains(Unroutable)),
    routable' = Buckets,
    seen' = seen, oplog' = oplog, inbox' = inbox, applied' = applied, claim' = claim, gone' = gone,
  }

  /// The fold is idempotent, so re-presenting what it already applied is
  /// what lets a rule that lost information recover it.
  action refold = all {
    cfg.canRefold,
    inbox != oplog,
    inbox' = oplog,
    seen' = seen, oplog' = oplog, applied' = applied, claim' = claim, routable' = routable, gone' = gone,
  }

  /// The checkpoint carries the prefix; the pending set and in-flight
  /// batches are lost.
  action restart = all {
    cfg.canRestart,
    claim' = Origins.mapBy(o => { ...claim.get(o), pending: Set() }),
    inbox' = if (cfg.canRefold) oplog else Set(),
    seen' = seen, oplog' = oplog, applied' = applied, routable' = routable, gone' = gone,
  }

  action truncate(e: Event): bool = all {
    oplog.contains(e),
    truncatable(cfg.door, claim, oplog, e),
    oplog' = oplog.exclude(Set(e)),
    inbox' = inbox.exclude(Set(e)),
    gone' = gone.union(Set(e)),
    seen' = seen, applied' = applied, claim' = claim, routable' = routable,
  }

  action receiveAny = {
    nondet o = Origins.oneOf()
    nondet s = Seqs.oneOf()
    nondet b = Buckets.oneOf()
    receive(o, s, b)
  }

  action step = any {
    receiveAny,
    { nondet batch = inbox.powerset().oneOf()
      applyBatch(batch) },
    register,
    refold,
    restart,
    { nondet e = oplog.oneOf()
      truncate(e) },
  }

  // ===========================================================================
  // Properties
  // ===========================================================================

  val quiescent = Origins.forall(o => seen.get(o) == Seqs) and inbox == Set()

  /// A run stops only once everything has arrived and been presented.
  val noDeadlock = quiescent or enabled(step)

  val inboxWithinOplog = inbox.subseteq(oplog)

  /// The oracle contract: every seq at or below the entry was folded.
  /// `get_frontier` ships this integer, and its readers discard or refuse
  /// data on it.
  val noOverClaim = Origins.forall(o => 1.to(claim.get(o).prefix).subseteq(applied.get(o)))

  /// The same contract for a reader that sees the pending set too.
  val pendingSound = Origins.forall(o => Seqs.forall(s =>
    doorClaims(true, claim.get(o), s) implies applied.get(o).contains(s)))

  /// No event left the tree before the projection folded it.
  val noLoss = gone.forall(e => applied.get(e.org).contains(e.seq))

  /// Under `Pending`, the entry denotes exactly the folded set. A restart
  /// breaks this until the re-fold.
  val exact = cfg.claimRule == Pending implies Origins.forall(o => Seqs.forall(s =>
    doorClaims(true, claim.get(o), s) == applied.get(o).contains(s)))

  /// Once everything has arrived, every bucket routes and the projection
  /// holds everything, the entry says so. An entry that under-claims makes
  /// `frontier_deficit/2` re-request forever and holds the event against
  /// `capped_truncation_point/2` forever.
  val complete = (quiescent and routable == Buckets and Origins.forall(o => applied.get(o) == Seqs))
    implies Origins.forall(o => claim.get(o).prefix == MaxSeq)

  /// Completeness after a repair step: the entry eventually becomes right
  /// and stays right.
  temporal eventuallyComplete = eventually(always(Origins.forall(o => claim.get(o).prefix == MaxSeq)))

  /// Delivery, registration and the re-fold eventually happen; a restart
  /// and the door need not. The fold's fairness is strong and on the full
  /// drain: weak fairness on some batch is met by an adversary that
  /// presents the same proper subset forever.
  temporal fairness = and {
    weakFair(receiveAny, vars),
    strongFair(applyBatch(inbox), vars),
    weakFair(register, vars),
    weakFair(refold, vars),
  }

  temporal live = fairness implies eventuallyComplete
}
