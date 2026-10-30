// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// An install that yields no index ops leaves the index without the term the
/// installed cell holds.
module IndexIntents_NoInstallIndex_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, installMode: NoIndexOps }
  ).* from "../specs/IndexIntents"

  run installWithoutOpsTest =
    init
      .then(write("k1", ["none"]))
      .then(install("k1", "a", 1))
      .expect(not(indexMatchesPrimary))
}

/// The runs below with each mechanism in place: the index ends equal to the
/// primary.
module IndexIntents_Intents_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Source
  ).* from "../specs/IndexIntents"

  run installSettlesIntoTheIndexTest =
    init
      .then(write("k1", ["none"]))
      .then(install("k1", "a", 1))
      .then(installSettle("k1"))
      .then(flush)
      .expect(indexMatchesPrimary and live(index.journal, "a", "k1"))

  /// Each event of a batch takes its own version, so a put and a later
  /// remove of one term do not tie.
  run batchOrdersItsEventsTest =
    init
      .then(write("k1", ["a", "none"]))
      .then(dispatch("k1"))
      .then(barrier("k1"))
      .expect(indexMatchesPrimary and not(live(index.journal, "a", "k1")))

  /// Ordered by the version, a remove from an install at an older HLC still
  /// supersedes the put.
  run installAtAnOlderHlcTest =
    init
      .then(write("k1", ["a"]))
      .then(dispatch("k1"))
      .then(install("k1", "none", 1))
      .then(installSettle("k1"))
      .then(barrier("k1"))
      .expect(indexMatchesPrimary and not(live(index.journal, "a", "k1")))
}

/// One version per batch: a put and a remove of one term in one batch tie, and
/// the put wins.
module IndexIntents_BatchVersion_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, versionPerEvent: false }
  ).* from "../specs/IndexIntents"

  run putAndRemoveTieTest =
    init
      .then(write("k1", ["a", "none"]))
      .then(dispatch("k1"))
      .then(barrier("k1"))
      .expect(not(indexMatchesPrimary))
}

/// Ordered by the cell HLC, a remove from an install at an older HLC loses to
/// the put it should supersede.
module IndexIntents_HlcOrder_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, orderByVersion: false }
  ).* from "../specs/IndexIntents"

  run installAtAnOlderHlcTest =
    init
      .then(write("k1", ["a"]))
      .then(dispatch("k1"))
      .then(install("k1", "none", 1))
      .then(installSettle("k1"))
      .then(barrier("k1"))
      .expect(not(indexMatchesPrimary))
}

/// Clearing up to the counter: the barrier clears an intent whose ops were
/// never dispatched, and a crash leaves nothing to replay them from.
module IndexIntents_DrawnBound_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, clearBound: ByDrawn }
  ).* from "../specs/IndexIntents"

  run clearsAnUndispatchedIntentTest =
    init
      .then(write("k1", ["a"]))
      .then(barrier("k1"))
      .then(crash(Keys.mapBy(k => shards.get(k).journal), []))
      .then(replayOpen("k1"))
      .expect(not(indexMatchesPrimary))
}

/// The same run clearing up to what the shard had dispatched: the barrier
/// clears nothing, and the open replays the intent.
module IndexIntents_Dispatched_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 2, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 0, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../specs/IndexIntents"

  run keepsAnUndispatchedIntentTest =
    init
      .then(write("k1", ["a"]))
      .then(barrier("k1"))
      .then(crash(Keys.mapBy(k => shards.get(k).journal), []))
      .then(replayOpen("k1"))
      .expect(writer.buf.exists(o => o.t == "a" and o.live))
}

/// A restarted writer that replays before it registers loses an op dispatched
/// between the two.
module IndexIntents_ReplayBeforeStamp_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Source, stampBeforeReplay: false }
  ).* from "../specs/IndexIntents"

  run dispatchBeforeTheStampTest =
    init
      .then(writerCrash)
      .then(writerRegister)
      .then(write("k1", ["a"]))
      .then(dispatch("k1"))
      .then(writerReplay)
      .expect(not(indexMatchesPrimary))
}

/// The same run with the writer registered first: the dispatch reaches it.
module IndexIntents_Dispatched_Writer_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a", "b"),
    MaxEvents = 2, MaxBatch = 1, MaxInstalls = 0,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../specs/IndexIntents"

  run dispatchAfterTheStampTest =
    init
      .then(writerCrash)
      .then(writerRegister)
      .then(write("k1", ["a"]))
      .then(dispatch("k1"))
      .then(writerReplay)
      .then(flush)
      .expect(indexMatchesPrimary and live(index.journal, "a", "k1"))
}

/// Without the replay's sync: a writer restarted inside an install group
/// replays the group's intent, which the primary has not synced, and flushes
/// it. A crash keeps that index batch and loses the install, which no WAL
/// re-presents.
module IndexIntents_InstallBatch_Writer_NoReplaySync_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 1, MaxBatch = 1, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = { ...Code, replaySyncs: false }
  ).* from "../specs/IndexIntents"

  run restartReplaysAnUnsettledInstallTest =
    init
      .then(write("k1", ["none"]))
      .then(install("k1", "a", 1))
      .then(writerCrash)
      .then(writerRegister)
      .then(writerReplay)
      .then(flush)
      .then(crash(Keys.mapBy(k => shards.get(k).journal.slice(0, 1)), index.journal))
      .then(replayOpen("k1"))
      .then(redo("k1"))
      .expect(not(indexMatchesPrimary) and live(index.journal, "a", "k1"))
}

/// The code's mechanism on the same run: the replay syncs the primary after
/// reading its intents, so the crash keeps the install's cell.
module IndexIntents_InstallBatch_Writer_test {
  import IndexIntentsTypes.* from "../specs/IndexIntents"
  import IndexIntentsConfigs.* from "../configs/IndexIntents.configs"
  import IndexIntents(
    Keys = Set("k1"), Vals = Set("none", "a"),
    MaxEvents = 1, MaxBatch = 1, MaxInstalls = 1,
    MaxCrashes = 1, MaxWriterCrashes = 1, MaxSaturations = 0, MaxCleanReopens = 0,
    MaxIndexEntries = 100,
    cfg = Code
  ).* from "../specs/IndexIntents"

  run replaySyncsAnUnsettledInstallTest =
    init
      .then(write("k1", ["none"]))
      .then(install("k1", "a", 1))
      .then(writerCrash)
      .then(writerRegister)
      .then(writerReplay)
      .expect(shards.get("k1").synced == shards.get("k1").journal.length())
      .then(flush)
      .then(crash(Keys.mapBy(k => shards.get(k).journal.slice(0, 1)), index.journal).fail())
}
