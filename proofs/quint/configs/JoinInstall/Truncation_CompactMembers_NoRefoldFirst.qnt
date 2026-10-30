// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Truncation_CompactMembers_NoRefoldFirst {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 2, MaxEvents = 3, MaxInstalls = 1, MaxCrashes = 1,
    cfg = { ...Code, refoldFirst: false }
  ).* from "../../specs/JoinInstall"
  val inv = safety
}
