// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module RibAbsConfigs {
  import RibAbsTypes.* from "../specs/RibAbs"

  /// The shipped registry: an in-memory DB, every echo restated, reopens
  /// with a restore, an instance restart that reopens the DB, sweeps that
  /// never rescan, a stub sweep only for departed nodes.
  pure val Shipped = {
    durable: false,
    reopen: true,
    restart: RestartWith({ restore: false, reopens: true }),
    clockRegress: false,
    selfHeal: true,
    heal: HealAlways,
    reap: true,
    sweepOnce: true,
    stubFollowsCell: false,
  }
}

module RibAbs_Shipped {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 4, cfg = Shipped
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

module RibAbs_Shipped_Stamp5_OnePeer {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1"), MaxOps = 2, MaxResets = 2, MaxStamp = 5, cfg = Shipped
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

module RibAbs_NoRestart_Stamp5 {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 5,
    cfg = { ...Shipped, restart: NoRestart }
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

/// A restart that neither reopens the DB nor restores the reading.
module RibAbs_RestartNoRestore {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 4,
    cfg = { ...Shipped, restart: RestartWith({ restore: false, reopens: false }) }
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

/// The owner restates only when its cell is wrong or empty.
module RibAbs_HealOnAbsent {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 5,
    cfg = {
      ...Shipped,
      restart: NoRestart,
      heal: HealWhenWrong({ onAbsent: true, onForeignTop: false }),
    }
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}

/// The owner restates only when its cell is wrong or its top reading is
/// another origin's.
module RibAbs_HealOnForeignTop {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.*
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 5,
    cfg = {
      ...Shipped,
      restart: NoRestart,
      heal: HealWhenWrong({ onAbsent: false, onForeignTop: true }),
    }
  ).* from "../specs/RibAbs"
  val inv = cellWithinFrontier and settledCellIsTruth and settledStubIsTruth
}
