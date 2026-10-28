// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A node cut off before a revocation keeps passing the fence on its own
/// local commits, without having seen the revocation.
module AuthFence_Refuse_CommitBumps_test {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.* from "../configs/AuthFence.configs"
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = { ...Refusing, commitBumps: true }
  ).* from "../specs/AuthFence"

  run cutOffWriterPassesTest =
    init
      .then(partition)
      .then(tick)
      .then(revoke)
      .then(tick)
      .then(tick)
      .then(localCommit("r2"))
      .expect(not(fenceSafe))
}

/// Under `Refuse` the same node, unable to confirm, stops passing.
module AuthFence_Refuse_test {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.* from "../configs/AuthFence.configs"
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = Refusing
  ).* from "../specs/AuthFence"

  run cutOffNodeStopsPassingTest =
    init
      .then(partition)
      .then(tick)
      .then(revoke)
      .then(tick)
      .then(tick)
      .expect(fenceSafe and not(passes(views.get("r2"), now)))
      .then(heal)
      .then(sync("r2", "r1"))
      .expect(fenceSafe and views.get("r2").sawRevocation)
}

/// Under `Proceed` an isolated node confirms itself and passes without the
/// revocation.
module AuthFence_Proceed_test {
  import AuthFenceTypes.* from "../specs/AuthFence"
  import AuthFenceConfigs.* from "../configs/AuthFence.configs"
  import AuthFence(
    Nodes = Set("r1", "r2"), Revoker = "r1", MaxLag = 1, MaxTime = 5,
    cfg = { ...Refusing, policy: Proceed }
  ).* from "../specs/AuthFence"

  run isolatedNodePassesTest =
    init
      .then(partition)
      .then(tick)
      .then(revoke)
      .then(tick)
      .then(tick)
      .then(isolated("r2"))
      .expect(not(fenceSafe))
}
