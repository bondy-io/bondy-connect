// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// Compaction truncates the only acknowledged seq out of the tree; a
/// restart seeded from the tree re-mints it.
module SeqSeed_Shipped_test {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.* from "../configs/SeqSeed.configs"
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, seedRule: LiveTree }).* from "../specs/SeqSeed"

  run truncatedSeqIsRemintedTest =
    init
      .then(reserve)
      .then(walAppend)
      .then(apply)
      .then(truncateFlush(1))
      .then(truncateCheckpoint)
      .then(stop)
      .then(restart)
      .expect(not(seedExact))
}

/// The same run, with the checkpoint frontier and the WAL seeding the
/// counter: the restart resumes past the truncated seq.
module SeqSeed_CkptWal_test {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.* from "../configs/SeqSeed.configs"
  import SeqSeed(
    MaxSeq = 3,
    cfg = { ...CkptSeed, seedRule: CkptFrontierAndWal, mintAfterReplay: false }
  ).* from "../specs/SeqSeed"

  run truncatedSeqIsNotRemintedTest =
    init
      .then(reserve)
      .then(walAppend)
      .then(apply)
      .then(truncateFlush(1))
      .then(truncateCheckpoint)
      .then(stop)
      .then(restart)
      .expect(seedExact)
      .then(reserve)
      .expect(dotUnique and seedExact)
}

/// A crash between the truncated root's flush and its checkpoint, after
/// retention dropped the seq from the WAL, leaves it in no durable source.
module SeqSeed_CkptCommitKeyedRetention_test {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.* from "../configs/SeqSeed.configs"
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, retention: HeldByDurableRoot }).* from "../specs/SeqSeed"

  run seqInNoDurableSourceTest =
    init
      .then(reserve)
      .then(walAppend)
      .then(apply)
      .then(flushRoot)
      .then(dropWal)
      .then(truncateFlush(1))
      .then(crash)
      .then(restart)
      .expect(not(seedExact))
}

/// A mint before the replay sees a counter behind the WAL.
module SeqSeed_CkptEarlyMint_test {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.* from "../configs/SeqSeed.configs"
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, mintAfterReplay: false }).* from "../specs/SeqSeed"

  run mintBeforeReplayTest =
    init
      .then(reserve)
      .then(walAppend)
      .then(stop)
      .then(restart)
      .expect(not(seedExact))
}
