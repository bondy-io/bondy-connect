// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A link cut and a member removed.
module ConfirmedCompaction_2R_Async_Partition_Retire {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 1, MaxCuts = 1, MaxRetire = 1, MaxLost = 0,
    cfg = Async
  ).* from "../../specs/ConfirmedCompaction"
  val inv = safety
  temporal prop = noDrop
}
