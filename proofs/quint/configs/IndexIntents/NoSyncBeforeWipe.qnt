// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched_Subset_Rebuild, without the index sync a rebuild makes between
/// removing the trust mark and wiping the index.
module IndexIntents_NoSyncBeforeWipe {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1", "k2"), Vals = Set("none", "a"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 8,
    cfg = { ...Code, indexCrashKeeps: AnySubset, syncBeforeWipe: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
