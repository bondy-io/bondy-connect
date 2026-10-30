// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched_Clean, with the open freshening the index without flushing the
/// writer first.
module IndexIntents_OpenNoFlush {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 1,
    MaxIndexEntries = 100,
    cfg = { ...Code, openFlushes: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
