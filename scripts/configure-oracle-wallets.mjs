import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Wallet } from "ethers";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.resolve(scriptDirectory, "..");
const secretsPath = path.join(packageDirectory, ".oracle.env");
const environmentPath = path.join(packageDirectory, ".env");
const publicConfigDirectory = path.join(packageDirectory, "config");
const publicConfigPath = path.join(publicConfigDirectory, "oracle-signers.json");

const secrets = fs.readFileSync(secretsPath, "utf8");
const entries = [...secrets.matchAll(/^ORACLE_WALLET_(\d+)_PRIVATE_KEY=(.*)$/gm)]
  .map((match) => ({ index: Number(match[1]), value: match[2].trim() }))
  .sort((a, b) => a.index - b.index);

if (entries.length === 0 || entries.some(({ value }) => value.length === 0)) {
  throw new Error("Every oracle wallet slot must contain a private key.");
}

const addresses = entries.map(({ index, value }) => {
  const normalized = value.startsWith("0x") ? value : `0x${value}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
    throw new Error(`Oracle wallet ${index} is not a 32-byte private key.`);
  }
  return new Wallet(normalized).address;
});

if (new Set(addresses.map((address) => address.toLowerCase())).size !== addresses.length) {
  throw new Error("Oracle wallet private keys must all be unique.");
}

addresses.sort((a, b) => {
  const left = BigInt(a);
  const right = BigInt(b);
  return left < right ? -1 : left > right ? 1 : 0;
});

const threshold = Math.floor(addresses.length / 2) + 1;
let environment = fs.readFileSync(environmentPath, "utf8");
environment = environment.replace(/^ORACLE_SIGNERS=.*$/m, `ORACLE_SIGNERS=${addresses.join(",")}`);
environment = environment.replace(/^ORACLE_THRESHOLD=.*$/m, `ORACLE_THRESHOLD=${threshold}`);
fs.writeFileSync(environmentPath, environment, "utf8");

fs.mkdirSync(publicConfigDirectory, { recursive: true });
fs.writeFileSync(
  publicConfigPath,
  `${JSON.stringify({ threshold, signers: addresses }, null, 2)}\n`,
  "utf8",
);

console.log(`Configured ${addresses.length} unique oracle signer addresses with a ${threshold}-of-${addresses.length} threshold.`);
console.log(`Public signer list: ${publicConfigPath}`);
console.log("Private keys were not printed or copied into the public configuration.");
