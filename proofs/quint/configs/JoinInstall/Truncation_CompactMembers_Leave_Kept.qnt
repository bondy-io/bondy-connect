// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Truncation_CompactMembers_Leave_Kept {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, join: AloneJoinClean, leave: true, kept: true }
  ).* from "../../specs/JoinInstall"
  val inv = safety
}
