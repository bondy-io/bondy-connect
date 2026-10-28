// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A fused instance, two replicas, two events each, one page lost.
module ConfirmedCompaction_2R_Seq2_Lost {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = Holding
  ).* from "../../specs/ConfirmedCompaction"
  val inv = lostSafety
  temporal prop = noDropNoStrand
}
