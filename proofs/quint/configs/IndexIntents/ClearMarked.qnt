// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched_Remark, with the barrier clearing intents while a rebuild is
/// due.
module IndexIntents_ClearMarked {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 2, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, clearMarked: true }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
