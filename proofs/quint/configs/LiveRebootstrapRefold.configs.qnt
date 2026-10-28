// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module LiveRebootstrapRefoldConfigs {
  import LiveRebootstrapRefoldTypes.* from "../specs/LiveRebootstrapRefold"

  /// The proposed order: an unconditional install, the durable mark, a
  /// re-fold that resets the frontier before finalize, the serve guard, and
  /// a failed install write that fails the batch.
  pure val Proposed = {
    install: ReplaceAlways,
    refold: BeforeFinalize,
    durableMark: true,
    serveGuard: true,
    sessionExpiry: true,
    resetFrontier: true,
    writeFail: FailsBatch,
  }
}
