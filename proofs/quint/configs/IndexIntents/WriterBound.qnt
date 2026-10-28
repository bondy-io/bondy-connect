// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents_2Shards, with every shard clearing up to the writer-wide highest
/// version.
module IndexIntents_WriterBound {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1", "k2"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, clearBound: ByWriter }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
