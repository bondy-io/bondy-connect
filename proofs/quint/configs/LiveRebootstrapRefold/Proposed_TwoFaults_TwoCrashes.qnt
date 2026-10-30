// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The proposed order.
module LiveRebootstrapRefold_Proposed_TwoFaults_TwoCrashes {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 1,
    MaxFaults = 2, MaxTrailFails = 1, MaxCrashes = 2, MaxWriteFails = 0,
    cfg = Proposed
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
