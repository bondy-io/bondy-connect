// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module IndexIntentsConfigs {
  import IndexIntentsTypes.* from "../specs/IndexIntents"

  /// The code's mechanism.
  pure val Code = {
    intents: true,
    intentInBatch: true,
    syncBeforeClear: true,
    clearBound: ByDispatched,
    orderByVersion: true,
    versionPerEvent: true,
    installMode: Synced,
    versionSource: Recorded,
    stampBeforeReplay: true,
    replaySyncs: true,
    markNeedsFlush: true,
    keepRequests: true,
    crashKeeps: Prefix,
    indexCrashKeeps: Prefix,
    rebuildAtOpen: false,
    openDispatched: AtCleared,
    syncBeforeMark: true,
    syncBeforeWipe: true,
    clearMarked: false,
    openFlushes: true,
    freshenNeedsFlush: true,
    unmarkMayFail: false,
    rebuildUnmarks: true,
    syncBeforeInstall: true,
    rebuildWipes: true,
    rebuildRefolds: true,
  }

  /// The same mechanism with the barrier clearing up to the version the
  /// index records.
  pure val Source = {
    ...Code,
    clearBound: BySource,
  }

  /// No intents: a full rebuild at every unclean open and writer
  /// restart.
  pure val NoIntents = {
    ...Code,
    intents: false,
    clearBound: BySource,
    orderByVersion: false,
    installMode: NoIndexOps,
    markNeedsFlush: false,
    keepRequests: false,
    rebuildAtOpen: true,
    syncBeforeMark: false,
    syncBeforeWipe: false,
  }
}
