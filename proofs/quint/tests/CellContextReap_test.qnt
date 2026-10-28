// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Compaction empties the MST of the cell's only op: the projection still
/// holds the cell, and the MST walk no longer lists it.
module CellContextReap_R2_DirTree_test {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.* from "../configs/CellContextReap.configs"
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 1, cfg = { ...Reaping, directory: MstWalk }
  ).* from "../specs/CellContextReap"

  pure val rmv1 = { dot: { org: "r1", seq: 1 }, kind: Rmv, ctx: Map("r1" -> 0, "r2" -> 0) }

  run compactedCellIsUnlistedTest =
    init
      .then(mint("r1", Rmv))
      .then(compact("r1", rmv1))
      .expect(not(directoryComplete))

  /// After `r1` departs, its context entry sits in a cell no directory
  /// lists, so no reap can drop it.
  run deadContextUnreachableTest =
    init
      .then(mint("r1", Rmv))
      .then(compact("r1", rmv1))
      .then(depart("r1"))
      .expect(not(deadContextReachable))
}

/// The same run with the adapter's own directory: the cell stays listed and
/// the reap drops the departed origin's entry.
module CellContextReap_R2_CellKeys_test {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.* from "../configs/CellContextReap.configs"
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 1, cfg = Reaping
  ).* from "../specs/CellContextReap"

  pure val rmv1 = { dot: { org: "r1", seq: 1 }, kind: Rmv, ctx: Map("r1" -> 0, "r2" -> 0) }

  run deadContextReapedTest =
    init
      .then(mint("r1", Rmv))
      .then(compact("r1", rmv1))
      .then(depart("r1"))
      .expect(directoryComplete and deadContextReachable)
      .then(reap("r1", "r1"))
      .expect(replicas.get("r1").cc.get("r1") == 0)
}

/// `r3` receives `r2`'s put, which observed `r1`'s, before `r1`'s own: the
/// put drops nothing, so `r3` keeps both dots where `r2` keeps one, over
/// the same applied ops.
module CellContextReap_R3S1_ReapTRUE_CausalFALSE_test {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.* from "../configs/CellContextReap.configs"
  import CellContextReap(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Reaping, causalDelivery: false }
  ).* from "../specs/CellContextReap"

  pure val put1 = { dot: { org: "r1", seq: 1 }, kind: Put, ctx: Map("r1" -> 0, "r2" -> 0, "r3" -> 0) }
  pure val put2 = { dot: { org: "r2", seq: 1 }, kind: Put, ctx: Map("r1" -> 1, "r2" -> 0, "r3" -> 0) }

  run outOfOrderDivergesTest =
    init
      .then(mint("r1", Put))
      .then(deliver("r2", put1))
      .then(mint("r2", Put))
      .then(deliver("r3", put2))
      .then(deliver("r3", put1))
      .expect(not(convergence))
}

/// Under causal delivery `r3` cannot take `r2`'s put first.
module CellContextReap_R3S1_ReapTRUE_CausalTRUE_test {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.* from "../configs/CellContextReap.configs"
  import CellContextReap(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = Reaping
  ).* from "../specs/CellContextReap"

  pure val put1 = { dot: { org: "r1", seq: 1 }, kind: Put, ctx: Map("r1" -> 0, "r2" -> 0, "r3" -> 0) }
  pure val put2 = { dot: { org: "r2", seq: 1 }, kind: Put, ctx: Map("r1" -> 1, "r2" -> 0, "r3" -> 0) }

  run causalDeliveryWaitsTest =
    init
      .then(mint("r1", Put))
      .then(deliver("r2", put1))
      .then(mint("r2", Put))
      .then(deliver("r3", put2))
      .fail()
}
