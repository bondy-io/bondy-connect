// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A door that drops on key order: 2 compacts its own event once 1 and 3
/// hold it, then pulls 1's earlier event, whose key sorts below 2's
/// watermark, and drops it. 3 never received it and has nothing to pull it
/// from.
module ConfirmedCompaction_3R_DoorDrop_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Code, door: DropsApplied }
  ).* from "../specs/ConfirmedCompaction"

  run doorDropsWhatAMemberLacksTest =
    init
      .then(mintAt(1, 1))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(pull(3, 2, false))
      .then(compact(2))
      .then(pull(2, 1, false))
      .expect(not(noGap))
}

/// A recency filter: 1 and 3 drop 2's row and compact 1's event between
/// themselves, so 2 can never receive it.
module ConfirmedCompaction_3R_Fresh_Partition_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 2, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Code, witnesses: FreshMembers }
  ).* from "../specs/ConfirmedCompaction"

  run staleRowStopsBoundingTest =
    init
      .then(mintAt(1, 1))
      .then(expire(1, 2))
      .then(pull(3, 1, false))
      .then(compact(1))
      .then(expire(3, 2))
      .then(compact(3))
      .expect(not(noLoss))
}

/// A walk that skips a lost page: 1 loses its own event before 2 has pulled
/// it, and truncates up to a later key every member confirmed, taking the
/// event with it.
module ConfirmedCompaction_3R_Lost_SkipWalk_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = { ...Holding, walkLost: true }
  ).* from "../specs/ConfirmedCompaction"

  val own = { hlc: 1, org: 1, seq: 1 }

  run skippedPageIsTruncatedTest =
    init
      .then(mintAt(1, 1))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(pull(3, 1, false))
      .then(lose(1, own))
      .then(compact(1))
      .expect(and {
        not(replicas.get(1).tree.contains(own)),
        not(replicas.get(2).tree.contains(own)),
        not(replicas.get(2).applied.contains(own)),
      })
}

/// An ungated rebuild drops 1's lost event before 2 has received it.
module ConfirmedCompaction_3R_Lost_Ungated_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = { ...Holding, heal: Ungated }
  ).* from "../specs/ConfirmedCompaction"

  val own = { hlc: 1, org: 1, seq: 1 }

  run ungatedRebuildStrandsTest =
    init
      .then(mintAt(1, 1))
      .then(lose(1, own))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(heal(1))
      .expect(and {
        not(replicas.get(1).tree.contains(own)),
        not(replicas.get(2).tree.contains(own)),
        not(replicas.get(2).applied.contains(own)),
      })
}

/// The reachability control: 2's rebuild drops a lost key it never applied.
module ConfirmedCompaction_2R_Async_Lost_Control_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = Async
  ).* from "../specs/ConfirmedCompaction"

  val first = { hlc: 1, org: 1, seq: 1 }

  run rebuildDropsALostKeyTest =
    init
      .then(mintAt(1, 1))
      .then(mintAt(1, 2))
      .then(pull(2, 1, false))
      .then(lose(2, first))
      .then(heal(2))
      .expect(and {
        lostSafety,
        not(replicas.get(2).tree.contains(first)),
        not(replicas.get(2).applied.contains(first)),
        replicas.get(1).applied.contains(first),
      })
}

/// The code on a fused instance: each run above stops where its mechanism
/// is back.
module ConfirmedCompaction_3R_Lost_test {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../configs/ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 2, MaxRetire = 0, MaxLost = 1,
    cfg = Holding
  ).* from "../specs/ConfirmedCompaction"

  val own = { hlc: 1, org: 1, seq: 1 }

  /// The confirmed door keeps 1's event at 2, since 3 has not confirmed it.
  run doorKeepsWhatAMemberLacksTest =
    init
      .then(mintAt(1, 1))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(pull(3, 2, false))
      .then(compact(2))
      .then(pull(2, 1, false))
      .expect(safety and replicas.get(2).tree.contains(own))

  /// Every member's row bounds compaction, however long it is silent.
  run silentMemberStillBoundsTest =
    init
      .then(mintAt(1, 1))
      .then(expire(1, 2).fail())

  run silentMemberBlocksCompactionTest =
    init
      .then(mintAt(1, 1))
      .then(pull(3, 1, false))
      .then(compact(1).fail())

  /// The walk stops at the lost page, and the rebuild waits for the cover.
  run lostPageHoldsTest =
    init
      .then(mintAt(1, 1))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(pull(3, 1, false))
      .then(lose(1, own))
      .then(compact(1).fail())

  run rebuildWaitsForTheCoverTest =
    init
      .then(mintAt(1, 1))
      .then(lose(1, own))
      .then(mintAt(2, 1))
      .then(pull(1, 2, false))
      .then(heal(1).fail())
}
