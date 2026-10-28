// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The proposed order, with one failed install write counted
/// installed.
module LiveRebootstrapRefold_Proposed_WriteFailCounted {
  import LiveRebootstrapRefoldTypes.* from "../../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 1,
    cfg = { ...Proposed, writeFail: CountedInstalled }
  ).* from "../../specs/LiveRebootstrapRefold"
  val inv = safety
}
