// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module CellContextReapConfigs {
  import CellContextReapTypes.* from "../specs/CellContextReap"

  /// The reap on, causal delivery, and the adapter's own cell directory.
  pure val Reaping = { reap: true, causalDelivery: true, directory: CellKeys }
}

/// The reap finds a cell only through the MST walk.
module CellContextReap_R2_DirTree {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 1, cfg = { ...Reaping, directory: MstWalk }
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    directoryComplete, deadContextReachable,
  }
}

/// `CellContextReap_R2_DirTree` without `directoryComplete`.
module CellContextReap_R2_DirTree_Dead {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 1, cfg = { ...Reaping, directory: MstWalk }
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    deadContextReachable,
  }
}

module CellContextReap_R2_ReapTRUE_CausalTRUE {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 2, cfg = Reaping
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    directoryComplete, deadContextReachable,
  }
}

/// Three replicas. `quint verify` has no symmetry reduction, so this
/// instance checks every permutation.
module CellContextReap_R3S1_ReapTRUE_CausalTRUE {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = Reaping
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    directoryComplete, deadContextReachable,
  }
}

/// Out-of-order delivery, three replicas, no symmetry reduction.
module CellContextReap_R3S1_ReapTRUE_CausalFALSE {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2", "r3"), MaxSeq = 1, cfg = { ...Reaping, causalDelivery: false }
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    directoryComplete, deadContextReachable,
  }
}

/// Two replicas with out-of-order delivery.
module CellContextReap_R2_Unordered {
  import CellContextReapTypes.* from "../specs/CellContextReap"
  import CellContextReapConfigs.*
  import CellContextReap(
    Replicas = Set("r1", "r2"), MaxSeq = 1, cfg = { ...Reaping, causalDelivery: false }
  ).* from "../specs/CellContextReap"
  val inv = and {
    noResurrection, convergence, noPhantomDot, contextCoversDots,
    directoryComplete, deadContextReachable,
  }
}
