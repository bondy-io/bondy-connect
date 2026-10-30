// THIS WAS BUILT BY CLAUDE OPUS and it is not verified.

/// The second reboot leaves the wall clock at 2, so the owner's next
/// reading (origin 3, count 0) takes stamp 4, the stamp of the reading the
/// peer holds (origin 2, count 1). The tie goes to the higher count, the
/// peer's stub keeps 1, and once the peer reaps origin 2 no merge refreshes
/// it.
module RibReading_WallStepBack_test {
  import RibReadingTypes.* from "../specs/RibReading"
  import RibReadingConfigs.* from "../configs/RibReading.configs"
  import RibReading(
    Peers = Set("p1"), MaxOps = 2, MaxResets = 2, MaxStamp = 6, K = 2, MaxWall = 3,
    StepBack = 2, cfg = { ...Registry, assumeWallAhead: false }
  ).* from "../specs/RibReading"

  pure val held = { org: 2, seq: 1, stamp: 4, count: 1 }
  pure val restated = { org: 3, seq: 1, stamp: 4, count: 0 }

  run stubStuckOnATiedStampTest =
    init
      .then(rowOp(1, 1))
      .then(reboot(2))
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(readAndWrite(1))
      .then(deliver("p1", "owner", held))
      .then(reboot(2))
      .then(deliver("owner", "p1", held))
      .then(reap("owner", 2))
      .then(selfHealWrite(1))
      .then(stamp(1))
      .then(readAndWrite(1))
      .then(deliver("p1", "owner", restated))
      .expect(stub.get("p1") == 1)
      .then(reap("p1", 2))
      .then(tick)
      // `settled` reads `enabled`, which only TLC evaluates
      .expect(and {
        owner.live == 0,
        value(replicas.get("p1").cell) == 0,
        stub.get("p1") == 1,
      })
}

/// With the wall clock past every held stamp, the second reboot cannot
/// land on wall 2.
module RibReading_WallAhead_test {
  import RibReadingTypes.* from "../specs/RibReading"
  import RibReadingConfigs.* from "../configs/RibReading.configs"
  import RibReading(
    Peers = Set("p1"), MaxOps = 2, MaxResets = 2, MaxStamp = 6, K = 2, MaxWall = 3,
    StepBack = 2, cfg = Registry
  ).* from "../specs/RibReading"

  pure val held = { org: 2, seq: 1, stamp: 4, count: 1 }

  action prefix =
    init
      .then(rowOp(1, 1))
      .then(reboot(2))
      .then(rowOp(1, 1))
      .then(stamp(1))
      .then(readAndWrite(1))
      .then(deliver("p1", "owner", held))

  run noStepBackOntoAHeldStampTest = prefix.then(reboot(2)).fail()

  run rebootPastTheHeldStampTest = prefix.then(reboot(3)).expect(owner.wall * K > 4)
}
