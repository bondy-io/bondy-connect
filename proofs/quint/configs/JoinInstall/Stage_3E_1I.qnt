// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Stage_3E_1I {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 2, MaxEvents = 3, MaxInstalls = 1, MaxCrashes = 0,
    cfg = InstallOnly
  ).* from "../../specs/JoinInstall"
  val inv = settledSound and someoneServes
}
