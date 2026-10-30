// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module FrontierPendingConfigs {
  import FrontierPendingTypes.* from "../specs/FrontierPending"

  /// The setting every instance shares: out-of-order delivery, batches
  /// that split the inbox, a table that may register, and the door as the
  /// code has it.
  pure val Base = {
    claimRule: Pending,
    inOrderDelivery: false,
    wholeBatchOnly: false,
    canHeal: true,
    canRefold: false,
    canRestart: false,
    door: Truncating({ prefixOnly: true, readsPending: false }),
  }
}

/// The shipped rule: a seq that failed, or never arrived, before this
/// batch is invisible to it.
module FrontierPending_MaxCap {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, claimRule: MaxCap, canRefold: true }
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog and noOverClaim
}

/// The prefix bound alone is sound, but forgets a seq folded while a hole
/// was open.
module FrontierPending_Contig_Dead {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, claimRule: Contig }
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog and complete
}

/// The prefix plus the pending set, with no re-fold and no restart.
module FrontierPending_Pending {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = Base
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog and noOverClaim and pendingSound and noLoss and exact and complete
}

/// One origin's hole must not disturb the other's entry: the pointwise
/// reduction the Isabelle theory relies on.
module FrontierPending_Pending_TwoOrigins {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1", "o2"), Buckets = Set("b1", "b2"), MaxSeq = 2, Unroutable = "b2",
    cfg = Base
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog and noOverClaim and pendingSound and noLoss and exact and complete
}

/// Restarts, which need not be fair, so any number of them; the boot
/// re-fold rebuilds the pending set.
module FrontierPending_Pending_Restart {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, canRefold: true, canRestart: true }
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog
}

/// Restarts with no re-fold: nothing re-presents what the pending set
/// recorded.
module FrontierPending_Pending_Restart_NoRefold {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.*
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, canRestart: true }
  ).* from "../specs/FrontierPending"
  val inv = noDeadlock and inboxWithinOplog
}
