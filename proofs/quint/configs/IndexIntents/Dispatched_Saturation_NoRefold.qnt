// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched_Saturation, with a rebuild whose re-fold dispatches nothing.
module IndexIntents_Dispatched_Saturation_NoRefold {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, rebuildRefolds: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
