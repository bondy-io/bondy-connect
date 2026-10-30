// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Stage_Crash_2I {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 2, MaxCrashes = 1,
    cfg = InstallOnly
  ).* from "../../specs/JoinInstall"
  val inv = settledSound and someoneServes
}
