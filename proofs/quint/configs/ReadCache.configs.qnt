// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module ReadCacheConfigs {
  /// The shipped protocol: a generation ticket and a re-check after the fill;
  /// an invalidation advances the generation, then deletes.
  pure val Shipped = { useTicket: true, bumpFirst: true, deleteOwnObject: true }
}

/// The shipped protocol.
module ReadCache_Ship {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2", "r3"), Writers = Set("w1", "w2"), MaxW = 4,
    cfg = Shipped
  ).* from "../specs/ReadCache"
  val inv = settledCoherent and noDeadlock
}

/// Readers fill without a ticket or re-check.
module ReadCache_Head {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2", "r3"), Writers = Set("w1", "w2"), MaxW = 4,
    cfg = { ...Shipped, useTicket: false }
  ).* from "../specs/ReadCache"
  val inv = settledCoherent and noDeadlock
}

/// The shipped reader, but an invalidation deletes before it advances the
/// generation.
module ReadCache_Swap {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2", "r3"), Writers = Set("w1", "w2"), MaxW = 4,
    cfg = { ...Shipped, bumpFirst: false }
  ).* from "../specs/ReadCache"
  val inv = settledCoherent and noDeadlock
}

/// The shipped protocol, against read-after-write.
module ReadCache_RAW {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2", "r3"), Writers = Set("w1", "w2"), MaxW = 4,
    cfg = Shipped
  ).* from "../specs/ReadCache"
  val inv = writersIdleCoherent and noDeadlock
}

/// Two readers and one writer.
module ReadCache_SmallShip {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2"), Writers = Set("w1"), MaxW = 2, cfg = Shipped
  ).* from "../specs/ReadCache"
  val inv = settledCoherent and noDeadlock
}

module ReadCache_SmallSwap {
  import ReadCacheConfigs.*
  import ReadCache(
    Readers = Set("r1", "r2"), Writers = Set("w1"), MaxW = 2,
    cfg = { ...Shipped, bumpFirst: false, deleteOwnObject: false }
  ).* from "../specs/ReadCache"
  val inv = settledCoherent and noDeadlock
}
