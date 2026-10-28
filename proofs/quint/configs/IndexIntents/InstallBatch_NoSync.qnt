// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// InstallBatch, with the install settling without syncing the primary.
module IndexIntents_InstallBatch_NoSync {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 2,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, installMode: Unsynced }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
