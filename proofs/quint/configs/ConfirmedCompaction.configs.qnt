// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module ConfirmedCompactionConfigs {
  import ConfirmedCompactionTypes.* from "../specs/ConfirmedCompaction"

  /// The code on a fused instance.
  pure val Code = {
    backend: Fused,
    witnesses: EveryMember,
    door: DropsConfirmed,
    capAtUnapplied: true,
    walkLost: false,
    heal: WhenMembersCover,
    healCap: true,
  }

  /// The code on an applier-backed instance.
  pure val Async = { ...Code, backend: Applier }

  /// The code on a fused instance whose rounds may hold what they merged.
  pure val Holding = { ...Code, backend: FusedHolding }
}
