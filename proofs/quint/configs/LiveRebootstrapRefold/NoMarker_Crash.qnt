// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// No durable re-fold mark.
module LiveRebootstrapRefold_NoMarker_Crash {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 0, MaxCrashes = 1, MaxWriteFails = 0,
    cfg = { ...Proposed, durableMark: false }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
