## Build, Deploy & Use Notes

> **Unaudited beta.** Flash-loan leverage code. Treat every deployment as beta until an
> audit report is linked here. Test on a fork and on testnet with real flows first; start
> mainnet with a tiny size ($500, not your full bag). Nothing here is "100% safe."

### How the leverage works (one-shot flash, NOT iterative)

This does **not** loop deposit→borrow→deposit→borrow. The flash loan collapses all those
iterations into a single atomic transaction that reaches the same converged end-state:

1. **Flash-borrow the entire target up front (one call)** — e.g. on $10k of your own
   capital targeting ~$100k exposure, you flash ~$90k. One flash call from Morpho (free) or
   Aave (5bps, financed as extra debt).
2. **Mint ALL the PT at once** — the contract takes its entire loanToken balance
   (`balanceOf` = your $10k + the $90k flash) and mints PT+YT through Pendle in one
   `mintPyFromToken`, protected by `minPtBps`. → ~$100k of PT, plus the YT, which goes to
   your EOA wallet (earning points/yield).
3. **Deposit ALL the PT as collateral in one go** — one `supplyCollateral` of the full
   ~$100k PT to your money-market position.
4. **Borrow ONCE to repay the flash** — one borrow of exactly the flash amount (Aave: flash
   + premium), which the lender pulls back to settle the flash when the callback returns.
   Debt ≈ $90k, collateral ≈ $100k PT → you're sitting at your target LTV.

