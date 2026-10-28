// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The code on an applier-backed instance: the replica's own checkpointed
/// frontier is a witness, the door confirms, the cap holds.
module ConfirmedCompaction_2R_Async {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 1, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = Async
  ).* from "../../specs/ConfirmedCompaction"
  val inv = safety
  temporal prop = noDrop
}
