// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched_Writer, with an open whose flush failed freshening the index
/// anyway.
module IndexIntents_FreshenWithoutFlush {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, freshenNeedsFlush: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
