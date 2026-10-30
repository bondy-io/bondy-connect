// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// NoIntents_Version, with a clean close and a trusting open: the counter
/// must resume above the versions the index holds.
module IndexIntents_NoIntents_Version_Clean {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 1,
    MaxIndexEntries = 100,
    cfg = { ...NoIntents, orderByVersion: true }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
