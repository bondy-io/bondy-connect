// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents_Rebuild with two writer crashes, the rebuild marking the index
/// trusted after a failed flush.
module IndexIntents_MarkWithoutFlush {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 2, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, markNeedsFlush: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
