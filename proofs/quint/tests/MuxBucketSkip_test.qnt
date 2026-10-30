// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The shipped bootstrap: r2 cannot route b2, installs nothing, and still
/// adopts r1's claim on the event in it.
module MuxBucketSkip_Minus_AdoptIfComplete_test {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.* from "../configs/MuxBucketSkip.configs"
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, adoption: Unconditional }
  ).* from "../specs/MuxBucketSkip"

  run unconditionalAdoptionOverClaimsTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(bootstrap("r2", "r1"))
      .expect(not(noOverClaim) and replicas.get("r2").applied == Set())
}

/// r1 restarts and ships from its partial directory, so r2 skips nothing it
/// can see and adopts the claim on a cell it was never sent.
module MuxBucketSkip_Minus_ServeGate_test {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.* from "../configs/MuxBucketSkip.configs"
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, serveGate: false }
  ).* from "../specs/MuxBucketSkip"

  run partialDirectoryShipsUnderAFullClaimTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(restart("r1"))
      .then(bootstrap("r2", "r1"))
      .expect(not(noOverClaim) and replicas.get("r2").applied == Set())
}

/// The fold skips r1's first event and merges the claim of its second.
module MuxBucketSkip_Minus_SkipHole_Contig_test {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.* from "../configs/MuxBucketSkip.configs"
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, skipIsHole: false, claim: BatchMax }
  ).* from "../specs/MuxBucketSkip"

  run foldClaimsOverASkippedGroupTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(mint("r1", "b1"))
      .then(bootstrap("r2", "r1"))
      .then(replay("r2"))
      .expect(not(noOverClaim) and replicas.get("r2").claim.get("r1") == 2)
}

/// With the verdict withheld, r2's sync against a peer it cannot fully
/// route arms no rebootstrap: r1's second event, routable at r2, stays
/// parked in r2's tree behind the first, and a replay changes nothing.
module MuxBucketSkip_Minus_GapVerdict_test {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.* from "../configs/MuxBucketSkip.configs"
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, gapVerdict: false }
  ).* from "../specs/MuxBucketSkip"

  val parked = { org: "r1", seq: 2, bucket: "b1" }

  run withheldVerdictParksTheEventTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(bootstrap("r2", "r1"))
      .then(mint("r1", "b1"))
      .then(sync("r2", "r1"))
      .then(replay("r2"))
      .expect(and {
        safety,
        replicas.get("r2").stage == Serving,
        replicas.get("r2").tree.contains(parked),
        not(replicas.get("r2").applied.contains(parked)),
        replicas.get("r2").cursor == Set(),
      })
}

/// The design under the skew: each run above, with the mechanism back.
module MuxBucketSkip_Final_Skew_test {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.* from "../configs/MuxBucketSkip.configs"
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = Final
  ).* from "../specs/MuxBucketSkip"

  run skippedInstallAdoptsNothingTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(bootstrap("r2", "r1"))
      .expect(safety and replicas.get("r2").stage == Serving and replicas.get("r2").claim.get("r1") == 0)

  run partialDirectoryRefusesToServeTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(restart("r1"))
      .then(bootstrap("r2", "r1").fail())

  /// The unroutable first event is a hole: the fold holds the second and
  /// keeps the cursor, so both re-present.
  run unroutableSeqIsAHoleTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(mint("r1", "b1"))
      .then(bootstrap("r2", "r1"))
      .then(replay("r2"))
      .expect(safety and replicas.get("r2").claim.get("r1") == 0 and replicas.get("r2").cursor == Set())

  /// The verdict arms the rebootstrap, the only path that writes the parked
  /// event without the fold.
  run rebootstrapDeliversTheParkedEventTest =
    init
      .then(register("r1", "b2"))
      .then(mint("r1", "b2"))
      .then(bootstrap("r2", "r1"))
      .then(mint("r1", "b1"))
      .then(sync("r2", "r1"))
      .expect(replicas.get("r2").stage == GapPending)
      .then(bootstrap("r2", "r1"))
      .expect(safety and replicas.get("r2").applied.contains({ org: "r1", seq: 2, bucket: "b1" }))
}
