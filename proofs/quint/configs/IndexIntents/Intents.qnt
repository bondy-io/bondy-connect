// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents in the primary batch, cleared per shard after the index sync,
/// replayed after registration at open and writer restart; a synced install;
/// per-event versions recovered from both stores. Node crash.
module IndexIntents_Intents {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Source
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
