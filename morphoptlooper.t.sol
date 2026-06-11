// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * Mainnet-fork integration test for MorphoPTLooper.
 *
 * this contract integrates the LIVE Pendle Router, Morpho Blue,
 * and a real PT market. Those exist only on mainnet. A fresh testnet has no PT to mint and
 * no Morpho market to borrow from. Fork the real chain at a recent block and run against the
 * real protocols.
 *
 * SETUP — fill the CONFIG block with a live market you actually intend to use, then:
 *   forge test --fork-url $ETH_RPC_URL -vvvv --match-contract MorphoPTLooperForkTest
 *
 * All addresses below are placeholders EXCEPT the PendleRouterv4 (same on every chain).
 * Pull the rest from the official sources and confirm each on the explorer.
 */

import "forge-std/Test.sol";
import "../MorphoPTLooper.sol";

contract MorphoPTLooperForkTest is Test {
    // ----------------------------- CONFIG (edit me) -----------------------------
    // Pendle Router V4 — same address on every chain (CREATE2 vanity deploy).
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    // Fill from the verified address table + the live market you'll use:
    address constant MORPHO = address(0); // Morpho Blue singleton
    address constant LOAN   = address(0); // loanToken you flash + borrow (e.g. USDC)
    address constant PT     = address(0); // the market's Pendle PT (collateralToken)
    address constant YT     = address(0); // the matching Pendle YT (PT/SY derived from it)
    address constant ORACLE = address(0);
    address constant IRM    = address(0);
    uint256 constant LLTV   = 915000000000000000; // 0.915e18 — copy from the real market

    uint256 constant INITIAL = 10_000e6; // your capital (adjust decimals to LOAN)
    uint256 constant FLASH   = 90_000e6; // leverage; keep below INITIAL*LLTV/(1-LLTV)
    uint256 constant MIN_PT_BPS = 9950;  // 0.5% mint tolerance
    // ----------------------------------------------------------------------------

    MarketParams mp;
    MorphoUserPTLooper looper;
    address user = makeAddr("user");

    function setUp() public {
        require(MORPHO != address(0) && LOAN != address(0) && YT != address(0),
                "fill CONFIG with a live market before running");
        mp = MarketParams({
            loanToken: LOAN, collateralToken: PT,
            oracle: ORACLE, irm: IRM, lltv: LLTV
        });
        MorphoPTLooperFactory factory = new MorphoPTLooperFactory(MORPHO, PENDLE_ROUTER);
        vm.prank(user);
        looper = MorphoUserPTLooper(payable(factory.createLooper()));
    }

    function _bytes32Id() internal view returns (bytes32) {
        return keccak256(abi.encode(mp));
    }

    /// Full open -> close round trip on a live market.
    function test_open_then_close_roundtrip() public {
        deal(LOAN, user, INITIAL);

        vm.startPrank(user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        looper.open(mp, YT, INITIAL, FLASH, MIN_PT_BPS);

        (, uint128 borrowShares, uint128 collat) =
            IMorpho(MORPHO).position(_bytes32Id(), address(looper));
        assertGt(collat, 0, "no collateral supplied");
        assertGt(borrowShares, 0, "no debt taken");
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered to EOA");

        // Pre-expiry close needs the YT back, approved to the looper.
        IERC20(YT).approve(address(looper), type(uint256).max);
        uint256 before = IERC20(LOAN).balanceOf(user);
        looper.close(mp, YT, 1); // minOut=1 in test only; use a real floor in production

        (, , uint128 collatAfter) = IMorpho(MORPHO).position(_bytes32Id(), address(looper));
        assertEq(collatAfter, 0, "position not fully closed");
        assertGt(IERC20(LOAN).balanceOf(user), before, "nothing returned to user");
        vm.stopPrank();
    }

    /// Over-leverage must revert atomically (health check) — funds never at risk.
    function test_overleverage_reverts() public {
        deal(LOAN, user, INITIAL);
        vm.startPrank(user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        uint256 tooMuch = INITIAL * 50; // far beyond LLTV/(1-LLTV)
        vm.expectRevert();
        looper.open(mp, YT, INITIAL, tooMuch, MIN_PT_BPS);
        vm.stopPrank();
    }

    /// minOut == 0 is rejected up front.
    function test_close_minOut_zero_reverts() public {
        vm.prank(user);
        vm.expectRevert(bytes("minOut required"));
        looper.close(mp, YT, 0);
    }

    /// Mismatched market/YT triplet reverts in _validate before any state change.
    function test_wrong_triplet_reverts() public {
        MarketParams memory bad = mp;
        bad.collateralToken = address(0xdead); // != IYT(yt).PT()
        deal(LOAN, user, INITIAL);
        vm.startPrank(user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        vm.expectRevert(bytes("market PT != yt PT"));
        looper.open(bad, YT, INITIAL, FLASH, MIN_PT_BPS);
        vm.stopPrank();
    }

    /// Only the owner can open/close/execute their looper.
    function test_onlyOwner() public {
        vm.expectRevert(bytes("not owner"));
        looper.open(mp, YT, INITIAL, FLASH, MIN_PT_BPS);
    }
}
