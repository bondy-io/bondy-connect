// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// NoIntents_Writer, with the rebuild marking only after a good flush.
module IndexIntents_NoIntents_Writer_MarkNeedsFlush {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...NoIntents, markNeedsFlush: true }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
