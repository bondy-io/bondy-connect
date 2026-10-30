// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// No intents, with index cells ordered by a per-shard version recovered from
/// the index: the state after the version counter lands and before intents
/// do.
module IndexIntents_NoIntents_Version {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...NoIntents, orderByVersion: true }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
