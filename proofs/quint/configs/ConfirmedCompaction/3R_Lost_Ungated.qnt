// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The rebuild needs no cover.
module ConfirmedCompaction_3R_Lost_Ungated {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = { ...Holding, heal: Ungated }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = lostSafety
  temporal prop = noDropNoStrand
}
