// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The code on an applier-backed instance, over the whole reachable graph:
/// the TLC backend passes no `CONSTRAINT` to bound its depth.
module ConfirmedCompaction_3R_Async_Depth {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2, 3), MaxSeq = 1, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = Async
  ).* from "../../specs/ConfirmedCompaction"
  val inv = safety
  temporal prop = noDrop
}
