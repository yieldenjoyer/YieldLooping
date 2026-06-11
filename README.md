## Donations are appreciated, but this is for the defi degens who love looping but dont wanna pay some protocol 8-15bps to open/close.
BTC: bc1pqve32dpz9zma2l67ns4z0q7w42usdtdgqhwd5pyqng8kv9cacwyszd4xsp
ETH:0x523bB94BFe5cf47087eB5556D5ed00515cdC487e - can send any eth token (USDT/USDC/ETH/etc)
SOL:8UDYmi9Fw7Kg8p8K1xTc2pnViPswVga9vHmTvgwqFBzw
SUI:0xb9726c6024e577684eaeb4670ea97a387b4de558558c3694a62da6179a5ac121

## READ: 
## Always test via foundry or similar before deploying with real $$ ALWAYS!

## THIS FILE & SMART CONTRACT IS FOR DEMONSTRATION PURPOSES ONLY, NO PROMISES OF COMPLETE WORKABILITY AND COULD LEAD TO PARTIAL OR FULL LOSS OF FUNDS.

## README:

# PT Looper — Self-Custodial Leveraged Pendle PT on Morpho Blue

One-transaction leveraged fixed-yield: flash loan → mint Pendle PT+YT at par → PT collateral on Morpho Blue → borrow to repay the flash. The YT (yield + points leg) goes straight to your wallet. Close unwinds the whole position in one transaction, also at par.

Two flavors, identical strategy, different flash source:
| Contract | Flash source | Flash fee | When to use |
|---|---|---|---|
| `MorphoPTLooper.sol` | Morpho Blue | **0** | Default. Always try this first. |
| `AavePTLooper.sol` | Aave V3 | 5 bps (financed as Morpho debt) | Only when flash size exceeds Morpho's idle loan-token liquidity. |

## Trust model — read this first

