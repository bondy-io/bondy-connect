// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// A reboot spends the first reset; a registration takes its stamp, and a
/// restart spends the second and kills the writer before it writes.
/// Nothing restates the count.
module RibAbs_RestartNoRestore_test {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.* from "../configs/RibAbs.configs"
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 4,
    cfg = { ...Shipped, restart: RestartWith({ restore: false, reopens: false }) }
  ).* from "../specs/RibAbs"

  run countNeverRestatedTest =
    init
      .then(rowOp(1, 1))
      .then(reboot(owner.clock + 1))
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(restart(survivors(owner.writers, Set())))
      // `settled` reads `enabled`, which only TLC evaluates
      .expect(and {
        owner.live == 1,
        owner.writers == Writers.mapBy(_ => Idle),
        not(owner.due),
        Replicas.forall(r => value(replicas.get(r).cell) == 0),
      })
}

/// The same run under the shipped policy: the restart makes a reopen due,
/// and its restore writer restates the count.
module RibAbs_Shipped_test {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.* from "../configs/RibAbs.configs"
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 4, cfg = Shipped
  ).* from "../specs/RibAbs"

  run restartReopensTest =
    init
      .then(rowOp(1, 1))
      .then(reboot(owner.clock + 1))
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(restart(survivors(owner.writers, Set())))
      .expect(owner.due and owner.resets == MaxResets)
      .then(reopen(1))
      .then(stamp(1))
      .then(readAndWrite(1))
      .expect(value(replicas.get(Owner).cell) == owner.live)

  /// A writer that already holds its stamp and is kept survives the
  /// restart, and writes under the new origin.
  run keptWriterWritesUnderTheNewOriginTest =
    init
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(restart(survivors(owner.writers, Set(1))))
      .then(readAndWrite(1))
      .expect(replicas.get(Owner).cell.map(e => e.org) == Set(2))
}

/// The peers hold a reading of count 2 from origin 1; two reboots end
/// every session. Each replica reaps origin 1, the owner's echo leaves its
/// cell empty, which is not a foreign top, so no reading follows and the
/// stubs keep 2.
module RibAbs_HealOnForeignTop_test {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.* from "../configs/RibAbs.configs"
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 5,
    cfg = {
      ...Shipped,
      restart: NoRestart,
      heal: HealWhenWrong({ onAbsent: false, onForeignTop: true }),
    }
  ).* from "../specs/RibAbs"

  pure val e = { org: 1, seq: 1, stamp: 1, count: 2 }

  run stubsKeepAReapedCountTest =
    init
      .then(rowOp(1, 1))
      .then(rowOp(1, 2))
      .then(stamp(1))
      .then(readAndWrite(1))
      .then(deliver("p1", Owner, e))
      .then(reboot(owner.clock + 1))
      .then(reboot(owner.clock + 1))
      .then(deliver("p2", "p1", e))
      .then(deliver(Owner, "p1", e))
      .then(reap("p1", 1))
      .then(reap("p2", 1))
      .then(reap(Owner, 1))
      .then(selfHealQuiet)
      .expect(and {
        owner.live == 0,
        Replicas.forall(r => value(replicas.get(r).cell) == 0),
        Peers.forall(p => stub.get(p) == 2),
      })
}

/// A reopen's restore writer and an older writer race: the reading of
/// count 1 takes the higher stamp, and the later count-0 reading the lower.
/// The peers' stubs take 1. After a reboot every replica reaps origin 2;
/// the count-0 reading then reaches the owner's cell again, which agrees
/// with `live`, so no reading follows and the stubs keep 1.
module RibAbs_HealOnAbsent_test {
  import RibAbsTypes.* from "../specs/RibAbs"
  import RibAbsConfigs.* from "../configs/RibAbs.configs"
  import RibAbs(
    Peers = Set("p1", "p2"), MaxOps = 2, MaxResets = 2, MaxStamp = 5,
    cfg = {
      ...Shipped,
      restart: NoRestart,
      heal: HealWhenWrong({ onAbsent: true, onForeignTop: false }),
    }
  ).* from "../specs/RibAbs"

  pure val one = { org: 2, seq: 1, stamp: 2, count: 1 }
  pure val zero = { org: 2, seq: 2, stamp: 1, count: 0 }

  run stubsKeepAnOutrankedCountTest =
    init
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(reopen(2))
      .then(stamp(2))
      .then(readAndWrite(2))
      .then(rowOp(-1, 2))
      .then(readAndWrite(1))
      .then(deliver("p1", Owner, one))
      .then(deliver("p1", Owner, zero))
      .then(reboot(owner.clock + 1))
      .then(deliver("p2", "p1", one))
      .then(deliver("p2", "p1", zero))
      .then(deliver(Owner, "p1", one))
      .then(reap("p1", 2))
      .then(reap("p2", 2))
      .then(reap(Owner, 2))
      .then(deliver(Owner, "p1", zero))
      .then(selfHealQuiet)
      .expect(and {
        owner.live == 0,
        Replicas.forall(r => value(replicas.get(r).cell) == 0),
        Peers.forall(p => stub.get(p) == 1),
      })
}
