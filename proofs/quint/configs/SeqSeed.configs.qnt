// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module SeqSeedConfigs {
  import SeqSeedTypes.* from "../specs/SeqSeed"

  /// The restored-frontier seed under watermark-keyed retention, with no
  /// mint before the WAL replay.
  pure val CkptSeed = {
    seedRule: CkptFrontier,
    retention: BelowCheckpointWatermark,
    frontierBeforeTruncate: false,
    mintAfterReplay: true,
  }
}

/// The counter seeded from the live tree alone; the replay tops it up.
module SeqSeed_Shipped {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.*
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, seedRule: LiveTree }).* from "../specs/SeqSeed"
  val inv = durableSound and seedExact and dotUnique and noDeadlock
}

/// Retention drops whatever the durable root holds.
module SeqSeed_CkptCommitKeyedRetention {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.*
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, retention: HeldByDurableRoot }).* from "../specs/SeqSeed"
  val inv = durableSound and seedExact and dotUnique and noDeadlock
}

/// A mint may run before the WAL replay has finished.
module SeqSeed_CkptEarlyMint {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.*
  import SeqSeed(MaxSeq = 3, cfg = { ...CkptSeed, mintAfterReplay: false }).* from "../specs/SeqSeed"
  val inv = durableSound and seedExact and dotUnique and noDeadlock
}

/// The WAL is a third seed source, read at restart; a mint may run before
/// the replay.
module SeqSeed_CkptWal {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.*
  import SeqSeed(
    MaxSeq = 3,
    cfg = { ...CkptSeed, seedRule: CkptFrontierAndWal, mintAfterReplay: false }
  ).* from "../specs/SeqSeed"
  val inv = durableSound and seedExact and dotUnique and noDeadlock
}

/// `SeqSeed_CkptWal` with five seqs.
module SeqSeed_CkptWal_MaxSeq5 {
  import SeqSeedTypes.* from "../specs/SeqSeed"
  import SeqSeedConfigs.*
  import SeqSeed(
    MaxSeq = 5,
    cfg = { ...CkptSeed, seedRule: CkptFrontierAndWal, mintAfterReplay: false }
  ).* from "../specs/SeqSeed"
  val inv = durableSound and seedExact and dotUnique and noDeadlock
}
