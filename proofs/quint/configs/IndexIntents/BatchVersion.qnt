// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents, with one version for a whole batch.
module IndexIntents_BatchVersion {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, versionPerEvent: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
