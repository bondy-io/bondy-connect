// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// `r1` compacts `(r1,1)` out of its tree, and `r2` integrates the
/// truncated tree: it holds `(r1,2)` without `(r1,1)` and claims both.
module AaeCausalClosure_Unheld_test {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.* from "../configs/AaeCausalClosure.configs"
  import AaeCausalClosure(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 2, Seed = "r1", cfg = Unheld
  ).* from "../specs/AaeCausalClosure"

  run holeBelowTheMaxTest =
    init
      .then(bootstrap("r2", "r1"))
      .then(mint("r1"))
      .then(mint("r1"))
      .then(compact("r1", Map("r1" -> 1, "r2" -> 0, "r3" -> 0)))
      .then(sync("r2", "r1"))
      .expect(not(prefixClosed) and not(noOverClaim))
}

/// The same run under the hold: `r2` holds `(r1,2)` back, claims nothing
/// of `r1`, flags the gap, and its rebootstrap delivers both events.
module AaeCausalClosure_Shipped_test {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.* from "../configs/AaeCausalClosure.configs"
  import AaeCausalClosure(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Seed = "r1", cfg = Held
  ).* from "../specs/AaeCausalClosure"

  run heldThenRebootstrappedTest =
    init
      .then(bootstrap("r2", "r1"))
      .then(mint("r1"))
      .then(mint("r1"))
      .then(compact("r1", Map("r1" -> 1, "r2" -> 0)))
      .then(sync("r2", "r1"))
      .expect(and {
        prefixClosed,
        noOverClaim,
        replicas.get("r2").applied == Set(),
        replicas.get("r2").gapFlag,
      })
      .then(rebootstrap("r2", "r1"))
      .expect(replicas.get("r2").applied == replicas.get("r1").applied and prefixClosed)
}
