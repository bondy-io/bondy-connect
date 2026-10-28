// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A door that drops the applied events at or below the watermark whether
/// every witness confirms them or not.
module ConfirmedCompaction_3R_DoorDrop {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Code, door: DropsApplied }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = noLoss and noGap and prefixClosed
  temporal prop = noDrop
}
