import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Contract } from "ethers";
import {
  arithmeticMeanTick, blockAtOrBefore, loadEnvironment, readDeployment,
  readPoolObservations, requireValue,
} from "./oracle-tools.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const values = loadEnvironment(path.join(packageDirectory, ".env"));
const windowSeconds = Number(values.ORACLE_TWAP_WINDOW_SECONDS || 1800);
const confirmations = Number(values.ORACLE_CONFIRMATIONS || 12);
const historyBlocks = Number(values.ORACLE_HISTORY_BLOCKS || 20000);
const validitySeconds = Number(requireValue(values, "MAX_REPORT_VALIDITY_SECONDS"));
if (![windowSeconds, confirmations, historyBlocks, validitySeconds].every(Number.isSafeInteger)) {
  throw new Error("Oracle timing settings must be integers.");
}

const { provider, poolId, manager, oracle } = await readDeployment(values);
try {
  const latest = await provider.getBlockNumber();
  if (latest <= confirmations) throw new Error("Chain does not have enough confirmed blocks.");
  const endBlockNumber = latest - confirmations;
  const endBlock = await provider.getBlock(endBlockNumber);
  if (!endBlock) throw new Error("Confirmed end block is unavailable.");
  const startTimestamp = endBlock.timestamp - windowSeconds;
  const startBlock = await blockAtOrBefore(provider, startTimestamp, endBlockNumber);
  const fromBlock = Math.max(0, startBlock - historyBlocks);
  const observations = await readPoolObservations(provider, manager, poolId, fromBlock, endBlockNumber);
  const tick = arithmeticMeanTick(observations, startTimestamp, endBlock.timestamp);

  const oracleContract = new Contract(oracle, ["function latestSequence(bytes32) view returns (uint64)"], provider);
  const sequence = Number(await oracleContract.latestSequence(poolId)) + 1;
  if (!Number.isSafeInteger(sequence)) throw new Error("Oracle sequence exceeds safe JSON integer range.");
  const report = {
    chainId: 4663,
    oracle,
    poolId,
    tick,
    observedAt: endBlock.timestamp,
    validUntil: endBlock.timestamp + validitySeconds,
    sequence,
    evidence: {
      method: "time-weighted arithmetic mean tick",
      startTimestamp,
      endTimestamp: endBlock.timestamp,
      endBlock: endBlockNumber,
      endBlockHash: endBlock.hash,
      confirmations,
      windowSeconds,
      events: observations.filter((item) => item.timestamp >= startTimestamp).length,
      historyFromBlock: fromBlock,
    },
  };
  const runtimeDirectory = path.join(packageDirectory, "runtime");
  fs.mkdirSync(runtimeDirectory, { recursive: true });
  const output = path.join(runtimeDirectory, "oracle-report.json");
  fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`Prepared report for sequence ${sequence} from ${windowSeconds} seconds of confirmed pool history.`);
  console.log(`Unsigned report: ${output}`);
} finally {
  provider.destroy();
}
