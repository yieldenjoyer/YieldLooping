## PT Loopers — v3 (free, EOAbonly, self custodial Pendle PT looping)

# Support / Donations

If it saved you money, a tip is appreciated but never required, and it buys you nothing extra.

| Chain | Address |
|---|---|
| BTC | `bc1pqve32dpz9zma2l67ns4z0q7w42usdtdgqhwd5pyqng8kv9cacwyszd4xsp` |
| ETH *(any ETH token — USDT/USDC/ETH/etc.)* | `0x523bB94BFe5cf47087eB5556D5ed00515cdC487e` |
| SOL | `8UDYmi9Fw7Kg8p8K1xTc2pnViPswVga9vHmTvgwqFBzw` |
| SUI | `0xb9726c6024e577684eaeb4670ea97a387b4de558558c3694a62da6179a5ac121` |

**Another method of support/donation** is you can trade on https://www.sigmaengine.io to farm multiple perp DEX's with market making/HFT/Delta Neutral strats and more.

Three independent loopers, same strategy (leveraged Pendle PT), different flash/borrow source:

| File | Flash/borrow source | Extra cost | Notes |
|---|---|---|---|
| `MorphoPTLooper.sol` | Morpho Blue flash | **0 fee** | preferred when Morpho has loan-token liquidity |
| `AavePTLooper.sol` | Aave V3 flash | **~5 bps premium / leg** | fallback for large flashes; **needs viaIR** |
| `EulerPTLooper.sol` | Euler EVC deferred checks | 0 flash fee | one Euler market at a time; optional 4626 wrapper |

Every user deploys their **own** looper from the factory and is its immutable `owner`. No protocol fee exists anywhere in these contracts — there is no treasury, admin, or skim to remove. "Free" means *no fee taken from you(the user) by some protocol*, but users still pay gas + the borrow interest inherent to leverage (+ Aave's premium on that variant only if you flash via them).

---

## updates:

- **Slippage (M1):** `open()` now takes an **absolute `minPtOut`** (PT units) instead of a bps figure derived from the loan token amount. The old `(amount * bps)/10_000` assumed 1 loan-token = 1 PT, which is false on any SY whose exchange rate ≠ 1 (most yield-bearing PTs) — it silently became a no op. Your UI now computes from the Pendle quote.
- **EOA-only:** `createLooper()` and `open()/close()` require `msg.sender == tx.origin`. **This excludes Safe / 4337 / smart contract wallets** by design. Remove the `onlyEOA` modifier + the factory check if you ever want to support them.
- **Euler controller release (M3):** `close()` now releases the controller even on a zero debt (unlevered) position, so it can't strand and block the next market.
- **Euler YT pre-check (M4):** uses `convertToAssets(shares)` for the exact PT amount, and now also checks YT **allowance**, not just balance.
- **All loopers:** `close()` checks YT allowance up front (clear error instead of a mid flash revert).

**Build status:** all three compile clean on solc 0.8.19, 0 warnings (Morpho/Euler legacy pipeline; Aave under `via_ir = true`, set in `foundry.toml`). Sizes are well under the 24,576-byte limit.

---

## Layout & test

```
./    MorphoPTLooper.sol  AavePTLooper.sol  EulerPTLooper.sol  foundry.toml
test/ MorphoPTLooper.t.sol  AavePTLooper.t.sol  EulerPTLooper.t.sol
```
(Contracts at repo root, tests in `test/` — matching the `import "../MorphoPTLooper.sol"` paths and `src = "."` in `foundry.toml`. Move to `src/` if you prefer; just update the imports and `src`.)

```
forge install foundry-rs/forge-std
# fill the CONFIG block in each test with a real market, then:
forge test --fork-url $ETH_RPC_URL -vvvv
```

> These have been tested via foundry, compiles + works as intended, however still recommend to run tests with forge test --profile test (test build needs optimizer_runs=1 for via-IR stack; deploy
  stays at 200) or you get a stack-too-deep error.

---

## Deploy

One factory per chain. Fill the canonical addresses (verify each on the explorer):

- **Pendle Router V4:** `0x888888888889758F76e7103c6CbF23ABbF58F946` (same on every chain)
- **Morpho Blue singleton:** per chain
- **Aave V3 Pool:** per chain (Aave variant)
- **Euler EVC:** per chain (Euler variant)

Then each user calls `factory.createLooper()` once and operates their looper directly.

---

## What the frontend MUST do (this is where user protection lives)

There is **no on-chain market allowlist** — deliberately. Baking one in would add a trusted admin and break "works with every present/future Pendle market," both of which cut against the free/permissionless model. A clone phishing-UI couldn't abuse the permissionless contract any more than it could abuse a plain token approval, so the contract stays universal and the curation lives in your UI:

1. **Compute `minPtOut`** from the Pendle SDK/quote (expected PT out × (1 − tolerance)). Never pass `1` in production — that disables slippage protection.
2. **Curate the market list.** Only surface `(YT, market)` pairs you've vetted for a sane oracle and real liquidity. The contract validates the PT/SY/loan-token triplet, but it cannot judge oracle quality or liquidity.
3. **Show health / liquidation.** These are leveraged positions; if the PT oracle drops or interest accrues past LLTV they get liquidated. Surface the health factor and warn. Use each looper's `getPosition(...)`.
4. **Guard the YT.** Pre-expiry par-close requires the user still holds the YT (the looper pulls it back). If a user sells/moves it, par-close is impossible and recovery means manually selling PT via the raw `execute()` escape hatch — expert-only. Warn before any action that would move the YT, and don't construct `execute()` calldata for non-expert users except the documented unwind.
5. **Size leverage against the oracle, not just LLTV.** Max borrow ≈ `LLTV × (initial + flash) × ptPrice`. The naive `LLTV/(1−LLTV)` bound ignores the PT discount and will revert on discounted PTs.

---

## Per-variant gotchas

- **Aave:** the 5 bps premium is financed as Morpho debt on open and must be covered by redemption on close, leave headroom or a near-liquidation close can revert.
- **Euler:** one controller (debt vault) per account at a time — fully close before switching markets, or deploy another looper (free). For wrapped-debt markets, **fork-test that the wrapper's `deposit` AND `redeem` are both open** before listing it.
- **Morpho/Aave:** `_debtAssets` hardcodes Morpho's virtual constants (1 / 1e6) and the Morpho variant assumes a 0 flash fee — both correct on mainnet today; if either ever changes, open/close revert (fail-safe, not a loss).

---

## Still required before real money

1. Run the fork tests above against the exact markets you'll list.
2. **External audit.** These are immutable and un-pausable; the only recovery path is each user's own `execute()`
