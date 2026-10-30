// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Without the mark: r1's install replaces its cell with r2's empty one,
/// and a subtree restart keeps the frontier, which claims r1's own event,
/// so the cursor is re-anchored past an event the cell lost.
module LiveRebootstrapRefold_NoMarker_Crash_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 0, MaxCrashes = 1, MaxWriteFails = 0,
    cfg = { ...Proposed, durableMark: false }
  ).* from "../specs/LiveRebootstrapRefold"

  run restartStrandsAReplacedEventTest =
    init
      .then(mint("r1"))
      .then(fault("r1"))
      .then(begin("r1", "r2"))
      .then(install("r1"))
      .then(crash("r1", true))
      .expect(not(noStrandedEvent) and replicas.get("r1").cell == Set())
}

/// The same run with the mark: the restart resets the frontier and leaves
/// the cursor undefined, so the boot re-fold restores the event.
module LiveRebootstrapRefold_Proposed_Crash_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 0, MaxCrashes = 1, MaxWriteFails = 0,
    cfg = Proposed
  ).* from "../specs/LiveRebootstrapRefold"

  run markForcesTheBootRefoldTest =
    init
      .then(mint("r1"))
      .then(fault("r1"))
      .then(begin("r1", "r2"))
      .then(install("r1"))
      .then(crash("r1", true))
      .expect(safety and replicas.get("r1").cursor == Set())
      .then(replay("r1"))
      .expect(safety and replicas.get("r1").cell == replicas.get("r1").tree and not(replicas.get("r1").owed))
}

/// Skip-if-older: r2's own event is newer than r1's, so r2 keeps its cell
/// and still adopts r1's frontier, which claims r1's event.
module LiveRebootstrapRefold_SkipIfOlder_TrailFail_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = { ...Proposed, install: KeepNewer }
  ).* from "../specs/LiveRebootstrapRefold"

  run keptCellUnderAnAdoptedFrontierTest =
    init
      .then(mint("r1"))
      .then(mint("r2"))
      .then(fault("r2"))
      .then(begin("r2", "r1"))
      .then(install("r2"))
      .then(rederive("r2"))
      .then(finalize("r2"))
      .then(trailFail("r2"))
      .expect(not(claimSound) and noStrandedEvent)
}

/// The re-fold waits for a successful trailing round, which fails: r1's
/// cell lost its own event to the install, and the replay already passed
/// it.
module LiveRebootstrapRefold_LateRederive_TrailFail_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = { ...Proposed, refold: AfterTrail }
  ).* from "../specs/LiveRebootstrapRefold"

  run failedTrailSkipsTheRefoldTest =
    init
      .then(mint("r1"))
      .then(replay("r1"))
      .then(fault("r1"))
      .then(begin("r1", "r2"))
      .then(install("r1"))
      .then(finalize("r1"))
      .then(trailFail("r1"))
      .expect(not(noStrandedEvent))
}

/// Two replicas re-bootstrap from each other: r2 streams r1's cell after
/// r1's install emptied it, and adopts the frontier r1 claimed before.
module LiveRebootstrapRefold_NoServeGuard_TwoFaults_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 1,
    MaxFaults = 2, MaxTrailFails = 1, MaxCrashes = 2, MaxWriteFails = 0,
    cfg = { ...Proposed, serveGuard: false, sessionExpiry: false }
  ).* from "../specs/LiveRebootstrapRefold"

  run mutualRebootstrapTest =
    init
      .then(mint("r1"))
      .then(fault("r1"))
      .then(begin("r1", "r2"))
      .then(install("r1"))
      .then(fault("r2"))
      .then(begin("r2", "r1"))
      .then(install("r2"))
      .then(rederive("r2"))
      .then(finalize("r2"))
      .then(trailFail("r2"))
      .expect(not(claimSound))
}

/// With the serve guard, r1 owes a re-fold once it installs, and refuses
/// r2's session.
module LiveRebootstrapRefold_Proposed_TwoFaults_TwoCrashes_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 1,
    MaxFaults = 2, MaxTrailFails = 1, MaxCrashes = 2, MaxWriteFails = 0,
    cfg = Proposed
  ).* from "../specs/LiveRebootstrapRefold"

  run owingSourceRefusesTest =
    init
      .then(mint("r1"))
      .then(fault("r1"))
      .then(begin("r1", "r2"))
      .then(install("r1"))
      .then(fault("r2"))
      .then(begin("r2", "r1").fail())
}

