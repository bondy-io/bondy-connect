// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents, with a crash keeping any subset of the unsynced entries.
module IndexIntents_Intents_Subset {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, crashKeeps: AnySubset, indexCrashKeeps: AnySubset }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
