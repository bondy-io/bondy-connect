// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module AaeCausalClosureConfigs {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"

  /// The prefix hold, the contiguous claim, the gap check, and compaction
  /// that does not wait for every replica (`mst_retention`,
  /// `truncate_prefix`).
  pure val Held = {
    gapCheck: true,
    gatedCompaction: false,
    prefixHold: true,
    claimRule: ContigOfApplied,
  }

  /// `Held` without the prefix hold and with the adopted max claim.
  pure val Unheld = { ...Held, prefixHold: false, claimRule: AdoptedMax }
}

/// Two replicas: sync, the hold and the frontier logic are pairwise.
module AaeCausalClosure_Shipped {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.*
  import AaeCausalClosure(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Seed = "r1", cfg = Held
  ).* from "../specs/AaeCausalClosure"
  val inv = noOverClaim and prefixClosed and noDeadlock
}

module AaeCausalClosure_Shipped_3R {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.*
  import AaeCausalClosure(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 2, Seed = "r1", cfg = Held
  ).* from "../specs/AaeCausalClosure"
  val inv = noOverClaim and prefixClosed and noDeadlock
}

/// The ablation of `AaeCausalClosure_Shipped`, with three replicas.
module AaeCausalClosure_Unheld {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.*
  import AaeCausalClosure(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 2, Seed = "r1", cfg = Unheld
  ).* from "../specs/AaeCausalClosure"
  val inv = noOverClaim and prefixClosed and noDeadlock
}

/// `AaeCausalClosure_Unheld` with two replicas.
module AaeCausalClosure_Unheld_2R {
  import AaeCausalClosureTypes.* from "../specs/AaeCausalClosure"
  import AaeCausalClosureConfigs.*
  import AaeCausalClosure(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Seed = "r1", cfg = Unheld
  ).* from "../specs/AaeCausalClosure"
  val inv = noOverClaim and prefixClosed and noDeadlock
}
