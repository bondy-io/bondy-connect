// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The operator removes a member: it stops bounding the others, and its own
/// unsynced events are given up.
module ConfirmedCompaction_3R_Retire {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 1, MaxLost = 0,
    cfg = Code
  ).* from "../../specs/ConfirmedCompaction"
  val inv = safety
  temporal prop = noDrop
}
