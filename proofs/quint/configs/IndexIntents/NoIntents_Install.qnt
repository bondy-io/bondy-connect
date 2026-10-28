// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// NoIntents, with a catalogue install.
module IndexIntents_NoIntents_Install {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = NoIntents
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
