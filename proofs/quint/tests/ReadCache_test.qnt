// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Without the ticket, a reader that read the projection before a write
/// fills the stale value after the writer's invalidation, and the cache stays
/// stale once every process is idle.
module ReadCache_Head_test {
  import ReadCacheConfigs.* from "../configs/ReadCache.configs"
  import ReadCache(
    Readers = Set("r1"), Writers = Set("w1"), MaxW = 1,
    cfg = { ...Shipped, useTicket: false }
  ).* from "../specs/ReadCache"

  run staleFillOutlivesInvalidationTest =
    init
      .then(reader("r1"))
      .then(reader("r1"))
      .then(writer("w1"))
      .then(writer("w1"))
      .then(writer("w1"))
      .then(reader("r1"))
      .expect(not(settledCoherent))
}

/// The shipped protocol: the same race serves a stale hit while the filling
/// reader has yet to re-check, which `writersIdleCoherent` reports, and the
/// re-check removes it.
module ReadCache_Ship_test {
  import ReadCacheConfigs.* from "../configs/ReadCache.configs"
  import ReadCache(
    Readers = Set("r1"), Writers = Set("w1"), MaxW = 1, cfg = Shipped
  ).* from "../specs/ReadCache"

  run recheckRemovesStaleFillTest =
    init
      .then(reader("r1"))
      .then(reader("r1"))
      .then(writer("w1"))
      .then(writer("w1"))
      .then(writer("w1"))
      .then(reader("r1"))
      .expect(not(writersIdleCoherent))
      .then(reader("r1"))
      .expect(shard.cache == None and settledCoherent)
}
