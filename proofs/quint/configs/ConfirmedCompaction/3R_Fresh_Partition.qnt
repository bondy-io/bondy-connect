// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A recency filter on the witnesses, under a partition: two replicas cut
/// off from the third drop its row and compact with each other alone.
module ConfirmedCompaction_3R_Fresh_Partition {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 2, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Code, witnesses: FreshMembers }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = noLoss and prefixClosed
  temporal prop = noDrop
}
