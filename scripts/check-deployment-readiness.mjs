import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Wallet, getAddress, isAddress } from "ethers";
import { loadEnvironment } from "./oracle-tools.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const values = loadEnvironment(path.join(packageDirectory, ".env"));
const oracleSecrets = loadEnvironment(path.join(packageDirectory, ".oracle.env"));
const publicOracle = JSON.parse(fs.readFileSync(path.join(packageDirectory, "config", "oracle-signers.json"), "utf8"));

const errors = [];
const notes = [];
const requireSetting = (name) => {
  if (!values[name]) errors.push(`${name} is empty.`);
};
const requireAddress = (name) => {
  requireSetting(name);
  if (values[name] && (!isAddress(values[name]) || getAddress(values[name]) === "0x0000000000000000000000000000000000000000")) {
    errors.push(`${name} is not a nonzero address.`);
  }
};

for (const name of ["RH_RPC_URL", "PONS_FACTORY", "NVDA_TOKEN", "DEPLOYER_ADDRESS", "PRIVATE_KEY",
  "PROJECT_TREASURY", "LAUNCH_BOOTSTRAPPER", "ORACLE_SIGNERS", "ORACLE_THRESHOLD",
  "MAX_REPORT_VALIDITY_SECONDS", "TOKEN_NAME", "TOKEN_DESCRIPTION", "PONS_LAUNCH_SALT"]) {
  requireSetting(name);
}
for (const name of ["PONS_FACTORY", "NVDA_TOKEN", "DEPLOYER_ADDRESS", "PROJECT_TREASURY", "LAUNCH_BOOTSTRAPPER"]) {
  requireAddress(name);
}

if (values.PRIVATE_KEY) {
  try {
    if (new Wallet(values.PRIVATE_KEY).address !== getAddress(values.DEPLOYER_ADDRESS)) {
      errors.push("PRIVATE_KEY does not match DEPLOYER_ADDRESS.");
    }
  } catch {
    errors.push("PRIVATE_KEY is not a valid private key.");
  }
}

const localKeys = Object.entries(oracleSecrets)
  .filter(([name]) => /^ORACLE_WALLET_\d+_PRIVATE_KEY$/.test(name))
  .map(([, key]) => key);
try {
  const localAddresses = localKeys.map((key) => new Wallet(key.startsWith("0x") ? key : `0x${key}`).address.toLowerCase()).sort();
  const configuredAddresses = publicOracle.signers.map((address) => getAddress(address).toLowerCase()).sort();
  if (localAddresses.length !== configuredAddresses.length || localAddresses.some((address, index) => address !== configuredAddresses[index])) {
    errors.push("Local oracle keys do not match config/oracle-signers.json.");
  }
  if (Number(values.ORACLE_THRESHOLD) !== publicOracle.threshold) {
    errors.push("ORACLE_THRESHOLD does not match config/oracle-signers.json.");
  }
} catch {
  errors.push("One or more local oracle private keys are invalid.");
}

if (!values.REFERENCE_ORACLE) notes.push("REFERENCE_ORACLE is filled after oracle deployment.");
if (!values.RECEIVER_ADDRESS) notes.push("RECEIVER_ADDRESS is filled after receiver deployment.");
if (!values.PROJECT_TOKEN_ADDRESS) notes.push("PROJECT_TOKEN_ADDRESS is filled after the Pons launch.");
if (!values.VAULT_ADDRESS) notes.push("VAULT_ADDRESS is filled after bindLaunch().");
if (!values.TOKEN_SYMBOL) errors.push("TOKEN_SYMBOL must be chosen before the Pons launch.");
if (!values.TOKEN_LOGO_URI) errors.push("TOKEN_LOGO_URI needs a public HTTPS or IPFS URL before the Pons launch.");

console.log(`Readiness check: ${errors.length === 0 ? "configuration complete" : `${errors.length} item(s) remain`}.`);
for (const error of errors) console.log(`- REQUIRED: ${error}`);
for (const note of notes) console.log(`- SEQUENCE: ${note}`);
console.log("Secret values were validated without printing them.");
if (errors.length) process.exitCode = 1;
