// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents, with a backlog drop and a writer crash; one event per batch, no
/// install, one term.
module IndexIntents_Intents_Rebuild {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Source
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