**Exact mint path:** loanToken → SY → PT+YT, all inside Pendle's `mintPyFromToken` — no AMM
and no market-price slippage (it's a wrap + split, not a swap). The loanToken→SY leg
converts at the SY's exchange rate (1:1 only when the loanToken is the SY's base unit; for a
yield-bearing SY it's the accrued rate — `minPtBps` guards the variance). The PT+YT↔SY split
is Pendle's fixed par mechanic: 1 PT + 1 YT redeems to 1 SY pre-expiry, PT alone
post-expiry. Sold your YT? Pre-expiry redemption isn't possible — use `execute()` to sell
PT, or wait for expiry.

**Atomic, all-or-nothing.** The whole thing is one tx. If you oversized the flash so step 4's
borrow would exceed the market's LTV, the health check reverts and the entire tx unwinds —
you lose only gas, never funds.

**Sizing the lever** is the single knob: `flashAmount = initialAmount × LTV/(1−LTV)` lands
you at max LTV (use less for headroom — see the sizing section). **Do not add literal
iteration** — it would reintroduce the per-loop gas and slippage the flash design eliminates.

**Net end-state after one tx:** ~$100k PT earning the fixed PT yield, ~$90k debt at the
borrow rate, YT in your wallet earning points/yield — the converged end-state of infinite
manual loops, reached in one shot.

### Compiler

Solidity `^0.8.19`. **`via_ir` is required** (the Aave looper exceeds the legacy stack
limit without it; it is the recommended production setting regardless).

```toml
# foundry.toml
[profile.default]
solc = "0.8.19"
via_ir = true
optimizer = true
optimizer_runs = 200
```

All three loopers compile clean under these settings (Morpho ~12.6KB, Aave ~12.7KB,
Euler ~10.0KB — well under the 24KB limit). No external imports; the minimal `SafeERC20`
and all interfaces are inline.

---

### Addresses you must supply (VERIFY EVERY ONE on the explorer)

> **Never paste protocol addresses from memory, a chat, or an unofficial gist.** A wrong
> address in a money contract is a total-loss bug. Pull each from the protocol's **official**
> docs/address book and confirm on the chain explorer before deploying.

**Factory constructor args (per chain):**

| Looper  | Constructor needs                          | Source of truth |
|---------|--------------------------------------------|-----------------|
| Morpho  | `MORPHO`, `PENDLE_ROUTER`                   | Morpho Blue docs · Pendle docs |
| Aave    | `MORPHO`, `AAVE_POOL`, `PENDLE_ROUTER`     | Morpho · Aave V3 address book · Pendle |
| Euler   | `EVC`, `PENDLE_ROUTER`                      | Euler docs · Pendle |

Fill in per chain you deploy to (leave blank until verified):

| Chain    | PENDLE_ROUTER (V4) | MORPHO (Blue) | AAVE_POOL (V3) | EVC (Euler) |
|----------|--------------------|---------------|----------------|-------------|
| Ethereum | `0x…`              | `0x…`         | `0x…`          | `0x…`       |
| Base     | `0x…`              | `0x…`         | `0x…`          | `0x…`       |
| Arbitrum | `0x…`              | `0x…`         | `0x…`          | `0x…`       |

Official sources:
- Pendle Router V4: https://docs.pendle.finance/Developers/Contracts/Addresses
- Morpho Blue: [https://docs.morpho.org/getting-started/resources/addresses](https://docs.morpho.org/get-started/resources/addresses)
- Aave V3 Pool: [https://aave.com/docs/resources/addresses](https://aave.com/docs/resources/addresses)
- Euler EVC/EVK: [https://docs.euler.finance/developers/addresses](https://docs.euler.finance/developers/contract-addresses)

---

### Per-call parameters

**Morpho / Aave loopers** — pass the EXACT canonical Morpho market. The market id is
`keccak256(abi.encode(MarketParams))`, so a single wrong field silently routes you to a
different (or attacker-created) market. Copy the tuple verbatim from the Morpho API/UI:

```
MarketParams {
  loanToken,        // what you flash + borrow (e.g. USDC, WETH)
  collateralToken,  // the Pendle PT — MUST equal IYT(yt).PT()
  oracle, irm, lltv // copy verbatim from the official market
}
yt  // the Pendle YT for the maturity (PT and SY are derived from it on-chain)
```

**Euler looper** — pass `collateralVault`, `debtVault`, `wrapper` (or `address(0)` when the
debt asset IS the mint token), and `yt`. Fork-test that a wrapped debt asset's deposit AND
redeem are both open before using it.

---

### Sizing the leverage (read before `open`)

`flashAmount` / `borrowAmount` is your leverage. The on-chain health check enforces the
ceiling, but overshooting just wastes gas — size it yourself:

```
maxFlash ≈ initialAmount × LLTV / (1 − LLTV)   (at oracle price)
```

Always stay **below** that with a safety margin so a small oracle move or borrow spike doesn't liquidate you.

Worked example — $10,000 initial, market LLTV = 0.915:
- theoretical max flash ≈ 10,000 × 0.915/0.085 ≈ **$107,600**
- use ~**$80–90k** (≈ 9–10× total exposure) to leave liquidation headroom.

Also bounded by the flash source's available liquidity (Morpho idle loanToken / Aave pool
cash / Euler debt-vault cash).

---

### Slippage params (required)

- `minPtBps` — min PT out per mint-token in, in bps. `9950` = 0.5% tolerance. Must be `> 0`.
- `minOut` — floor on tokens returned to you after full debt + flash settlement on close.
  **`close()` reverts on `minOut == 0`** — always set a real floor (expected return minus
  your slippage budget).

---

### Pre-expiry close REQUIRES the YT

`open()` sends the YT to your wallet. To `close()` **before maturity**, you must still hold
that YT (>= your PT collateral) and approve it to your looper — par redemption needs PT+YT.

**If you sold the YT** (e.g. to take the yield upfront), you **cannot par-close pre-expiry.**
Your options: (1) rebuy the YT, (2) wait for maturity (post-expiry needs only PT), or
(3) use `execute()` to sell the PT on Pendle and unwind manually. `close()` now fails fast
with a clear message instead of reverting deep in the flash callback.

---

### Test before you deploy (do ALL of this with real money on the line)

> **Most important nuance:** these contracts integrate live Pendle markets + Morpho/Aave/
> Euler. Those protocols and their markets **only exist on mainnet** — a fresh testnet has no
> PT markets to mint, no Morpho market to borrow from. So **mainnet-fork testing is the real
> test here, not testnet deployment.** Fork the actual chain, run against the actual
> contracts and a real, live PT market.

#### 1. Foundry mainnet-fork test (the gold standard)

Forks the target chain at a recent block and exercises a full open→close round trip against
the *real* Pendle router, Morpho/Aave/Euler, and a live PT market. Catches the integration
bugs unit tests never will.

```solidity
// test/MorphoLooper.fork.t.sol
// run: forge test --fork-url $ETH_RPC_URL --fork-block-number <recent> -vvvv --match-test
import "forge-std/Test.sol";
import "../MorphoPTLooper.sol";

contract MorphoLooperForkTest is Test {
    // fill from the verified address table + the live market you'll actually use
    address constant MORPHO = 0x...;          // Morpho Blue
    address constant PENDLE_ROUTER = 0x...;   // Pendle Router V4
    address constant LOAN = 0x...;            // e.g. USDC
    address constant YT = 0x...;              // the YT of the live PT market
    MarketParams mp;                          // the EXACT canonical Morpho market tuple

    MorphoUserPTLooper looper;
    address user = address(0xBEEF);

    function setUp() public {
        mp = MarketParams({loanToken: LOAN, collateralToken: 0x.../*PT*/,
                           oracle: 0x..., irm: 0x..., lltv: 915000000000000000});
        vm.startPrank(user);
        looper = MorphoPTLooperFactory(/*deploy or address*/).createLooper();
        vm.stopPrank();
    }

    function test_open_then_close_roundtrip() public {
        uint256 initial = 10_000e6;             // $10k USDC
        uint256 flash   = 90_000e6;             // ~9x — below LTV/(1-LTV) bound
        deal(LOAN, user, initial);

        vm.startPrank(user);
        IERC20(LOAN).approve(address(looper), initial);
        looper.open(mp, YT, initial, flash, 9950);   // 0.5% mint tolerance

        // assertions: position opened at target leverage
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collat) = IMorpho(MORPHO).position(id, address(looper));
        assertGt(collat, 0, "no collateral");
        assertGt(borrowShares, 0, "no debt");
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered to EOA");

        // close requires the YT pre-expiry — user still holds it here
        IERC20(YT).approve(address(looper), type(uint256).max);
        looper.close(mp, YT, 1);                // minOut=1 in test; use a real floor live

        (, , uint128 collatAfter) = IMorpho(MORPHO).position(id, address(looper));
        assertEq(collatAfter, 0, "position not fully closed");
        assertGt(IERC20(LOAN).balanceOf(user), 0, "nothing returned");
        vm.stopPrank();
    }

    // negative tests that MUST revert:
    function test_overleverage_reverts() public { /* flash beyond LTV/(1-LTV) -> health revert */ }
    function test_close_without_YT_reverts_preExpiry() public { /* sell YT, expect fail-fast */ }
    function test_wrong_market_triplet_reverts() public { /* mismatched mp/yt -> _validate revert */ }
    function test_minOut_zero_reverts() public { /* close(minOut=0) -> "minOut required" */ }
}
```

Run it: `forge test --fork-url $ETH_RPC_URL -vvvv`. Repeat per chain and per looper
(swap in the Aave/Euler addresses + constructor). For Euler, also fork-test a **wrapped**
debt-asset market and confirm the wrapper's deposit AND redeem are both open.

#### 2. Tenderly - dry-run the EXACT transaction before sending it

Fork tests prove the code; Tenderly proves *your specific call with your specific params*
won't revert before you spend real gas/funds:

- **Tenderly Virtual TestNet** (or a fork): deploy the factory, `createLooper()`, then
  **simulate** the actual `open(...)` call you intend to send. Inspect the full call trace,
  every token transfer, the final Morpho/Euler health state, and any revert reason — all
  before broadcasting.
- For a one-off check, paste the unsigned tx into Tenderly's **Simulator** against a recent
  block; it shows the decoded trace and the exact failure point if it would revert.
- Keep a saved simulation for each market you go live on — re-simulate after any param
  change (new maturity, new market, resized flash).

#### 3. Testnet (optional, limited use)

Deploy the factory to **Base Sepolia** only to rehearse the *deploy + createLooper + approve*
mechanics and your scripts — **not** the loop itself (no live PT/Morpho markets there). The
real correctness signal is the mainnet fork + Tenderly simulation above.

#### Pre-mainnet checklist

- [ ] `forge test --fork-url` green: open/close round trip on a live market, per looper, per chain
- [ ] Negative tests revert: over-leverage, no-YT pre-expiry close, wrong triplet, minOut=0
- [ ] Euler: wrapped-debt market fork-tested (deposit + redeem both open)
- [ ] Tenderly simulation of your exact `open()` (and `close()`) passes with real params
- [ ] Every address in your deploy reconciled against the official source AND the explorer
- [ ] Independent review / audit of the diff + a bug bounty before scaling past $500

---

### Deploy & use runbook

1. Set `foundry.toml` as above. `forge build`.
2. `forge create` the **factory** with the verified per-chain addresses. Verify on the explorer.
3. Call `createLooper()` → returns YOUR personal looper (owner = you, immutable).
4. `approve` the mint token (loanToken / Euler mint token) to your looper.
5. `open(...)` with the canonical market params, your `yt`, `initialAmount`, sized
   `flashAmount`, and `minPtBps`.
6. Monitor health on the money market's own UI (Morpho/Euler). This contract does not
   manage liquidation risk for you — the underlying protocol does.
7. `close(..., minOut)` while holding the YT (pre-expiry) or any time post-expiry.

---

### Security model (what protects you, and what doesn't)

- **Per-user isolation:** each looper has one immutable owner. A bug in one user's looper
  cannot touch another's funds. `execute()`/`sweep()` are owner-only and only move your own.
- **Flash-callback guards:** every callback checks the real lender as `msg.sender` AND an
  in-flight flag; the Aave path additionally requires `initiator == address(this)`
  (load-bearing — do not remove).
- **Reentrancy:** the `lock` (1→2) plus the in-flight check block re-entry into open/close.
- **What it does NOT protect:** market/credit/oracle risk of the underlying assets, your own
  leverage choices, and liquidation. It is plumbing, not a risk manager. Leverage liquidates.
