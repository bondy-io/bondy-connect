// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The rebuild not capped below the first unapplied key.
module ConfirmedCompaction_3R_Lost_Uncapped {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = { ...Holding, healCap: false }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = lostSafety
  temporal prop = noDropNoStrand
}
