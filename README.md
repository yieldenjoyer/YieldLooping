# PT Looper — Self-Custodial Leveraged Pendle PT, Any Market, on Morpho / Aave / Euler

One tx leveraged fixed yield on **any** Pendle PT market: flash/atomic borrow → mint PT+YT at par → PT as collateral on a money market → borrow to settle → done. The **YT (yield + points leg) goes straight to your wallet**. Close unwinds everything in one transaction, also at par.

Markets are chosen **per call, not per deployment**. You deploy your personal looper once per chain, then point it at any PT market — today's and every future maturity — by passing the market parameters to `open()`/`close()`. Nothing to redeploy when a new PT lists.

**Free. No protocol fee, ever** — there is no fee switch anywhere in these contracts. This exists for the DeFi degens who love looping and don't want to hand 8–15 bps to some frontend on every open/close. You pay gas + the borrow interest inherent to leverage (+ Aave's 5 bps flash premium on that one flavor). Nothing else.

## Support / Donations

If it saved you money, a tip is appreciated — never required, and it buys you nothing extra.

| Chain | Address |
|---|---|
| BTC | `bc1pqve32dpz9zma2l67ns4z0q7w42usdtdgqhwd5pyqng8kv9cacwyszd4xsp` |
| ETH *(any ETH token — USDT/USDC/ETH/etc.)* | `0x523bB94BFe5cf47087eB5556D5ed00515cdC487e` |
| SOL | `8UDYmi9Fw7Kg8p8K1xTc2pnViPswVga9vHmTvgwqFBzw` |
| SUI | `0xb9726c6024e577684eaeb4670ea97a387b4de558558c3694a62da6179a5ac121` |

**Another method of support/donation** is you can trade on https://www.sigmaengine.io to farm multiple perp DEX's with market making/HFT/Delta Neutral strats and more.

## Three flavors

| Contract | Money market | Flash source | Flash fee | Notes |
|---|---|---|---|---|
| `MorphoPTLooper.sol` | Morpho Blue | Morpho Blue | 0 | **Default.** Many markets in parallel per looper. |
| `AavePTLooper.sol` | Morpho Blue | Aave V3 | 5 bps (financed as debt) | Only when flash size exceeds Morpho's idle liquidity. **Requires `via_ir`.** |
| `EulerPTLooper.sol` | Euler v2 | none — EVC deferred checks | 0 | Borrows the target before collateralizing; one health check at batch end. One active market per looper at a time. |

---

## Trust model — read this first