/// A failed install write counted installed: r2 adopts r1's frontier over
/// a cell the write never reached.
module LiveRebootstrapRefold_Proposed_WriteFailCounted_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 1,
    cfg = { ...Proposed, writeFail: CountedInstalled }
  ).* from "../specs/LiveRebootstrapRefold"

  run adoptsOverAMissedWriteTest =
    init
      .then(mint("r1"))
      .then(fault("r2"))
      .then(begin("r2", "r1"))
      .then(installWriteFail("r2"))
      .then(rederive("r2"))
      .then(finalize("r2"))
      .then(trailFail("r2"))
      .expect(not(claimSound) and replicas.get("r2").cell == Set())
}

/// The same failed write under `FailsBatch`: the session takes the
/// failed-stream path, re-folds, and never adopts the frontier.
module LiveRebootstrapRefold_Proposed_WriteFailAborts_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2"), MaxSeq = 2,
    MaxFaults = 1, MaxTrailFails = 1, MaxCrashes = 1, MaxWriteFails = 1,
    cfg = Proposed
  ).* from "../specs/LiveRebootstrapRefold"

  run failedStreamNeverAdoptsTest =
    init
      .then(mint("r1"))
      .then(fault("r2"))
      .then(begin("r2", "r1"))
      .then(installWriteFail("r2"))
      .then(rederive("r2"))
      .expect(safety and replicas.get("r2").phase == Idle and replicas.get("r2").claim.get("r1") == 0)
}

/// Without the session expiry: r2 adopts r1's frontier from a bootstrap
/// whose trailing round fails, so its MST lacks r1:1. r3 opens a session on
/// r2 and reads that frontier. r2 then re-bootstraps from r3, whose cell
/// lacks r1:1, and finalizes. The session is still valid, so r3 installs
/// r2's new cell and adopts the frontier it read, which claims r1:1.
module LiveRebootstrapRefold_NoExpiry_3R_Safety_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    MaxFaults = 3, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = { ...Proposed, sessionExpiry: false }
  ).* from "../specs/LiveRebootstrapRefold"

  run staleSessionAdoptsAnOldFrontierTest =
    init
      .then(mint("r1"))
      .then(fault("r2")).then(begin("r2", "r1")).then(install("r2"))
      .then(rederive("r2")).then(finalize("r2")).then(trailFail("r2"))
      .then(fault("r3")).then(begin("r3", "r2"))
      .then(fault("r2")).then(begin("r2", "r3")).then(install("r2"))
      .then(rederive("r2")).then(finalize("r2"))
      .then(install("r3")).then(rederive("r3")).then(finalize("r3")).then(trailOk("r3"))
      .expect(and {
        not(claimSound),
        replicas.get("r3").claim.get("r1") == 1,
        replicas.get("r3").cell == Set(),
      })
}

/// The same run with the expiry: r2's install expired r3's session, so r3
/// aborts it, which only an invalid session allows, and retries.
module LiveRebootstrapRefold_Proposed_3R_ThreeFaults_test {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"
  import LiveRebootstrapRefoldConfigs.* from "../configs/LiveRebootstrapRefold.configs"
  import LiveRebootstrapRefold(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    MaxFaults = 3, MaxTrailFails = 1, MaxCrashes = 0, MaxWriteFails = 0,
    cfg = Proposed
  ).* from "../specs/LiveRebootstrapRefold"

  run expiredSessionAbortsTest =
    init
      .then(mint("r1"))
      .then(fault("r2")).then(begin("r2", "r1")).then(install("r2"))
      .then(rederive("r2")).then(finalize("r2")).then(trailFail("r2"))
      .then(fault("r3")).then(begin("r3", "r2"))
      .then(fault("r2")).then(begin("r2", "r3")).then(install("r2"))
      .then(rederive("r2")).then(finalize("r2"))
      .then(abort("r3"))
      .expect(safety and replicas.get("r3").gap)
}
