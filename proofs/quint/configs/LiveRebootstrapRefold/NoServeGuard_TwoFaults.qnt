// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A source owing a re-fold still serves.
module LiveRebootstrapRefold_NoServeGuard_TwoFaults {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 1,
    MaxFaults = 2, MaxTrailFails = 1, MaxCrashes = 2, MaxWriteFails = 0,
    cfg = { ...Proposed, serveGuard: false, sessionExpiry: false }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
