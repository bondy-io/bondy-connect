// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// InstallBatch_Writer without the replay's sync: a restarted writer
/// replays an open install group's intents before the group syncs the
/// primary.
module IndexIntents_InstallBatch_Writer_NoReplaySync {
  import IndexIntentsTypes.* from "../../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 1, MaxBatch = 1, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, replaySyncs: false }
  ).* from "../../specs/IndexIntents"
  val inv = safety
}
