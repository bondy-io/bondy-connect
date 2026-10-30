// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The proposed order with the session expiry off, three replicas.
module LiveRebootstrapRefold_NoExpiry_3R_Safety {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    MaxFaults = 3, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = { ...Proposed, sessionExpiry: false }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
