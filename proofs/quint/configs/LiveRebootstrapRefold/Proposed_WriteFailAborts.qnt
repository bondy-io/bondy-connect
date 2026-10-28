// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The proposed order, with one failed install write that fails the
/// batch.
module LiveRebootstrapRefold_Proposed_WriteFailAborts {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 1, MaxWriteFails = 1,
    cfg = Proposed
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
