// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module RibReadingConfigs {
  import RibReadingTypes.* from "../specs/RibReading"

  /// The shipped registry: an in-memory DB, every echo restated, reopens
  /// with a restore, sweeps that never rescan, a stub sweep only for
  /// departed nodes.
  pure val Registry = {
    assumeWallAhead: true,
    durable: false,
    reopen: true,
    selfHeal: true,
    heal: HealAlways,
    reap: true,
    sweepOnce: true,
    stubFollowsCell: false,
  }
}

/// A reboot may step the wall clock back, but not past a stamp a replica
/// holds.
module RibReading_WallAhead {
  import RibReadingTypes.* from "../specs/RibReading"
  import RibReadingConfigs.*
  import RibReading(
    Peers = Set("p1"), MaxOps = 2, MaxResets = 2, MaxStamp = 6, K = 2, MaxWall = 3,
    StepBack = 2, cfg = Registry
  ).* from "../specs/RibReading"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

/// A reboot may step the wall clock back past a stamp a replica holds.
module RibReading_WallStepBack {
  import RibReadingTypes.* from "../specs/RibReading"
  import RibReadingConfigs.*
  import RibReading(
    Peers = Set("p1"), MaxOps = 2, MaxResets = 2, MaxStamp = 6, K = 2, MaxWall = 3,
    StepBack = 2, cfg = { ...Registry, assumeWallAhead: false }
  ).* from "../specs/RibReading"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}
