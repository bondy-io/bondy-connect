// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstall_Truncation_CompactRecorded_Stranded_3R {
  import JoinInstallTypes.* from "../../specs/JoinInstall"
  import JoinInstallConfigs.* from "../JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, compactBy: Recorded }
  ).* from "../../specs/JoinInstall"
  val inv = safety
}
