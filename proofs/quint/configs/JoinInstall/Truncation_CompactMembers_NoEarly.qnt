// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Truncation_CompactMembers_NoEarly {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 2, MaxCrashes = 0,
    cfg = { ...Code, early: false }
  ).* from "../../specs/JoinInstall"
  val inv = safety
}
