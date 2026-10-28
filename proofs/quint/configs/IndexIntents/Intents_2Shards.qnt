// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents, with two primary shards sharing the writer, one event per batch,
/// no install.
module IndexIntents_Intents_2Shards {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1", "k2"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Source
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
