// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// No intents: HLC order, a full rebuild at every open, no install. The
/// rebuild marks after a failed flush and drops requests that arrive while it
/// runs.
module IndexIntents_NoIntents {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = NoIntents
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
