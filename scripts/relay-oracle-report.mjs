import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Contract, JsonRpcProvider, Wallet, verifyTypedData } from "ethers";
import { loadEnvironment, ORACLE_DOMAIN, REPORT_TYPES, requireValue } from "./oracle-tools.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const runtimeDirectory = path.join(packageDirectory, "runtime");
const values = loadEnvironment(path.join(packageDirectory, ".env"));
const report = JSON.parse(fs.readFileSync(path.join(runtimeDirectory, "oracle-report.json"), "utf8"));
const config = JSON.parse(fs.readFileSync(path.join(packageDirectory, "config", "oracle-signers.json"), "utf8"));
const domain = { ...ORACLE_DOMAIN, chainId: report.chainId, verifyingContract: report.oracle };
const value = {
  poolId: report.poolId,
  tick: report.tick,
  observedAt: report.observedAt,
  validUntil: report.validUntil,
  sequence: report.sequence,
};
const allowed = new Set(config.signers.map((address) => address.toLowerCase()));
const signed = fs.readdirSync(runtimeDirectory)
  .filter((name) => name.startsWith("signature-") && name.endsWith(".json"))
  .map((name) => JSON.parse(fs.readFileSync(path.join(runtimeDirectory, name), "utf8")))
  .map((item) => ({
    signature: item.signature,
    signer: verifyTypedData(domain, REPORT_TYPES, value, item.signature),
  }))
  .filter((item) => allowed.has(item.signer.toLowerCase()))
  .sort((a, b) => BigInt(a.signer) < BigInt(b.signer) ? -1 : 1);
if (new Set(signed.map((item) => item.signer.toLowerCase())).size !== signed.length) {
  throw new Error("Duplicate oracle signatures found.");
}
if (signed.length < config.threshold) {
  throw new Error(`Need ${config.threshold} valid signatures; found ${signed.length}.`);
}
if (Math.floor(Date.now() / 1000) > report.validUntil) throw new Error("Report has expired; prepare a fresh report.");

const provider = new JsonRpcProvider(requireValue(values, "RH_RPC_URL"));
try {
  const oracle = new Contract(report.oracle, [
    "function submit(bytes32,int24,uint64,uint64,uint64,bytes[])",
  ], provider);
  const args = [report.poolId, report.tick, report.observedAt, report.validUntil, report.sequence,
    signed.slice(0, config.threshold).map((item) => item.signature)];
  const gas = await oracle.submit.estimateGas(...args);
  if (!process.argv.includes("--broadcast")) {
    console.log(`Validated ${config.threshold} signatures. Estimated relay gas: ${gas}.`);
    console.log("Dry run only. Pass --broadcast with a fresh PRIVATE_KEY in .env to submit.");
  } else {
    const relayer = new Wallet(requireValue(values, "PRIVATE_KEY"), provider);
    const transaction = await oracle.connect(relayer).submit(...args);
    console.log(`Submitted oracle report: ${transaction.hash}`);
    const receipt = await transaction.wait();
    if (!receipt || receipt.status !== 1) throw new Error("Oracle report transaction failed.");
    console.log(`Oracle report confirmed in block ${receipt.blockNumber}.`);
  }
} finally {
  provider.destroy();
}
