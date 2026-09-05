import test from "node:test";
import assert from "node:assert/strict";
import { arithmeticMeanTick } from "./oracle-tools.mjs";

test("calculates a time-weighted tick", () => {
  const observations = [
    { timestamp: 90, tick: 100, blockNumber: 1, logIndex: 0 },
    { timestamp: 120, tick: 200, blockNumber: 2, logIndex: 0 },
  ];
  assert.equal(arithmeticMeanTick(observations, 100, 200), 180);
});

test("uses the last event in a block for the following interval", () => {
  const observations = [
    { timestamp: 90, tick: 100, blockNumber: 1, logIndex: 0 },
    { timestamp: 120, tick: 200, blockNumber: 2, logIndex: 0 },
    { timestamp: 120, tick: 300, blockNumber: 2, logIndex: 1 },
  ];
  assert.equal(arithmeticMeanTick(observations, 100, 200), 260);
});

test("rounds negative means toward negative infinity", () => {
  const observations = [
    { timestamp: 0, tick: -2, blockNumber: 1, logIndex: 0 },
    { timestamp: 1, tick: -1, blockNumber: 2, logIndex: 0 },
  ];
  assert.equal(arithmeticMeanTick(observations, 0, 3), -2);
});

test("requires a known tick at the window start", () => {
  assert.throws(
    () => arithmeticMeanTick([{ timestamp: 101, tick: 1, blockNumber: 1, logIndex: 0 }], 100, 200),
    /No pool tick is known/,
  );
});
