// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Intents, with the version restarting at zero after a crash.
module IndexIntents_VersionReset {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, versionSource: Reset }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
