// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module MuxBucketSkipConfigs {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"

  /// All five mechanisms that close the two channels, and the initiator
  /// gate.
  pure val Final = {
    skipIsHole: true,
    claim: ContigOfApplied,
    adoption: IfNothingSkipped,
    serveGate: true,
    gateOnRegistration: true,
    gapVerdict: true,
  }

  /// Every replica's build declares both buckets: an unroutable bucket is a
  /// transient registration window.
  pure val Uniform = Map("r1" -> Set("b1", "b2"), "r2" -> Set("b1", "b2"))

  /// r2 runs a build with no table for b2, so b2 is never routable there.
  pure val Skewed = Map("r1" -> Set("b1", "b2"), "r2" -> Set("b1"))
}

/// Three replicas, one event per origin: at `MaxSeq = 2` TLC passes 64M
/// distinct states without closing.
module MuxBucketSkip_Final_3r {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, Founding = "b1", Seed = "r1",
    Declared = Skewed.put("r3", Set("b1", "b2")), cfg = Final
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

module MuxBucketSkip_Final_NoSkew {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Uniform, cfg = Final
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

module MuxBucketSkip_Final_Skew {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = Final
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

/// The bootstrap adopts the peer's frontier unconditionally: the rule
/// `finalize_catalogue_bootstrap/5` was shipped with.
module MuxBucketSkip_Minus_AdoptIfComplete {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, adoption: Unconditional }
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

/// The frontier-gap verdict is withheld for a deficit this replica cannot
/// close, so no rebootstrap is triggered.
module MuxBucketSkip_Minus_GapVerdict {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, gapVerdict: false }
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

/// The initiator syncs, folds and installs before its own tables have
/// registered.
module MuxBucketSkip_Minus_GateOnRegistration {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, gateOnRegistration: false }
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

/// The responder serves a catalogue before its own tables have registered.
module MuxBucketSkip_Minus_ServeGate {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, serveGate: false }
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}

/// The fold with neither the hole nor the contiguous claim.
module MuxBucketSkip_Minus_SkipHole_Contig {
  import MuxBucketSkipTypes.* from "../specs/MuxBucketSkip"
  import MuxBucketSkipConfigs.*
  import MuxBucketSkip(
    Replicas = Set("r1", "r2"), MaxSeq = 2, Founding = "b1", Seed = "r1",
    Declared = Skewed, cfg = { ...Final, skipIsHole: false, claim: BatchMax }
  ).* from "../specs/MuxBucketSkip"
  val inv = safety
}
