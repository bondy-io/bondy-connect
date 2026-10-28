// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A replay holds `(2,2)` behind the gap at `(2,1)`; compaction truncates
/// `(1,1)`, and the advance moves the cursor over `(2,2)`, so no later
/// replay presents it.
module ReplayReanchor_Shipped_NoRestart_test {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 0,
    cfg = { reanchor: Always, gated: false }
  ).* from "../specs/ReplayReanchor"

  run heldEventUnderTheCursorTest =
    init
      .then(mint)
      .then(deliver({ org: 2, seq: 2 }))
      .then(replay)
      .expect(holding)
      .then(compact(Set({ org: 1, seq: 1 })))
      .then(advance)
      .expect(not(presentable))
}

/// A restart over an unclaimed tree leaves the cursor unanchored, which
/// owes a full fold; the advance re-anchors before the gate opens, so the
/// fold never happens.
module ReplayReanchor_Shipped_Gated_test {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.* from "../configs/ReplayReanchor.configs"
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = { ...GuardedGated, reanchor: Always }
  ).* from "../specs/ReplayReanchor"

  run owedFullFoldCancelledTest =
    init
      .then(mint)
      .then(deliver({ org: 2, seq: 2 }))
      .then(restart)
      .expect(cursor == Unanchored)
      .then(compact(Set({ org: 1, seq: 1 })))
      .then(advance)
      .then(openGate)
      .then(replay)
      .expect(not(presentable))
}

/// The same two runs under the guarded rule: the cursor stays where the
/// next replay presents the held event, and it is folded once `(2,1)`
/// arrives.
module ReplayReanchor_Guarded_Gated_test {
  import ReplayReanchorTypes.* from "../specs/ReplayReanchor"
  import ReplayReanchorConfigs.* from "../configs/ReplayReanchor.configs"
  import ReplayReanchor(
    Local = 1, Remotes = Set(2), MaxSeq = 3, MaxCompact = 2, MaxRestart = 1,
    cfg = GuardedGated
  ).* from "../specs/ReplayReanchor"

  run heldEventStaysPresentableTest =
    init
      .then(mint)
      .then(deliver({ org: 2, seq: 2 }))
      .then(replay)
      .then(compact(Set({ org: 1, seq: 1 })))
      .then(advance)
      .expect(presentable and cursor == Unanchored)
      .then(deliver({ org: 2, seq: 1 }))
      .then(replay)
      .expect(applied.contains({ org: 2, seq: 2 }))

  run owedFullFoldKeptTest =
    init
      .then(mint)
      .then(deliver({ org: 2, seq: 2 }))
      .then(restart)
      .then(compact(Set({ org: 1, seq: 1 })))
      .then(advance)
      .expect(cursor == Unanchored)
      .then(openGate)
      .then(replay)
      .expect(presentable)
}
