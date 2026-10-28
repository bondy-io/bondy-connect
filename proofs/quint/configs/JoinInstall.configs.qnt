// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

module JoinInstallConfigs {
  import JoinInstallTypes.* from "../specs/JoinInstall"

  /// The code: every guard of the install and of the truncation, no local
  /// fold before the boot replay, staged installs, compaction confirmed by
  /// every other member, and the sweep's point at the first unconfirmed
  /// key.
  pure val Code = {
    install: Stage,
    refoldFirst: true,
    compactBy: Members,
    retiredExempt: false,
    bound: FirstUnconfirmed,
    reap: false,
    join: Clustered,
    mark: true,
    serve: true,
    replayed: true,
    target: true,
    busy: true,
    early: true,
    token: true,
    trunc: true,
    coverBegin: true,
    floor: true,
    leave: false,
    kept: false,
  }

  /// The install alone: no compaction, and none of its guards.
  pure val InstallOnly = { ...Code, compactBy: NoCompaction, trunc: false, coverBegin: false, floor: false }
}
