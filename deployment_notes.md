
> **Unaudited beta.** Flash-loan leverage code. Treat every deployment as beta until an
> audit report is linked here. Test on a fork and on testnet with real flows first and always; start
> mainnet with a tiny size ($50-$500, not your full stack). Nothing here is "100% safe." 
> **so dont assume so until you've tested with a fork/foundry/tenderly and everything compiles and works as intended.**

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
> address in a money contract is a total loss bug. Pull from each from the protocol's **official**
> docs/address book and confirm on the chain explorer before deploying. I.E. Pendles v4 (or current) router for example with the proper SY/YT/PT addresses

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
- Pendle Router V4: [https://docs.pendle.finance/Developers/Contracts/Addresses](https://docs.pendle.finance/pendle-v2-dev/PendleRouter/ApiReference/YtFunctions#swapexacttokenforyt)
- Morpho Blue: [https://docs.morpho.org/getting-started/resources/addresses](https://docs.morpho.org/get-started/resources/addresses#addresses)
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
ceiling, but overshooting just wastes gas — size it yourself and check the vault has suffucient liquidity.

```
maxFlash ≈ initialAmount × LLTV / (1 − LLTV)   (at oracle price)
```

Always stay **below** that with a safety margin so a small oracle move doesn't liquidate you.

Worked example — $10,000 initial, market LLTV = 0.915:
- theoretical max flash ≈ 10,000 × 0.915/0.085 ≈ **$107,600**
- use ~**$80–90k** (≈ 9–10× total exposure) to leave liquidation headroom.

Also bounded by the flash source's available liquidity (Morpho idle loanToken / Aave pool
cash / Euler debt-vault cash).

---

### Slippage params (now required)

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
- **So be aware of the risks at all times**
