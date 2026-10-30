// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Without the cap: a truncation reaches the confirmed frontier whether or
/// not the replica applied every key below it.
module ConfirmedCompaction_2R_Async_NoCap {
  import ConfirmedCompactionTypes.* from "../../specs/ConfirmedCompaction"
  import ConfirmedCompactionConfigs.* from "../ConfirmedCompaction.configs"
  import ConfirmedCompaction(
    Replicas = Set(1, 2), MaxSeq = 2, Skew = 1, MaxCuts = 0, MaxRetire = 0, MaxLost = 0,
    cfg = { ...Async, capAtUnapplied: false }
  ).* from "../../specs/ConfirmedCompaction"
  val inv = noLoss and prefixClosed
  temporal prop = noDrop
}
