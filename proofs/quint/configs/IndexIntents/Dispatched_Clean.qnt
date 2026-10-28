// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents_Clean, clearing up to what the shard had dispatched when the
/// barrier began.
module IndexIntents_Dispatched_Clean {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 1,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
