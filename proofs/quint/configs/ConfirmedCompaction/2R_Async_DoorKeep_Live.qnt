// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A door that drops nothing: two replicas that both compacted may re-ship a
/// confirmed event to each other forever.
module ConfirmedCompaction_2R_Async_DoorKeep_Live {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 0, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Async, door: DropsNothing }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = noDeadlock
  temporal prop = live
}
