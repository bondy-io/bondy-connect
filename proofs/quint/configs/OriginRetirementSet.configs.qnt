// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module OriginRetirementSetConfigs {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"

  /// The shipped design: reap once every member has retired the origin,
  /// ban its events, persist a retirement before enforcing it. Members may
  /// depart and rejoin at any time; the log is never reclaimed.
  pure val Shipped = {
    reap: ReapWhen(EveryMemberRetired),
    banEnforced: true,
    compaction: false,
    retirementDurable: true,
    stableMembership: false,
  }
}

/// A retirement can be enforced before it is persisted, and lost on restart.
module OriginRetirementSet_ForgetfulS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, retirementDurable: false }).* from "../specs/OriginRetirementSet"
  val inv = safety
}

/// Can every member reap a retired origin under the meet rule, with the
/// survivors stable?
module OriginRetirementSet_MeetProbe {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, reap: ReapWhen(EveryMemberLevel), stableMembership: true }).* from "../specs/OriginRetirementSet"
  val inv = notAllMembersReaped
}

/// Retirement alone licenses the reap, with the log reclaimed and the
/// survivors stable.
module OriginRetirementSet_NoneCompactS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, reap: ReapWhen(RetiredHere), compaction: true, stableMembership: true }).* from "../specs/OriginRetirementSet"
  val inv = safety and noStuckEvent
}

/// The meet rule with the ban not enforced.
module OriginRetirementSet_Unbanned {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 2, cfg = { ...Shipped, reap: ReapWhen(EveryMemberLevel), banEnforced: false }).* from "../specs/OriginRetirementSet"
  val inv = safety
}

/// The meet rule with the ban not enforced.
module OriginRetirementSet_UnbannedS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, reap: ReapWhen(EveryMemberLevel), banEnforced: false }).* from "../specs/OriginRetirementSet"
  val inv = safety
}

/// The shipped design.
module OriginRetirementSet_Universal {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 2, cfg = Shipped).* from "../specs/OriginRetirementSet"
  val inv = safety
}

/// The shipped guard with the log reclaimed.
module OriginRetirementSet_UniversalChurnS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, compaction: true }).* from "../specs/OriginRetirementSet"
  val inv = safety and noStuckEvent
}

/// The shipped guard with the log reclaimed and the survivors stable.
module OriginRetirementSet_UniversalCompactS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, compaction: true, stableMembership: true }).* from "../specs/OriginRetirementSet"
  val inv = safety and noStuckEvent
}

/// Can every member reap a retired origin under the shipped guard, with
/// the survivors stable?
module OriginRetirementSet_UniversalProbe {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, stableMembership: true }).* from "../specs/OriginRetirementSet"
  val inv = notAllMembersReaped
}

/// The shipped design.
module OriginRetirementSet_UniversalS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = Shipped).* from "../specs/OriginRetirementSet"
  val inv = safety
}

/// The shipped guard without the ban.
module OriginRetirementSet_UniversalUnbannedS1 {
  import OriginRetirementSetTypes.* from "../specs/OriginRetirementSet"
  import OriginRetirementSetConfigs.*
  import OriginRetirementSet(Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Shipped, banEnforced: false }).* from "../specs/OriginRetirementSet"
  val inv = safety
}
