// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module AuthFenceConfigs {
  import AuthFenceTypes.* from "../specs/AuthFence"

  /// Two clustered nodes under policy `Refuse`: only a sync confirms.
  pure val Refusing = { clustered: true, policy: Refuse, commitBumps: false }
}

module AuthFence_Refuse {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.*
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = Refusing
  ).* from "../specs/AuthFence"
  val inv = fenceSafe
}

/// A local commit confirms freshness.
module AuthFence_Refuse_CommitBumps {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.*
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = { ...Refusing, commitBumps: true }
  ).* from "../specs/AuthFence"
  val inv = fenceSafe
}

/// Policy `Proceed`: an isolated node confirms itself.
module AuthFence_Proceed {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.*
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = { ...Refusing, policy: Proceed }
  ).* from "../specs/AuthFence"
  val inv = fenceSafe
}

/// One node with clustering off: it confirms itself every round.
module AuthFence_Single {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.*
  import AuthFence(
    Nodes = Set("r1"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = { ...Refusing, clustered: false }
  ).* from "../specs/AuthFence"
  val inv = fenceSafe
}
