// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * Mainnet-fork integration test for EulerPTLooper (v2).
 *   forge test --fork-url $ETH_RPC_URL -vvvv --match-contract EulerPTLooperForkTest
 *
 * Euler uses NO external flash — it borrows inside an EVC batch with deferred health checks.
 * Fill CONFIG with a real Euler PT market (collateral vault + debt vault + the YT).
 * If the debt asset is a 4626 wrapper of the mint token, set WRAPPER; else address(0).
 */
import "forge-std/Test.sol";
import "../EulerPTLooper.sol";

contract EulerCaller {
    function tryCreate(EulerPTLooperFactory f) external returns (address) { return f.createLooper(); }
}

contract EulerPTLooperForkTest is Test {
    // ----------------------------- CONFIG (edit me) -----------------------------
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant EVC = address(0);              // Euler Vault Connector
    address constant COLLATERAL_VAULT = address(0); // eVault whose asset() == yt.PT()
    address constant DEBT_VAULT = address(0);       // eVault to borrow from (the controller)
    address constant WRAPPER = address(0);          // 4626 wrapper, or address(0)
    address constant MINT_TOKEN = address(0);       // token you deposit (== debt asset if WRAPPER==0)
    address constant YT = address(0);
    uint256 constant INITIAL = 10_000e18;
    uint256 constant BORROW  = 70_000e18;           // debt-asset units; bound by LTV and vault cash
    uint256 constant MIN_PT_OUT = 1;
    // ----------------------------------------------------------------------------
    EulerUserPTLooper looper;
    EulerPTLooperFactory factory;
    address user = makeAddr("user");

    function setUp() public {
        require(EVC != address(0) && COLLATERAL_VAULT != address(0) && DEBT_VAULT != address(0) && YT != address(0),
                "fill CONFIG with a live Euler market before running");
        factory = new EulerPTLooperFactory(EVC, PENDLE_ROUTER);
        vm.prank(user, user);
        looper = EulerUserPTLooper(payable(factory.createLooper()));
    }

    function test_open_then_close_roundtrip() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, BORROW, MIN_PT_OUT);
        (uint256 ptShares, uint256 debt,) = looper.getPosition(COLLATERAL_VAULT, DEBT_VAULT, YT);
        assertGt(ptShares, 0, "no collateral");
        assertGt(debt, 0, "no debt");
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered");
        IERC20(YT).approve(address(looper), type(uint256).max);
        uint256 before = IERC20(MINT_TOKEN).balanceOf(user);
        looper.close(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, 1);
        (uint256 ptAfter, uint256 debtAfter,) = looper.getPosition(COLLATERAL_VAULT, DEBT_VAULT, YT);
        assertEq(ptAfter, 0, "collateral not withdrawn");
        assertEq(debtAfter, 0, "debt not repaid");
        assertGt(IERC20(MINT_TOKEN).balanceOf(user), before, "nothing returned");
        vm.stopPrank();
    }

    /// Controller must be released after close so a different market can be opened.
    function test_unlevered_close_releases_controller() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, 0, MIN_PT_OUT); // unlevered
        IERC20(YT).approve(address(looper), type(uint256).max);
        looper.close(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, 1);
        // Re-opening the same market must succeed -> controller was released (M3 fix).
        deal(MINT_TOKEN, user, INITIAL);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, 0, MIN_PT_OUT);
        vm.stopPrank();
    }

    function test_overleverage_reverts() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        vm.expectRevert();
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, INITIAL * 50, MIN_PT_OUT);
        vm.stopPrank();
    }

    function test_close_minOut_zero_reverts() public {
        vm.prank(user, user);
        vm.expectRevert(bytes("minOut required"));
        looper.close(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, 0);
    }

    function test_wrong_collateral_vault_reverts() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        vm.expectRevert(bytes("collateral vault asset != yt PT"));
        looper.open(DEBT_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, BORROW, MIN_PT_OUT); // wrong collateral vault
        vm.stopPrank();
    }

    function test_factory_rejects_contract_caller() public {
        EulerCaller c = new EulerCaller();
        vm.expectRevert(bytes("EOA only"));
        c.tryCreate(factory);
    }
}
