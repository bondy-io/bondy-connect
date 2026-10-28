// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The re-fold max-merges the old frontier instead of resetting it.
module LiveRebootstrapRefold_MergeFrontier_3R_Safety {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    MaxFaults = 2, MaxTrailFails = 1, MaxCrashes = 1, MaxWriteFails = 0,
    cfg = { ...Proposed, resetFrontier: false }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
