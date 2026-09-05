# NVDA lite liquidity contracts

First implementation of the Pons fee receiver and permanent liquidity vault. **Not deployed or independently audited.** There is no replacement ERC-20 here: the project token must be created through Pons.

`NVDA_TOKEN` is the existing tokenized NVIDIA asset used as the Pons pairing token. It is distinct from NVDA lite. The new NVDA lite address is recorded as `PROJECT_TOKEN_ADDRESS` only after the Pons launch transaction succeeds.

## What is implemented

- `LiquidityFeeReceiver` is configured as Pons's `creatorFeeRecipient`. It claims its own quote-token escrow balance and reserves half of actual receipts for liquidity, with the other half accrued to a fixed project treasury. Cumulative rounding prevents tiny repeated claims changing the allocation.
- Anyone can call `claimFeesAndInject()`. It attempts eligible Pons sweeps, claims available fees, then attempts one bounded injection after graduation. Internal conversions still require Pons's operator. Failed injections leave claims and accounting intact for a later attempt.
- `LockedLiquidityVault` owns an additional full-range **direct Uniswap v4 core position in the same pool**. It swaps part of the quote budget, incorporates residual token balances, and increases that position. It does not use a transferable position NFT or modify Pons's original position.
- There is no vault owner, proxy, upgrade, withdrawal, token approval, arbitrary-call, or negative-liquidity entry point. Unused assets remain in the vault. Direct quote donations to the receiver can be accounted with `syncDonations()` and are 100% liquidity funding.
- Anyone can call `payTreasury()`, but payment goes only to the immutable treasury address. The caller receives no reward. Gas is paid externally, with no automatic deduction from liquidity funds.

### Developer withdrawals and the website

`payTreasury()` is the developer withdrawal function. Its maximum payment is the separately tracked `treasuryAccrued` balance; it never reads the entire contract balance as withdrawable funds. The focused test `testDeveloperPayoutCannotWithdrawReservedLiquidityOrPayCaller` covers third-party triggering, repeat withdrawals, and a subsequent liquidity injection from the untouched budget.

The website panel is at `/#inject-liquidity`. Its developer controls appear inside a separate disclosure, and activate for the configured treasury wallet. This is a UI convenience: the contract allows anyone to trigger payment to the fixed treasury. Multisig treasuries can use their own interface or another caller to trigger that payment.

The private website keeps its published receiver, vault, token, and treasury addresses in `src/config/liquidityDeployment.json`. Those addresses remain blank until deployment and verification. This public repository is the canonical contract source.

Users can also use the receiver's Write Contract tab on Robinhood Chain Blockscout once verified. `claimFeesAndInject()`, `claimFees()` and `payTreasury()` require no arguments and no ETH value; gas is paid separately. The receiver's exact explorer link is generated from the same published deployment configuration. Verification and website configuration have not yet been performed.

## Signed reference oracle: configuration required before deployment

`SignedReferenceOracle` implements the immutable `IReferenceOracle` used by the vault. Anyone can relay an EIP-712 tick report, but the oracle accepts it only with the configured signer quorum. It rejects unauthorized or duplicate signatures, expired reports, future observations, excessive validity windows, replayed sequences, and observations older than the current report. The signer set, threshold, and maximum report validity are fixed at deployment; there is no owner or signer-rotation function.

The reference must describe raw token1/token0 units in canonical Uniswap address ordering, including decimals. It must identify the exact pool and derive its value from a reviewed source resistant to manipulation. Reading the target pool's current tick, or merely periodically copying its spot price, does not meet that requirement. Uniswap v4 does not automatically supply a v3-style historical oracle for every pool.

The vault checks freshness, future timestamps, pre/post-swap price deviation, a fixed maximum quote swap amount, and minimum output after fees. Callers cannot choose routes, recipients, minimum output, or a weaker limit. Maximum configurable deviation is 200 ticks (approximately 2% in price); maximum configured swap loss is 5%, including the Pons hook charge. These are ceilings, not deployment recommendations.

The on-chain verification contract and dry-run-first reporting tools are implemented. `prepare-oracle-report.mjs` calculates a 30-minute time-weighted arithmetic mean tick from PoolManager initialization/swap events behind a 100-block confirmation buffer, rather than copying the current spot tick. `sign-oracle-report.mjs` signs that exact EIP-712 report with one reporter key, and `relay-oracle-report.mjs` verifies the quorum and estimates gas unless explicitly passed `--broadcast`. The calculation policy and deployment configuration still require independent review.

