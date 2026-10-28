// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// No witnesses: each replica truncates its own event, which the other has
/// never received, and the two refuse each other as sources for good.
module JoinInstall_Truncation_CompactOwn_Stranded_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, compactBy: Own }
  ).* from "../specs/JoinInstall"

  run ownTruncationStrandsTest =
    init
      .then(mint("r1", true))
      .then(mint("r2", true))
      .then(reserve("r1", 1, Set()))
      .then(reserve("r2", 2, Set()))
      .expect(not(noStrandedRecord))
}

/// Replicas alone, joined at any time: both truncate alone, then join.
module JoinInstall_Truncation_CompactMembers_SoloJoinAny_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, join: AloneJoinAny }
  ).* from "../specs/JoinInstall"

  run joinAfterTruncationStrandsTest =
    init
      .then(mint("r1", true))
      .then(mint("r2", true))
      .then(reserve("r1", 1, Set()))
      .then(reserve("r2", 2, Set()))
      .then(join)
      .expect(not(noStrandedRecord))
}

/// A member returns without the clean-join rule after both sides
/// truncated apart.
module JoinInstall_Truncation_CompactMembers_Leave_JoinAny_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, leave: true }
  ).* from "../specs/JoinInstall"

  run returnAfterTruncationStrandsTest =
    init
      .then(mint("r1", true))
      .then(mint("r2", true))
      .then(leave("r1"))
      .then(reserve("r1", 1, Set()))
      .then(reserve("r2", 2, Set()))
      .then(rejoin("r1"))
      .expect(not(noStrandedRecord))
}

/// The clean-join rule holds both the join and the return once both sides
/// hold a truncation record, and a member still counts the other's claims.
module JoinInstall_Truncation_CompactMembers_Leave_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, join: AloneJoinClean, leave: true }
  ).* from "../specs/JoinInstall"

  run cleanJoinHoldsTheJoinTest =
    init
      .then(mint("r1", true))
      .then(mint("r2", true))
      .then(reserve("r1", 1, Set()))
      .then(reserve("r2", 2, Set()))
      .then(join.fail())

  run cleanJoinHoldsTheReturnTest =
    init
      .then(mint("r1", true))
      .then(mint("r2", true))
      .then(join)
      .then(leave("r1"))
      .then(reserve("r1", 1, Set()))
      .then(reserve("r2", 2, Set()))
      .then(rejoin("r1").fail())

  run membersConfirmBeforeATruncationTest =
    init
      .then(mint("r1", true))
      .then(join)
      .then(reserve("r1", 1, Set()).fail())
}

/// A replica writes its mark while it serves an open session: two mutual
/// sessions mark both replicas, and neither can serve the other.
module JoinInstall_Truncation_CompactMembers_NoBusy_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 2, MaxCrashes = 0,
    cfg = { ...Code, busy: false }
  ).* from "../specs/JoinInstall"

  run mutualSessionsMarkBothTest =
    init
      .then(readFrontier("r2", "r1"))
      .then(readFrontier("r1", "r2"))
      .then(begin("r1"))
      .then(begin("r2"))
      .expect(not(someoneServes))
}

/// A marked source serves: a session reads from a replica whose own
/// session marked it, and that session then fails.
module JoinInstall_Truncation_CompactMembers_NoServe_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 2, MaxCrashes = 0,
    cfg = { ...Code, serve: false }
  ).* from "../specs/JoinInstall"

  run markedSourceServesTest =
    init
      .then(readFrontier("r2", "r1"))
      .then(begin("r2"))
      .then(readFrontier("r1", "r2"))
      .then(abort("r2"))
      .then(begin("r1"))
      .expect(not(someoneServes))
}

/// The code on the two runs above: each stops where its guard is back.
module JoinInstall_Truncation_CompactMembers_NoServe_NoBusy_control_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 2, MaxCrashes = 0,
    cfg = Code
  ).* from "../specs/JoinInstall"

  /// A replica serving an open session does not mark itself, and its own
  /// session is refused instead.
  run busyReplicaDoesNotMarkTest =
    init
      .then(readFrontier("r2", "r1"))
      .then(readFrontier("r1", "r2"))
      .then(begin("r1").fail())

  run busyReplicaRefusesTest =
    init
      .then(readFrontier("r2", "r1"))
      .then(readFrontier("r1", "r2"))
      .then(refuse("r1"))
      .expect(someoneServes and replicas.get("r1").session == Idle)

  /// A marked replica serves no session.
  run markedSourceRefusesTest =
    init
      .then(readFrontier("r2", "r1"))
      .then(begin("r2"))
      .then(readFrontier("r1", "r2").fail())
}

/// `witnesses` name confirming members under `Recorded` only.
module JoinInstall_Truncation_CompactRecorded_witnesses_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, compactBy: Recorded }
  ).* from "../specs/JoinInstall"

  run recordedNeedsAWitnessTest =
    init
      .then(mint("r1", true))
      .then(reserve("r1", 1, Set()).fail())
}

module JoinInstall_Truncation_CompactMembers_SoloJoinAny_witnesses_test {
  import JoinInstallTypes.* from "../specs/JoinInstall"
  import JoinInstallConfigs.* from "../configs/JoinInstall.configs"
  import JoinInstall(
    Replicas = Set("r1", "r2"), MaxSeq = 1, MaxEvents = 2, MaxInstalls = 1, MaxCrashes = 0,
    cfg = { ...Code, join: AloneJoinAny }
  ).* from "../specs/JoinInstall"

  run membersTakeNoWitnessTest =
    init
      .then(mint("r1", true))
      .then(reserve("r1", 1, Set("r2")).fail())

  run soloTruncatesTest =
    init
      .then(mint("r1", true))
      .then(reserve("r1", 1, Set()))
}