- **You deploy your own looper** via the factory (`createLooper()`). It is yours alone: every function is `onlyOwner`, the owner is immutable, and the position lives on *your looper's* Morpho account.
- **There is no admin.** No upgradability, no pause, no fee switch, no privileged role for the factory deployer. After the factory is deployed, nobody — including its author — has any power over any looper.
- **No shared authorization.** You never call Morpho's `setAuthorization`. Your looper acts only on its own Morpho position (`msg.sender == onBehalf`), which Morpho permits natively.
- **`execute()` escape hatch.** Your looper can raw-call anything, signed by you. If `open()`/`close()` were ever broken, you can still repay, withdraw, and rescue everything yourself (runbook below). The safety of your funds depends on Morpho and Pendle — not on this code being correct.
- **What you DO trust:** Morpho Blue (including the chosen market's oracle and IRM), Pendle (SY/PT/YT + RouterV4), the loan token itself (e.g. USDe), and Aave V3 if you use the Aave-flash flavor.

## How it works

**Open** — `open(initialAmount, flashAmount, minPtBps)`
1. Pulls `initialAmount` of the loan token from your wallet (approve first).
2. Flash-borrows `flashAmount`.
3. Mints PT+YT from the full sum **at par via the SY** — never priced through an AMM.
4. Supplies all PT as collateral to your Morpho position.
5. Borrows `flashAmount` (+ Aave premium, if applicable) as your Morpho debt and repays the flash.
6. Sends all YT to your wallet.

One flash collapses the entire iterative loop — there is nothing to "loop N times." Maximum leverage in a single shot is the same bound infinite iteration converges to. `open()` is **additive**: call it again any time to add capital or leverage.

**Close** — `close(minOut)`
1. Flash-borrows your **exact** debt (interest is accrued in the same transaction first, then converted from shares with Morpho's own rounding — exact to the wei).
2. Repays your debt **by shares** (immune to per-second interest accrual).
3. Withdraws all PT (zero debt → always healthy).
4. Redeems PT+YT → loan token **at par**. Pre-expiry this pulls your YT back (see the rule below). Post-expiry YT is not needed.
5. Repays the flash (+ premium on Aave); everything left goes to your wallet.

## The YT rule

**If you sell your YT, you cannot close at par before maturity.** Pre-expiry close requires YT equal to your PT collateral, approved to your looper. Sold it? Either buy it back, or wait until expiry (post-expiry close needs no YT). The YT in your wallet is your yield/points leg — that flexibility is the product; this constraint is its price.

## Leverage math

```
max flashAmount = initialAmount × lltv / (1 − lltv)   (at the market oracle's PT price)
```

Worked example, lltv = 91.5%: $10,000 initial → max flash ≈ $107,600 (~11.8× exposure). **Opening at the max means liquidation on the first basis point of adverse oracle movement.** Stay at ≤ 80% of the bound. Overshooting is safe in the narrow sense: the borrow reverts and the entire transaction unwinds — you lose gas, nothing else.

**Carry risk — the one nobody prints:** your PT yield is fixed at entry; your Morpho borrow rate floats with utilization. If the borrow APR rises above the PT's implied APY, a leveraged position bleeds — at 10×, a 1% rate gap is roughly 10% annualized on your equity. Looping itself pushes utilization (and the rate) up. Watch the market's rate, not just the liquidation price.

**Maturity:** at PT expiry the YT goes to zero and close stops needing it. There is no auto-roll — close, then open on the next maturity's factory. Each factory is bound to exactly one (market, maturity).

## Deployments

Protocol addresses (verify yourself on a block explorer before trusting any deployment):

| Protocol | Ethereum (1) | Base (8453) |
|---|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Pendle RouterV4 | `0x888888888889758F76e7103c6CbF23ABbF58F946` | `0x888888888889758F76e7103c6CbF23ABbF58F946` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |

# Official factory deployments:
**Anything not in this table is a fork I do not stand behind.** Impersonation factories are a standard grift — check the address here, check the source is verified, check `owner` on your looper is you.
Factory constructor (per market):
- `morpho` — Morpho Blue on that chain
- `aavePool` — Aave flavor only
- `pendleRouter` — Pendle RouterV4 on that chain
- `marketParams` — the **exact** `MarketParams` tuple of the target Morpho market (field order matters; `keccak256(abi.encode(mp))` must equal the live market id). **`loanToken` must be the token the Pendle SY mints from** — same asset in and out, that's what keeps this oracle-free.
- `sy`, `yt` — the Pendle SY and YT for the PT used as collateral (find them on Pendle's market page for the maturity)

## User flow

```
1. factory.createLooper()                      → your looper address (one-time)
2. loanToken.approve(looper, amount)
3. looper.open(initial, flash, 9950)           → position open, YT in your wallet
   ... later ...
4. yt.approve(looper, collateralAmount)        → pre-expiry close only
5. looper.close(minOut)                        → debt cleared, funds in your wallet
```

## Recovery runbook (`execute()`)

If `close()` ever reverts and you want out *now*, your looper can do everything manually. All calls below are `looper.execute(target, 0, calldata)` signed by you.

1. **Repay debt manually** (you need loan tokens on the looper — `transfer` some in, or `sweep` and rebuild):
   ```
   target: MORPHO
   calldata: repay(marketParams, 0, <yourBorrowShares>, <looperAddress>, "")
   // approve first: execute(loanToken, 0, approve(MORPHO, <amount>))
   // borrowShares: from looper.getPosition()
   ```
2. **Withdraw collateral** (after debt is zero):
   ```
   target: MORPHO
   calldata: withdrawCollateral(marketParams, <collateral>, <looperAddress>, <yourWallet>)
   ```
3. **Redeem PT yourself**: send PT (+YT pre-expiry) to Pendle's app from your wallet, or via `execute()` against the router with `redeemPyToSy` then SY `redeem`.
4. **Rescue any token**: `looper.sweep(token)` sends the looper's full balance of `token` to you.

Drill this on a fork once before you need it. It is the whole point of the design.

## Design rationale (for reviewers)

Pre-answering the standard checklist, because each of these is deliberate:

- **No oracle reads in this contract.** Minting and redemption are at par through the SY (bounded by `minPtBps`/`minOut`); the flash repayment is exact debt. The only oracle in the system is the Morpho market's own, used by Morpho for the LTV check at `borrow` — where it belongs. Adding an oracle read here would *create* a manipulation surface, not remove one.
- **Repay is by shares, not assets.** Debt grows every second; asset-exact repayment is a race you lose. Shares clear the debt exactly. The close-path flash amount is computed after `accrueInterest()` in the same transaction with Morpho's own `toAssetsUp` rounding, so flash == pulled, to the wei.
- **The Aave `initiator` check is load-bearing.** Anyone can initiate an Aave flash loan naming an arbitrary receiver. Without `initiator == address(this)`, an attacker feeds your callback arbitrary params. Do not "simplify" it away.
- **Reentrancy:** entry points take a lock; callbacks require the in-flight state (`unlocked == 2`) and provider-restricted `msg.sender`. Morpho only ever calls back the flash initiator.
- **`execute()` exists on purpose.** An owner-only raw call on a single-owner contract holding no third-party funds is recovery, not a backdoor. It can do nothing the owner couldn't do by design.

## Testing (Foundry)

```bash
forge test --fork-url $ETH_RPC_URL -vvv
```

The invariant matrix any deployment must pass on a fork of the target chain:

- `test_OpenClose_RoundTrip` — open levered → close, debt == 0, user recovers capital ± rates/dust
- `test_OpenClose_AaveSource` — same through the Aave flavor, premium accounted
- `test_Close_AfterExpiry` — warp past maturity, close without YT
- `test_Open_OverLeveraged_Reverts` — flash beyond the lltv bound reverts cleanly, no state change
- `test_Open_Additive` — second open() grows the same position
- `test_Recovery_Drill` — full manual unwind via execute()/sweep only
- `test_Callback_Hostile` — direct callback calls and attacker-initiated Aave flash revert

## Known limitations

- Full close only (no partial close in v1 — `execute()` covers surgical cases)
- One market + one maturity per looper; new maturity = new factory
- The Morpho market's `loanToken` must equal the SY's mint token (enforced by design)
- Personal looper deployment costs ~0.5–0.8M gas (pennies on Base)
- Aave flavor finances the 5 bps premium as additional Morpho debt

## Status & disclaimer

**Unaudited.** Fork-tested invariants are necessary, not sufficient — treat any deployment as beta until an audit report is linked here. MIT licensed, provided as-is, no warranty. Leveraged positions can be liquidated; fixed-vs-floating carry can go negative; you are responsible for your own positions. This is software, not advice. Any usage is completely on your own. DYOR an testing before deploying real capital always!
