// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Without the ban, a replica that retired and reaped an origin takes its
/// events again once the node rejoins.
module OriginRetirementSet_UnbannedS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    cfg = { ...Shipped, reap: ReapWhen(EveryMemberLevel), banEnforced: false }
  ).* from "../specs/OriginRetirementSet"

  run skipBlindToARejoinedOriginTest =
    init
      .then(mint("r1"))
      .then(depart("r1"))
      .then(retire("r2", "r1"))
      .then(join("r1"))
      .expect(not(retiredSkipIsSafe) and noOverClaim and noSpuriousGap and noDataLoss)
}

/// The same run with the ban: the retired origin's event is refused.
module OriginRetirementSet_UniversalS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = Shipped
  ).* from "../specs/OriginRetirementSet"

  run banRefusesARejoinedOriginTest =
    init
      .then(mint("r1"))
      .then(depart("r1"))
      .then(retire("r2", "r1"))
      .then(join("r1"))
      .then(sync("r2", "r1"))
      .expect(safety and replicas.get("r2").applied == Set())
}

/// Retirement alone: r2 reaps r1 while r3, which never retired it, has
/// not received the event r2 reclaimed. Nothing will flag r3's deficit.
module OriginRetirementSet_NoneCompactS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    cfg = { ...Shipped, reap: ReapWhen(RetiredHere), compaction: true, stableMembership: true }
  ).* from "../specs/OriginRetirementSet"

  run reapStrandsAnUnretiredMemberTest =
    init
      .then(mint("r1"))
      .then(sync("r2", "r1"))
      .then(depart("r1"))
      .then(compact("r2", { org: "r1", seq: 1 }))
      .then(retire("r2", "r1"))
      .then(reap("r2", "r1"))
      .expect(stuck("r3", { org: "r1", seq: 1 }) and safety)
}

/// The same run under the shipped guard: r3 has not retired r1, so r2
/// may not reap.
module OriginRetirementSet_UniversalCompactS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    cfg = { ...Shipped, compaction: true, stableMembership: true }
  ).* from "../specs/OriginRetirementSet"

  run guardWaitsForEveryMemberTest =
    init
      .then(mint("r1"))
      .then(sync("r2", "r1"))
      .then(depart("r1"))
      .then(compact("r2", { org: "r1", seq: 1 }))
      .then(retire("r2", "r1"))
      .then(reap("r2", "r1").fail())
}

/// A retirement enforced but never persisted: r3 reaps r1, a restart
/// forgets the retirement, and r3 reads a deficit against r1 for the
/// event it holds.
module OriginRetirementSet_ForgetfulS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, retirementDurable: false }
  ).* from "../specs/OriginRetirementSet"

  run restartForgetsALicensedReapTest =
    init
      .then(mint("r1"))
      .then(depart("r2"))
      .then(sync("r3", "r1"))
      .then(depart("r1"))
      .then(retire("r3", "r1"))
      .then(reap("r3", "r1"))
      .then(join("r1"))
      .then(restart("r3"))
      .expect(not(noSpuriousGap) and noOverClaim and noDataLoss and retiredSkipIsSafe)
}

/// Churn: r2 is away while r3, the sole member, retires and reaps r1. r2
/// returns holding neither the retirement nor the event r3 reclaimed.
module OriginRetirementSet_UniversalChurnS1_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, compaction: true }
  ).* from "../specs/OriginRetirementSet"

  run absentMemberWasNotConsultedTest =
    init
      .then(mint("r1"))
      .then(depart("r2"))
      .then(sync("r3", "r1"))
      .then(depart("r1"))
      .then(compact("r3", { org: "r1", seq: 1 }))
      .then(retire("r3", "r1"))
      .then(reap("r3", "r1"))
      .then(join("r2"))
      .expect(stuck("r2", { org: "r1", seq: 1 }) and safety)
}

/// Both survivors retire r1 and both reap it.
module OriginRetirementSet_UniversalProbe_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, stableMembership: true }
  ).* from "../specs/OriginRetirementSet"

  run everyMemberReapsTest =
    init
      .then(mint("r1"))
      .then(sync("r2", "r1"))
      .then(depart("r1"))
      .then(retire("r2", "r1"))
      .then(sync("r3", "r2"))
      .then(retire("r3", "r1"))
      .then(reap("r2", "r1"))
      .then(reap("r3", "r1"))
      .expect(not(notAllMembersReaped) and safety)
}

/// The same run under the meet rule: once r2 reaps, r3's claim on r1 is
/// no longer level with it, and never will be.
module OriginRetirementSet_MeetProbe_test {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.* from "../configs/OriginRetirementSet.configs"
  import OriginRetirementSet(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1,
    cfg = { ...Shipped, reap: ReapWhen(EveryMemberLevel), stableMembership: true }
  ).* from "../specs/OriginRetirementSet"

  run firstReapUnlevelsTheRestTest =
    init
      .then(mint("r1"))
      .then(sync("r2", "r1"))
      .then(depart("r1"))
      .then(retire("r2", "r1"))
      .then(sync("r3", "r2"))
      .then(retire("r3", "r1"))
      .then(reap("r2", "r1"))
      .then(reap("r3", "r1").fail())
}
