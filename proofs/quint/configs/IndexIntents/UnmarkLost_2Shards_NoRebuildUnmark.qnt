// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// UnmarkLost_2Shards, with the rebuild relying on the marks to have removed
/// the trust mark.
module IndexIntents_UnmarkLost_2Shards_NoRebuildUnmark {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1", "k2"), Vals = Set("none", "a"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 1, MaxCleanReopens = 0,
    MaxIndexEntries = 8,
    cfg = { ...Code, unmarkMayFail: true, rebuildUnmarks: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
