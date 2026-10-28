// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Dispatched with a writer crash, values {none, a}, one event: a writer
/// that restarts inside an install group replays its intents, then syncs
/// the primary.
module IndexIntents_InstallBatch_Writer {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 1, MaxBatch = 1, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
