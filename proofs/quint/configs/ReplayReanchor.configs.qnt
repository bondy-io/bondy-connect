// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module ReplayReanchorConfigs {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"

  /// The guarded re-anchor with a drain-gated boot replay.
  pure val GuardedGated = { reanchor: Guarded, gated: true }
}

/// The cursor moves to the new root on every compaction; no restart.
module ReplayReanchor_Shipped_NoRestart {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 0,
    cfg = { reanchor: Always, gated: false }
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}

module ReplayReanchor_Shipped_Gated {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = { ...GuardedGated, reanchor: Always }
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}

module ReplayReanchor_Guarded_Open {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = { ...GuardedGated, gated: false }
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}

module ReplayReanchor_Guarded_Gated {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = GuardedGated
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}

/// `Guarded_Gated` with the anchor half of the guard removed.
module ReplayReanchor_Guarded_Gated_NoAnchor {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = { ...GuardedGated, reanchor: HeldOnly }
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}

/// Two remote origins; safety only.
module ReplayReanchor_Guarded_Gated_2R_Safety {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.*
  import ReplayReanchor(
    Local = 1, Remotes = Set(2, 3), MaxSeq = 2, MaxCompact = 2, MaxRestart = 1,
    cfg = GuardedGated
  ).* from "../specs/ReplayReanchor"
  val inv = presentable
}
