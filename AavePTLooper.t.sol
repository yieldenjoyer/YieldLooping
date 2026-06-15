// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * Mainnet-fork integration test for AavePTLooper (v2). Requires viaIR (foundry.toml sets it).
 *   forge test --fork-url $ETH_RPC_URL -vvvv --match-contract AavePTLooperForkTest
 * Flash liquidity from Aave V3 (5 bps premium). Fill CONFIG with a real market.
 */
import "forge-std/Test.sol";
import "../AavePTLooper.sol";

contract AaveCaller {
    function tryCreate(AavePTLooperFactory f) external returns (address) { return f.createLooper(); }
}

contract AavePTLooperForkTest is Test {
    // ----------------------------- CONFIG (edit me) -----------------------------
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant MORPHO = address(0);     // Morpho Blue singleton (the money market)
    address constant AAVE_POOL = address(0);  // Aave V3 Pool (the flash source)
    address constant LOAN   = address(0);     // loanToken, flashable on Aave (e.g. USDC)
    address constant PT     = address(0);
    address constant YT     = address(0);
    address constant ORACLE = address(0);
    address constant IRM    = address(0);
    uint256 constant LLTV   = 915000000000000000;
    uint256 constant INITIAL = 10_000e6;
    uint256 constant FLASH   = 80_000e6;   // leave headroom for the 5 bps premium financed as debt
    uint256 constant MIN_PT_OUT = 1;
    // ----------------------------------------------------------------------------
    MarketParams mp;
    AaveUserPTLooper looper;
    AavePTLooperFactory factory;
    address user = makeAddr("user");

    function setUp() public {
        require(MORPHO != address(0) && AAVE_POOL != address(0) && LOAN != address(0) && YT != address(0),
                "fill CONFIG with a live market before running");
        mp = MarketParams({loanToken: LOAN, collateralToken: PT, oracle: ORACLE, irm: IRM, lltv: LLTV});
        factory = new AavePTLooperFactory(MORPHO, AAVE_POOL, PENDLE_ROUTER);
        vm.prank(user, user);
        looper = AaveUserPTLooper(payable(factory.createLooper()));
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
        // debt should be flash + premium (premium financed as Morpho debt)
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered");
        IERC20(YT).approve(address(looper), type(uint256).max);
        uint256 before = IERC20(LOAN).balanceOf(user);
        looper.close(mp, YT, 1);
        (, , uint128 collatAfter) = IMorpho(MORPHO).position(_id(), address(looper));
        assertEq(collatAfter, 0, "not fully closed");
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

    function test_factory_rejects_contract_caller() public {
        AaveCaller c = new AaveCaller();
        vm.expectRevert(bytes("EOA only"));
        c.tryCreate(factory);
    }
}