## Build and test

Requires Foundry and Git. Solidity is pinned to 0.8.26, Cancun EVM. Dependency revisions are in `dependencies.json`; the contracts are isolated from the old SHI500 package.

Copy `.env.example` to `.env` and fill the blank deployment values. A local git-ignored `.env` has already been created in this workspace with public chain settings, treasury/bootstrapper addresses, oracle signer addresses, and technical limits. The deployed oracle address remains blank. Load it safely into the current PowerShell process without printing values:

```powershell
. ./scripts/load-env.ps1
```

The file includes `RH_RPC_URL`, `PONS_RPC_URL`, `DEPLOYER_ADDRESS`, `PRIVATE_KEY`, `PROJECT_TREASURY`, `LAUNCH_BOOTSTRAPPER`, `REFERENCE_ORACLE`, execution limits, optional fork pinning, Blockscout settings, and post-deployment address slots. `.env` is ignored both here and by the repository root. `.env.example` contains placeholders only.

Oracle reporter keys live separately in the git-ignored `.oracle.env`. Run `node scripts/configure-oracle-wallets.mjs` after filling every slot. It validates the keys without printing them, derives and sorts their public addresses, writes `ORACLE_SIGNERS` and the majority threshold to `.env`, and publishes the address-only list at `config/oracle-signers.json`. A production deployment must distribute signer keys across independent systems; keeping every signer key in one file is suitable only for local configuration and testing.

After the token is launched and the receiver is bound, one reporting cycle is:

```powershell
node ./scripts/prepare-oracle-report.mjs
$env:ORACLE_SIGNER_PRIVATE_KEY = '<one signer key loaded privately on its own reporter>'
node ./scripts/sign-oracle-report.mjs
node ./scripts/relay-oracle-report.mjs
```

Run the signing step independently on enough reporter systems and collect the resulting address-labelled signature files in `runtime`. The relay command is a dry run by default. Production automation must never place every quorum key on the relayer.

```powershell
./scripts/install-dependencies.ps1
forge build
forge test -vv
```

The local suite uses real Uniswap v4 core and a test hook charging 2% on swap output. It covers fee splitting, cumulative rounding, graduation gating, public callers, batch limits, repeated position increases, both currency orderings, stale/future/manipulated prices, callback authorization, reentrancy, direct donations, and conservation of funds through fuzzed claims and injections.

Final verification on 5 September 2026: **26 Solidity tests passed**, comprising 16 liquidity-system tests, 7 signed-oracle tests, and 3 live-state fork tests at block **55130253**. The fork suite now creates a brand-new token through the real Pons V2 factory with the receiver as fee recipient, binds it, and verifies creation of the permanent vault. The two fuzz tests ran 256 cases each. Four Node tests also cover the reporter's time-weighted tick calculation, including same-block observations and negative rounding. No tests failed or were skipped.

Opt-in fork tests use the real Robinhood Chain escrow, factory, hook, pool manager, and an existing NVDA-paired launch. All mutations happen inside the local fork; RPC access only reads chain state.

```powershell
$env:PONS_RPC_URL = 'https://rpc.mainnet.chain.robinhood.com'
forge test --match-contract PonsForkTest -vv
```

Set `PONS_FORK_BLOCK` to pin a block when using an archive-capable RPC. The public RPC could not serve block 54283608; the first successful fork run used block **54368014**, with escrow recipient claiming and two successive deposits against the real Pons hook passing. The current fork suite also creates and binds a new Pons token. These tests prove only the covered integration paths; they do not prove the security of a production oracle or constitute a mainnet deployment.

## Deployment sequence

