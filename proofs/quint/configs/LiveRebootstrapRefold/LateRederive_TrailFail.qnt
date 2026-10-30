// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The full re-fold runs only after a successful trailing round.
module LiveRebootstrapRefold_LateRederive_TrailFail {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = { ...Proposed, refold: AfterTrail }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
