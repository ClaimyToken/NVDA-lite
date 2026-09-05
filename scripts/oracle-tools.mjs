import fs from "node:fs";
import { Contract, Interface, JsonRpcProvider } from "ethers";

export const ORACLE_DOMAIN = { name: "NVDA Signed Reference Oracle", version: "1" };
export const REPORT_TYPES = {
  TickReport: [
    { name: "poolId", type: "bytes32" },
    { name: "tick", type: "int24" },
    { name: "observedAt", type: "uint64" },
    { name: "validUntil", type: "uint64" },
    { name: "sequence", type: "uint64" },
  ],
};

const POOL_MANAGER_EVENTS = new Interface([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event Swap(bytes32 indexed id,address indexed sender,int128 amount0,int128 amount1,uint160 sqrtPriceX96,uint128 liquidity,int24 tick,uint24 fee)",
]);

export function loadEnvironment(filePath) {
  const values = {};
  for (const line of fs.readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const separator = trimmed.indexOf("=");
    if (separator === -1) continue;
    values[trimmed.slice(0, separator)] = trimmed.slice(separator + 1).trim();
  }
  return values;
}

export function requireValue(values, name) {
  const value = values[name];
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

export function arithmeticMeanTick(observations, startTimestamp, endTimestamp) {
  if (!Number.isInteger(startTimestamp) || !Number.isInteger(endTimestamp) || endTimestamp <= startTimestamp) {
    throw new Error("Invalid averaging window.");
  }
  const ordered = [...observations].sort(
    (a, b) => a.timestamp - b.timestamp || a.blockNumber - b.blockNumber || a.logIndex - b.logIndex,
  );
  let active = null;
  let cursor = startTimestamp;
  let weighted = 0n;
  for (const observation of ordered) {
    if (observation.timestamp <= startTimestamp) {
      active = observation.tick;
      continue;
    }
    if (observation.timestamp > endTimestamp) break;
    if (active === null) throw new Error("No pool tick is known at the start of the averaging window.");
    weighted += BigInt(active) * BigInt(observation.timestamp - cursor);
    cursor = observation.timestamp;
    active = observation.tick;
  }
  if (active === null) throw new Error("No pool tick is known at the start of the averaging window.");
  weighted += BigInt(active) * BigInt(endTimestamp - cursor);
  const duration = BigInt(endTimestamp - startTimestamp);
  let mean = weighted / duration;
  if (weighted < 0n && weighted % duration !== 0n) mean -= 1n;
  const result = Number(mean);
  if (result < -887272 || result > 887272) throw new Error("Calculated tick is outside Uniswap bounds.");
  return result;
}

export async function blockAtOrBefore(provider, timestamp, highBlock) {
  let low = 0;
  let high = highBlock;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    const block = await provider.getBlock(middle);
    if (!block) throw new Error(`Block ${middle} is unavailable.`);
    if (block.timestamp <= timestamp) low = middle;
    else high = middle - 1;
  }
  return low;
}

export async function readPoolObservations(provider, manager, poolId, fromBlock, toBlock, chunkSize = 2_000) {
  const initializeTopic = POOL_MANAGER_EVENTS.getEvent("Initialize").topicHash;
  const swapTopic = POOL_MANAGER_EVENTS.getEvent("Swap").topicHash;
  const logs = [];
  for (let start = fromBlock; start <= toBlock; start += chunkSize) {
    const end = Math.min(toBlock, start + chunkSize - 1);
    logs.push(...await provider.getLogs({
      address: manager,
      fromBlock: start,
      toBlock: end,
      topics: [[initializeTopic, swapTopic], poolId],
    }));
  }
  const timestamps = new Map();
  const observations = [];
  for (const log of logs) {
    let timestamp = timestamps.get(log.blockNumber);
    if (timestamp === undefined) {
      const block = await provider.getBlock(log.blockNumber);
      if (!block) throw new Error(`Block ${log.blockNumber} is unavailable.`);
      timestamp = block.timestamp;
      timestamps.set(log.blockNumber, timestamp);
    }
    const parsed = POOL_MANAGER_EVENTS.parseLog(log);
    observations.push({
      timestamp,
      blockNumber: log.blockNumber,
      logIndex: log.index,
      tick: Number(parsed.args.tick),
      event: parsed.name,
    });
  }
  return observations;
}

export async function readDeployment(values) {
  const provider = new JsonRpcProvider(requireValue(values, "RH_RPC_URL"));
  const vault = new Contract(requireValue(values, "VAULT_ADDRESS"), [
    "function poolId() view returns (bytes32)",
    "function manager() view returns (address)",
    "function oracle() view returns (address)",
  ], provider);
  const [network, poolId, manager, oracle] = await Promise.all([
    provider.getNetwork(), vault.poolId(), vault.manager(), vault.oracle(),
  ]);
  if (network.chainId !== 4663n) throw new Error("RPC is not Robinhood Chain mainnet.");
  if (oracle.toLowerCase() !== requireValue(values, "REFERENCE_ORACLE").toLowerCase()) {
    throw new Error("Vault oracle does not match REFERENCE_ORACLE.");
  }
  return { provider, poolId, manager, oracle };
}
