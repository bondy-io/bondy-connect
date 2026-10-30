// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents_Subset, with an install group writing over unsynced primary
/// writes.
module IndexIntents_Intents_Subset_NoInstallSync {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = {
      ...Source,
      crashKeeps: AnySubset,
      indexCrashKeeps: AnySubset,
      syncBeforeInstall: false,
    }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
