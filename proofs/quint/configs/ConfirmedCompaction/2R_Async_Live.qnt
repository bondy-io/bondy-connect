// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The code on an applier-backed instance: every tree empties and every
/// replica applies every event.
module ConfirmedCompaction_2R_Async_Live {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = Async
  ).* from "../../specs/ConfirmedCompaction"
  val inv = noDeadlock
  temporal prop = live
}
