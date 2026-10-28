// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Seq 2 arrives first and folds alone; the batch saw no failure, so the
/// shipped rule claims 2 with seq 1 missing.
module FrontierPending_MaxCap_test {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.* from "../configs/FrontierPending.configs"
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, claimRule: MaxCap, canRefold: true }
  ).* from "../specs/FrontierPending"

  run claimsAcrossAHoleTest =
    init
      .then(receive("o1", 2, "b1"))
      .then(applyBatch(Set({ org: "o1", seq: 2, bucket: "b1" })))
      .expect(claim.get("o1").prefix == 2 and not(noOverClaim))
}

/// Seq 2 folds in a batch of its own while seq 1 waits; the prefix bound
/// cannot record it, so with all three folded the entry still says 1.
module FrontierPending_Contig_Dead_test {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.* from "../configs/FrontierPending.configs"
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, claimRule: Contig }
  ).* from "../specs/FrontierPending"

  pure def ev(s: int): Event = { org: "o1", seq: s, bucket: "b1" }

  run forgetsASeqFoldedAboveAHoleTest =
    init
      .then(receive("o1", 1, "b1"))
      .then(receive("o1", 2, "b1"))
      .then(receive("o1", 3, "b1"))
      .then(applyBatch(Set(ev(2))))
      .then(applyBatch(Set(ev(1), ev(3))))
      .then(register)
      .expect(applied.get("o1") == Seqs and claim.get("o1").prefix == 1 and not(complete))
}

/// The same schedule under `Pending`: seq 2 waits in the pending set, and
/// the entry reaches 3 on the spot.
module FrontierPending_Pending_test {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.* from "../configs/FrontierPending.configs"
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2", cfg = Base
  ).* from "../specs/FrontierPending"

  pure def ev(s: int): Event = { org: "o1", seq: s, bucket: "b1" }

  run completeOnTheSpotTest =
    init
      .then(receive("o1", 1, "b1"))
      .then(receive("o1", 2, "b1"))
      .then(receive("o1", 3, "b1"))
      .then(applyBatch(Set(ev(2))))
      .expect(claim.get("o1") == { prefix: 0, pending: Set(2) })
      .then(applyBatch(Set(ev(1), ev(3))))
      .then(register)
      .expect(claim.get("o1") == { prefix: 3, pending: Set() } and complete and exact)
}

/// Seqs 1 and 2 land in the unroutable bucket and are dropped, seq 3
/// waits in the pending set, and a restart loses it. Without a re-fold
/// nothing presents any of them again.
module FrontierPending_Pending_Restart_NoRefold_test {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.* from "../configs/FrontierPending.configs"
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, canRestart: true }
  ).* from "../specs/FrontierPending"

  run pendingLostOnRestartTest =
    init
      .then(receive("o1", 1, "b2"))
      .then(receive("o1", 2, "b2"))
      .then(receive("o1", 3, "b1"))
      .then(applyBatch(inbox))
      .then(restart)
      .then(register)
      // `eventuallyComplete` is temporal, which only TLC checks
      .expect(and {
        inbox == Set(),
        quiescent,
        routable == Buckets,
        claim.get("o1") == { prefix: 0, pending: Set() },
      })
}

/// The same run with the boot re-fold: the restart re-presents the oplog,
/// and once the bucket routes the entry reaches 3.
module FrontierPending_Pending_Restart_test {
  import FrontierPendingTypes.* from "../specs/FrontierPending"
  import FrontierPendingConfigs.* from "../configs/FrontierPending.configs"
  import FrontierPending(
    Origins = Set("o1"), Buckets = Set("b1", "b2"), MaxSeq = 3, Unroutable = "b2",
    cfg = { ...Base, canRefold: true, canRestart: true }
  ).* from "../specs/FrontierPending"

  run refoldRecoversTest =
    init
      .then(receive("o1", 1, "b2"))
      .then(receive("o1", 2, "b2"))
      .then(receive("o1", 3, "b1"))
      .then(applyBatch(inbox))
      .then(restart)
      .then(register)
      .then(applyBatch(inbox))
      .expect(claim.get("o1") == { prefix: 3, pending: Set() } and exact)
}
