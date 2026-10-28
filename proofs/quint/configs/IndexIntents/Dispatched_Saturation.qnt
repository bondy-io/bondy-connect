// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents_Saturation, clearing up to what the shard had dispatched when the
/// barrier began.
module IndexIntents_Dispatched_Saturation {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