1. Choose the oracle signers, quorum, report calculation policy, treasury/bootstrapper addresses, execution thresholds, and permanent-funds policy. Have the complete design independently reviewed before using real funds.
2. Simulate `script/DeployReferenceOracle.s.sol:DeployReferenceOracle` using sorted, comma-separated `ORACLE_SIGNERS`, `ORACLE_THRESHOLD`, and `MAX_REPORT_VALIDITY_SECONDS`. After deployment and verification, set `REFERENCE_ORACLE` to its address.
3. Simulate `script/DeployReceiver.s.sol:DeployReceiver` with a Robinhood Chain RPC. It reads the factory's actual manager, hook and escrow addresses, checks their consistency, and creates the receiver. Forge scripts simulate unless explicitly given `--broadcast`; no live deployment has been performed.
4. Fill the immutable token metadata and simulate `script/LaunchProjectToken.s.sol:LaunchProjectToken`. It reads the factory's current config and economics immediately before creation, launches with the receiver as `creatorFeeRecipient`, NVDA as pairing asset, **100 basis points creator tax**, and native buybacks off. The script rejects an unavailable deployer, unapproved quote, disabled config, non-1% base fee, or nonzero core LP fee.
5. Put the returned token address into `PROJECT_TOKEN_ADDRESS` and simulate `script/BindLaunch.s.sol:BindLaunch`. The configured bootstrapper calls `bindLaunch(token)` once. Binding verifies the factory record, recipient, pairing asset, fee settings and curve, then creates the permanent vault. The bootstrapper has no further control and cannot rebind.
6. Verify the oracle, receiver and vault bytecode, pool identity, oracle configuration and launch data. Fund caller gas externally and publish transaction links. A bot can relay signed oracle reports and submit the same public injection function as anyone else.

The oracle deployment script requires `ORACLE_SIGNERS`, `ORACLE_THRESHOLD`, and `MAX_REPORT_VALIDITY_SECONDS`. Signer addresses must be strictly ascending. The receiver deployment script requires explicit values for `REFERENCE_ORACLE`, `PROJECT_TREASURY`, `LAUNCH_BOOTSTRAPPER`, `MIN_BATCH_RAW`, `MAX_BATCH_RAW`, `MAX_SWAP_QUOTE_RAW`, `MAX_ORACLE_AGE_SECONDS`, `MAX_TICK_DEVIATION`, and `MAX_SWAP_LOSS_BPS`. Amounts are raw NVDA units (18 decimals). Neither script creates the Pons token.

After loading the environment, simulate without broadcasting:

```powershell
forge script script/DeployReceiver.s.sol:DeployReceiver --rpc-url $env:RH_RPC_URL --sender $env:DEPLOYER_ADDRESS
```

Run `node scripts/check-deployment-readiness.mjs` before every deployment stage. It validates key/address consistency and public configuration without printing secrets, and distinguishes missing immutable launch metadata from addresses that are expected only after earlier stages.

Simulation must pass before constructing a broadcast command. Deployment is an irreversible external action and has not been authorized or performed. Prefer an encrypted Foundry keystore or hardware wallet for mainnet; if `PRIVATE_KEY` is used, keep `.env` local and never paste it into chat, logs, source files, or shell output.

## Permanent-funds policy and external dependencies

- Liquidity budgets cannot be recovered if the launch never graduates, is rescued, or permanently loses a usable oracle. The treasury can still withdraw only its separately accrued half. This strict first implementation requires acceptance before deployment; it is not a reversible trial with real funds.
- Direct quote transfers, including exceptional Pons recovery transfers outside the escrow, are treated as 100% liquidity donations when synced. Non-quote tokens sent to the receiver have no recovery function. Do not send assets directly expecting a refundable deposit.
- Pons can redirect future recipient fees or change buyback state through its own administration. This receiver exposes neither action. Previously claimed budgets remain in the contracts; the complete protocol is not ownerless.
- Adding liquidity incurs the Pons swap charge and price impact. `totalSentToVault` measures budgets delivered to the vault, not all capital already deposited. Residual balances and emitted liquidity units must be reported separately.
- A public caller can choose when to execute within the immutable checks. Sandwich and price-reference risks remain; the guards do not promise lossless execution. Oracle outages stop injections, and pending Pons conversions can delay claims.

## Sources

- [Pons v2 documentation](https://docs.ponsfamily.com/v2)
- [Pons published interfaces](https://github.com/ponsdotdev/ponsfamily/blob/main/contractsV2/src/v2/interfaces/ILaunchpadV2.sol)
- [Pons launch factory](https://github.com/ponsdotdev/ponsfamily/blob/main/contractsV2/src/v2/PonsV2LaunchFactory.sol)
- [Pons fee hook](https://github.com/ponsdotdev/ponsfamily/blob/main/contractsV2/src/v2/hooks/PonsV2MemeHook.sol)
- [Pinned Uniswap v4 core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75)
