import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Wallet } from "ethers";
import { ORACLE_DOMAIN, REPORT_TYPES } from "./oracle-tools.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const reportPath = process.argv[2] || path.join(packageDirectory, "runtime", "oracle-report.json");
const privateKey = process.env.ORACLE_SIGNER_PRIVATE_KEY;
if (!privateKey || !/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
  throw new Error("Set ORACLE_SIGNER_PRIVATE_KEY locally to one fresh signer key.");
}
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const wallet = new Wallet(privateKey);
const domain = { ...ORACLE_DOMAIN, chainId: report.chainId, verifyingContract: report.oracle };
const value = {
  poolId: report.poolId,
  tick: report.tick,
  observedAt: report.observedAt,
  validUntil: report.validUntil,
  sequence: report.sequence,
};
const signature = await wallet.signTypedData(domain, REPORT_TYPES, value);
const output = path.join(path.dirname(reportPath), `signature-${wallet.address}.json`);
fs.writeFileSync(output, `${JSON.stringify({ signer: wallet.address, signature, value }, null, 2)}\n`, "utf8");
console.log(`Signed report as ${wallet.address}.`);
console.log(`Signature file: ${output}`);
