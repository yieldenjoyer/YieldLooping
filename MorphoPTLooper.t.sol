// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * Mainnet-fork integration test for MorphoPTLooper (v2).
 *
 * Uses the LIVE Pendle Router, Morpho Blue, and a real PT market — fork mainnet:
 *   forge test --fork-url $ETH_RPC_URL -vvvv --match-contract MorphoPTLooperForkTest
 *
 * NOTE: every test uses vm.startPrank(user, user) — the second arg sets tx.origin so the
 * onlyEOA gate passes. Single-arg prank() would revert with "EOA only".
 *
 * Fill the CONFIG block with a real market before running.
 */
import "forge-std/Test.sol";
import "../MorphoPTLooper.sol";

contract Caller {
    // helper used to prove a CONTRACT (msg.sender != tx.origin) is rejected
    function tryCreate(MorphoPTLooperFactory f) external returns (address) {
        return f.createLooper();
    }
}

contract MorphoPTLooperForkTest is Test {
    // ----------------------------- CONFIG (edit me) -----------------------------
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant MORPHO = address(0); // Morpho Blue singleton
    address constant LOAN   = address(0); // loanToken (e.g. USDC)
    address constant PT     = address(0); // market's Pendle PT (collateralToken)
    address constant YT     = address(0); // matching Pendle YT
    address constant ORACLE = address(0);
    address constant IRM    = address(0);
    uint256 constant LLTV   = 915000000000000000; // copy from the real market
    uint256 constant INITIAL = 10_000e6;
    uint256 constant FLASH   = 90_000e6;  // see README: bound by LLTV*ptPrice, not just LLTV
    uint256 constant MIN_PT_OUT = 1;      // mechanics test only; in prod pass a real PT floor
    // ----------------------------------------------------------------------------
    MarketParams mp;
    MorphoUserPTLooper looper;
    MorphoPTLooperFactory factory;
    address user = makeAddr("user");

    function setUp() public {
        require(MORPHO != address(0) && LOAN != address(0) && YT != address(0),
                "fill CONFIG with a live market before running");
        mp = MarketParams({loanToken: LOAN, collateralToken: PT, oracle: ORACLE, irm: IRM, lltv: LLTV});
        factory = new MorphoPTLooperFactory(MORPHO, PENDLE_ROUTER);
        vm.prank(user, user); // tx.origin == msg.sender for the EOA gate
        looper = MorphoUserPTLooper(payable(factory.createLooper()));
    }

    function _id() internal view returns (bytes32) { return keccak256(abi.encode(mp)); }

    function test_open_then_close_roundtrip() public {
        deal(LOAN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        looper.open(mp, YT, INITIAL, FLASH, MIN_PT_OUT);
        (, uint128 borrowShares, uint128 collat) = IMorpho(MORPHO).position(_id(), address(looper));
        assertGt(collat, 0, "no collateral");
        assertGt(borrowShares, 0, "no debt");
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered to EOA");
        IERC20(YT).approve(address(looper), type(uint256).max);
        uint256 before = IERC20(LOAN).balanceOf(user);
        looper.close(mp, YT, 1);
        (, , uint128 collatAfter) = IMorpho(MORPHO).position(_id(), address(looper));
        assertEq(collatAfter, 0, "position not fully closed");
        assertGt(IERC20(LOAN).balanceOf(user), before, "nothing returned");
        vm.stopPrank();
    }

    function test_overleverage_reverts() public {
        deal(LOAN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        vm.expectRevert();
        looper.open(mp, YT, INITIAL, INITIAL * 50, MIN_PT_OUT);
        vm.stopPrank();
    }

    /// v2: absolute minPtOut floor actually bites now.
    function test_open_slippage_reverts() public {
        deal(LOAN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        vm.expectRevert(); // Pendle reverts: minPyOut not met
        looper.open(mp, YT, INITIAL, FLASH, type(uint256).max);
        vm.stopPrank();
    }

    function test_close_minOut_zero_reverts() public {
        vm.prank(user, user);
        vm.expectRevert(bytes("minOut required"));
        looper.close(mp, YT, 0);
    }

    function test_wrong_triplet_reverts() public {
        MarketParams memory bad = mp;
        bad.collateralToken = address(0xdead);
        deal(LOAN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(LOAN).approve(address(looper), INITIAL);
        vm.expectRevert(bytes("market PT != yt PT"));
        looper.open(bad, YT, INITIAL, FLASH, MIN_PT_OUT);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        vm.prank(address(0xBEEF), address(0xBEEF));
        vm.expectRevert(bytes("not owner"));
        looper.open(mp, YT, INITIAL, FLASH, MIN_PT_OUT);
    }

    /// EOA gate: a contract caller cannot deploy a looper.
    function test_factory_rejects_contract_caller() public {
        Caller c = new Caller();
        vm.expectRevert(bytes("EOA only"));
        c.tryCreate(factory);
    }
}