- **You deploy your own looper** via the factory (`createLooper()`, one-time). It is yours alone: every function is `onlyOwner`, the owner is **immutable**, and positions live on your looper's own account at the money market.
- **EOA-only.** Deploy and operate require `msg.sender == tx.origin`. This deliberately **excludes Safe / multisig / ERC-4337 smart-contract wallets** — a personal looper is meant to be driven directly by your own key. (If you need smart-wallet support, it's one modifier to remove and redeploy your own factory.)
- **There is no admin.** No upgradability, no pause, no fee switch, no privileged role for the factory deployer. After the factory exists, nobody — including its author — has power over any looper.
- **No shared authorization.** Your looper acts only on its own positions (`msg.sender == onBehalf` / its own EVC account), which the protocols permit natively.
- **Market params are validated on-chain.** You pass a market + a YT address; the looper reads PT and SY **from the YT contract itself** and proves the set is consistent (collateral == that PT, SY mints/redeems the loan asset). A mismatched set reverts with a named error — it cannot silently misroute funds.
- **`execute()` escape hatch.** Your looper can raw-call anything, signed by you. If `open()`/`close()` were ever broken, you can still repay, withdraw, and rescue everything yourself (runbook below). Your funds' safety depends on the underlying protocols — not on this code being correct.

**What you DO trust:** the money market (including each chosen market's oracle and IRM), Pendle (SY/PT/YT + RouterV4), the loan asset itself, and Aave V3 only if you use that flavor.

### What the contracts enforce (v2)

- **Absolute slippage floor.** `open()` takes `minPtOut` in **PT units** (not a bps figure). You compute it off-chain from the Pendle quote minus your tolerance; the mint reverts if it returns less PT. *(v1 used a bps floor derived from the loan amount, which silently no-op'd on any SY whose exchange rate ≠ 1 — i.e. most yield-bearing PTs. Fixed.)*
- **Exact repayment, by protocol.** Morpho: repay by shares after a same-tx `accrueInterest`, mirroring `toAssetsUp` rounding — flash == pulled, to the wei. Euler: `repay(type(uint256).max)` is protocol-exact.
- **Aave initiator check is load-bearing.** Anyone can initiate an Aave flash naming an arbitrary receiver; `initiator == address(this)` is what stops a hostile callback. Do not remove it.
- **Euler controller is always released on close** — including a zero-debt (unlevered) close — so it can't strand and block your next market.

---

## Pointing it at any asset — what to pass

Get the identifiers once, reuse forever.

### Morpho / Aave flavors — `(MarketParams, yt)`

- **`MarketParams`** — the exact 5-tuple `(loanToken, collateralToken, oracle, irm, lltv)` of the target Morpho market, from the Morpho app/API. It must be **exact**: the contract computes `keccak256(abi.encode(params))` as the market id — one wrong field addresses a market that doesn't exist (reverts, nothing lost).
- **`yt`** — the YT address from Pendle's market page for that PT/maturity. PT and SY are derived from it on-chain; you cannot pass a mismatched PT.

Enforced for you: `marketParams.collateralToken == yt.PT()`, and the SY must accept and return the `loanToken` (`isValidTokenIn/Out`). In practice the Morpho market's loan asset is the PT's underlying (USDe for PT-USDe, etc.) — same asset in and out is what keeps the flow at par and oracle-free.

### Euler flavor — `(collateralVault, debtVault, wrapper, yt)`

- **`collateralVault`** — the Euler eVault holding the PT (`asset()` must equal `yt.PT()`; enforced).
- **`debtVault`** — the eVault you borrow from (becomes your looper's controller).
- **`wrapper`** — `address(0)` normally. If the debt asset is a 4626 wrapper of the mint token (e.g. debt = `eUSDe`, which wraps USDe), pass the wrapper and the looper hops through deposit/redeem automatically. **Fork-test that both directions of the wrapper are open before relying on it.**
- **`yt`** — same as above.

Euler constraint: the EVC allows **one controller (debt vault) per account**, so an Euler looper runs **one active market at a time** — fully close (the controller is released automatically) before opening a different market, or deploy another looper (free) for parallel positions. Morpho loopers hold any number of markets in parallel.

---

## How it works

### Open — `open(market…, yt, initialAmount, flashOrBorrowAmount, minPtOut)`

1. Pulls `initialAmount` of the loan/mint asset from your wallet (approve first).
2. Flash-borrows the leverage (Morpho/Aave) or borrows directly under deferred checks (Euler).
3. Mints PT+YT from the full sum **at par via the SY** — never priced through an AMM; floored by `minPtOut`.
4. Supplies all PT as collateral on your position.
5. Settles the flash from a borrow (Morpho/Aave) or passes the single batch-end health check (Euler).
6. Sends all YT to your wallet.

One flash/batch collapses the entire iterative loop — there is nothing to "loop N times." `open()` is **additive**: call again any time to add capital or leverage.

### Close — `close(market…, yt, minOut)`

1. Sources the exact debt (flash on Morpho/Aave — interest accrued in-tx first, converted with the protocol's own rounding, exact to the wei; Euler repays with `type(uint256).max`, exact by protocol).
2. Repays in full — by shares on Morpho, max-repay on Euler — both immune to per-second accrual.
3. Withdraws all PT.
4. Redeems PT+YT → loan asset **at par**. Pre-expiry this pulls your YT back (balance **and** allowance checked up front). Post-expiry YT is not needed.
5. Settles the flash (+ premium on Aave); everything left goes to your wallet, floored by `minOut`.

### ⚠️ The YT rule

If you sell your YT, you **cannot close at par before maturity.** Pre-expiry close requires YT equal to your PT collateral, approved to your looper. Sold it? Buy it back, or wait until expiry (post-expiry close needs no YT). The YT in your wallet is your yield/points leg — that flexibility is the product; this constraint is its price.

---

## Leverage math

```
max borrow ≈ initialAmount × LTV / (1 − LTV)   — at the market oracle's PT price
```

Worked example, LTV = 91.5%: `$10,000` initial → max ≈ `$107,600` borrowed (~11.8× exposure). **The oracle prices PT below 1, so your real max is lower than this formula** — size off the projected health on the Morpho/Pendle UI, and stay at **≤ 80% of the bound**. Opening at the max means liquidation on the first basis point of adverse oracle movement.

Overshooting is safe in the narrow sense: the borrow (or batch-end check) reverts and the whole transaction unwinds — you lose gas, nothing else. The borrow is also capped by the lender's available cash (flash liquidity on Morpho, vault cash on Euler).

**Carry risk — the one nobody prints:** your PT yield is fixed at entry; your borrow rate floats with utilization. If the borrow APR rises above the PT's implied APY, a leveraged position bleeds — at 10×, a 1% rate gap is roughly 10% annualized on your equity. Looping itself pushes utilization (and the rate) up. Watch the market's rate, not just the liquidation price.

**Maturity:** at PT expiry the YT goes to zero and close stops needing it. There is no auto-roll — close, then open on the next maturity by passing its market params. Same looper, no redeploy.

---

## Deployments

Protocol addresses (**always verify yourself on a block explorer before trusting any deployment**). Morpho Blue singleton and Pendle RouterV4 are the same address on every chain.

| Protocol | Ethereum (1) | Base (8453) |
|---|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Pendle RouterV4 | `0x888888888889758F76e7103c6CbF23ABbF58F946` | `0x888888888889758F76e7103c6CbF23ABbF58F946` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Euler EVC | see euler finance docs per chain. Also recommended reading is evc.wtf to learn.

Factory constructors take **only** protocol addresses (one factory per chain per flavor):

- Morpho flavor: `(morpho, pendleRouter)`
- Aave flavor: `(morpho, aavePool, pendleRouter)`
- Euler flavor: `(evc, pendleRouter)`

### Official factory deployments

| Chain | Flavor | Factory | Status |
|---|---|---|---|
| _add after deploy + verification_ | | | |

Anything not in this table is a fork we do not stand behind. Impersonation factories are a standard grift — check the address here, check the source is verified, check `owner` on your looper is **you**.

---

## User flow

```solidity
// one-time per chain (EOA only — call from your own wallet, not a Safe/contract)
looper = factory.createLooper();

// per position (Morpho flavor shown)
loanToken.approve(looper, initialAmount);
looper.open(marketParams, yt, initialAmount, flashAmount, minPtOut); // minPtOut in PT units, from the Pendle quote

// ... YT is now in your wallet; PT collateral + debt on your looper's position ...

// closing before expiry
yt.approve(looper, ptCollateralAmount);   // looper.getPosition(marketParams) tells you the amount
looper.close(marketParams, yt, minOut);
```

---

## Recovery runbook (`execute()`)

If `close()` ever reverts and you want out now, your looper can do everything manually. All calls below are `looper.execute(target, 0, calldata)` signed by you.

**Morpho flavors:**

1. Repay debt manually (loan tokens must be on the looper — transfer some in):
   - `execute(loanToken, 0, approve(MORPHO, amount))`
   - `execute(MORPHO, 0, repay(marketParams, 0, yourBorrowShares, looperAddress, ""))` — shares from `getPosition()`
2. Withdraw collateral (after debt is zero):
   - `execute(MORPHO, 0, withdrawCollateral(marketParams, collateral, looperAddress, yourWallet))`
3. Redeem PT yourself: from your wallet via Pendle's app, or via `execute()` against the router (`redeemPyToSy`, then SY `redeem`).
4. Rescue any token: `looper.sweep(token)`.

**Euler flavor:** same shape — `execute(debtVault, 0, repay(type(uint256).max, looperAddress))` after approving the debt asset, then `execute(debtVault, 0, disableController())`, then `execute(collateralVault, 0, redeem(shares, looperAddress, looperAddress))`, then redeem/sweep.

**Drill this on a fork once before you need it.** It is the whole point of the design.

---

## Design rationale (for reviewers)

Pre-answering the standard checklist, because each of these is deliberate:

- **No oracle reads in this contract.** Minting and redemption are at par through the SY (bounded by `minPtOut`/`minOut`); flash/debt settlement is exact. The only oracle in the system is the money market's own, used at borrow/batch-end for the LTV check — where it belongs. Adding an oracle read here would create a manipulation surface, not remove one.
- **Per-call market params are safe by construction.** Params are supplied only by the looper's sole owner and validated against the YT contract's own `PT()`/`SY()` plus the SY's token lists. The worst a wrong-but-consistent set can do is open a position the owner didn't intend — on their own single-owner contract, with their own funds, atomically revertible by the health check.
- **Repayment is exact by protocol, not by buffer.** Debt grows per second; asset-exact repayment any other way is a race you lose.
- **The Aave initiator check is load-bearing.** Without `initiator == address(this)`, an attacker feeds the callback arbitrary params. Do not "simplify" it away.
- **Reentrancy:** entry points take a lock; callbacks/batch-steps require the in-flight state (`unlocked == 2`) plus provider-restricted `msg.sender` (Morpho only calls back the flash initiator; EVC items are authenticated to the account owner; Aave adds the initiator check).
- **`execute()` exists on purpose.** An owner-only raw call on a single-owner contract holding no third-party funds is recovery, not a backdoor. It can do nothing the owner couldn't do by design.

---

## Build & test (Foundry)

```
forge install foundry-rs/forge-std
forge test --fork-url $RPC_URL -vvv
```

`via_ir = true` is **required** (set in `foundry.toml`): `AavePTLooper` is stack-too-deep on the legacy pipeline. It is harmless for the Morpho/Euler loopers. All three compile clean on solc 0.8.19 with zero warnings; bytecode is well under the 24 KB limit.

> These contracts compile clean but the fork tests have **not been run against live markets** in this repo — they need a mainnet fork and real market addresses. Fill the CONFIG blocks and run them on a fork of your target chain before deploying.

The invariant matrix any deployment must pass on a fork of the target chain:

| Test | Status |
|---|---|
| `OpenClose_RoundTrip` — open levered → close, debt == 0, capital recovered ± rates/dust | included |
| `Open_OverLeveraged_Reverts` — borrow beyond the LTV bound reverts cleanly, no state change | included |
| `Open_Slippage_Reverts` — `minPtOut` floor bites | included |
| `Params_Mismatch_Reverts` — wrong yt / collateral vault / loan token revert with named errors | included |
| `EOA_Gate` — a contract caller cannot deploy or operate a looper | included |
| `Euler_Unlevered_Close_ReleasesController` — controller freed even at zero debt | included |
| `OpenClose_AaveSource` — same through the Aave flavor, premium accounted | **add** |
| `Close_AfterExpiry` — warp past maturity, close without YT | **add** |
| `Open_Additive` — second `open()` grows the same position | **add** |
| `MultiMarket_Parallel` — Morpho: two markets on one looper, independent open/close | **add** |
| `Euler_WrappedDebtAsset` — full cycle with a 4626-wrapped debt asset (e.g. eUSDe) | **add** |
| `Euler_SecondMarket_Reverts` — opening market B while A is active reverts | **add** |
| `Recovery_Drill` — full manual unwind via `execute()`/`sweep` only | **add** |
| `Callback_Hostile` — direct callback/step calls and attacker-initiated Aave flash revert | **add** |

The included `test/` files cover the first six; extend with the rest before mainnet.

---

## Known limitations

- Full close only per market (no partial close in v1 — `execute()` covers surgical cases).
- **EOA-only:** no Safe / multisig / smart-contract-wallet support by design.
- Euler flavor: one active market per looper at a time (EVC single-controller rule); deploy more loopers for parallel Euler positions.
- The market's loan/debt asset must be SY-mintable (directly, or through the 4626 wrapper on Euler).
- Personal looper deployment costs ~0.5–0.9M gas one-time (pennies on Base).
- Aave flavor finances the 5 bps premium as additional Morpho debt.

---

## Status & disclaimer

**Unaudited.** Fork-tested invariants are necessary, not sufficient — treat any deployment as **beta** until an audit report is linked here. MIT licensed, provided as-is, no warranty. Leveraged positions can be liquidated; fixed-vs-floating carry can go negative; you are responsible for your own positions and your own market parameters. This is software, not advice. Test thoroughly (Foundry or Tenderly) for any edge cases before any real-money deployment.

**Read the deployment guide and fork-test it yourself before deploying with real money. Always.**
