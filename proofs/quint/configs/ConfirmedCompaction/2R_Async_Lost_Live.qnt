// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// An applier-backed instance with one page lost: every tree empties.
module ConfirmedCompaction_2R_Async_Lost_Live {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 1,
    cfg = Async
  ).* from "../../specs/ConfirmedCompaction"
  val inv = lostSafety
  temporal prop = live
}
