// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * Mainnet-fork test for the EulerPTLooper 4626-WRAPPED DEBT ASSET path.
 *
 *   forge test --fork-url $ETH_RPC_URL -vvvv --match-contract EulerWrappedDebtForkTest
 *
 * This is the path the v2 event-underflow bug lived in (debt asset and mint token are
 * different units), and the least-covered one. Use a real Euler market where:
 *     debtVault.asset() == WRAPPER            (a 4626 token, e.g. a wrapped USDe vault)
 *     IERC4626(WRAPPER).asset() == MINT_TOKEN (the Pendle mint token, e.g. USDe)
 * The looper borrows the wrapper, unwraps to the mint token to mint PT, and on close
 * wraps back to repay. Both wrapper directions (deposit AND redeem) must be open.
 *
 * setUp() asserts the CONFIG really is a wrapped market, so a wrong address fails fast.
 */
import "forge-std/Test.sol";
import "../EulerPTLooper.sol";

contract EulerWrappedDebtForkTest is Test {
    // ----------------------------- CONFIG (edit me) -----------------------------
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant EVC = address(0);              // Euler Vault Connector
    address constant COLLATERAL_VAULT = address(0); // eVault whose asset() == yt.PT()
    address constant DEBT_VAULT = address(0);       // eVault whose asset() == WRAPPER
    address constant WRAPPER = address(0);          // the 4626 debt asset (wraps MINT_TOKEN)
    address constant MINT_TOKEN = address(0);       // WRAPPER.asset() — what you deposit & mint PT from
    address constant YT = address(0);
    uint256 constant INITIAL = 10_000e18;
    uint256 constant BORROW  = 60_000e18;           // in WRAPPER (debt-asset) units; leave LTV headroom
    uint256 constant MIN_PT_OUT = 1;                // mechanics only; pass a real PT floor in prod
    // ----------------------------------------------------------------------------
    EulerUserPTLooper looper;
    EulerPTLooperFactory factory;
    address user = makeAddr("user");

    function setUp() public {
        require(
            EVC != address(0) && COLLATERAL_VAULT != address(0) && DEBT_VAULT != address(0)
                && WRAPPER != address(0) && MINT_TOKEN != address(0) && YT != address(0),
            "fill CONFIG (wrapped market) before running"
        );
        // Prove the CONFIG is actually a wrapped-debt market.
        require(IEVault(DEBT_VAULT).asset() == WRAPPER, "DEBT_VAULT.asset() must be WRAPPER");
        require(IERC4626(WRAPPER).asset() == MINT_TOKEN, "WRAPPER.asset() must be MINT_TOKEN");
        require(IEVault(COLLATERAL_VAULT).asset() == IYT(YT).PT(), "COLLATERAL_VAULT.asset() must be yt.PT()");

        factory = new EulerPTLooperFactory(EVC, PENDLE_ROUTER);
        vm.prank(user, user);
        looper = EulerUserPTLooper(payable(factory.createLooper()));
    }

    /// Preflight the README requirement: both wrapper directions must be open.
    function test_wrapper_both_directions_open() public {
        deal(MINT_TOKEN, address(this), 1e18);
        IERC20(MINT_TOKEN).approve(WRAPPER, type(uint256).max);
        uint256 shares = IERC4626(WRAPPER).deposit(1e18, address(this));
        assertGt(shares, 0, "wrapper deposit is closed");
        uint256 assets = IERC4626(WRAPPER).redeem(shares, address(this), address(this));
        assertGt(assets, 0, "wrapper redeem is closed");
    }

    /// Full levered open -> close through the wrapper. A clean open() here is the
    /// regression check for the Opened-event cross-unit underflow.
    function test_wrapped_roundtrip() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);

        // OPEN — must not revert (the bug reverted here on wrapped markets).
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, BORROW, MIN_PT_OUT);

        (uint256 ptShares, uint256 debt,) = looper.getPosition(COLLATERAL_VAULT, DEBT_VAULT, YT);
        assertGt(ptShares, 0, "no collateral");
        assertGt(debt, 0, "no debt");
        assertGt(IERC20(YT).balanceOf(user), 0, "YT not delivered to EOA");

        // CLOSE — wrap mint token back, repay, release controller, return mint token.
        IERC20(YT).approve(address(looper), type(uint256).max);
        uint256 beforeBal = IERC20(MINT_TOKEN).balanceOf(user);
        looper.close(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, 1);

        (uint256 ptAfter, uint256 debtAfter,) = looper.getPosition(COLLATERAL_VAULT, DEBT_VAULT, YT);
        assertEq(ptAfter, 0, "collateral not withdrawn");
        assertEq(debtAfter, 0, "debt not repaid");
        assertGt(IERC20(MINT_TOKEN).balanceOf(user), beforeBal, "user got no mint token back");

        // No funds stranded on the looper: mint token swept to user, wrapper fully unwound.
        assertEq(IERC20(MINT_TOKEN).balanceOf(address(looper)), 0, "stuck mint token");
        assertEq(IERC20(WRAPPER).balanceOf(address(looper)), 0, "stuck wrapper/debt asset");

        // Controller released by close -> the same market can be opened again.
        deal(MINT_TOKEN, user, INITIAL);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, BORROW, MIN_PT_OUT);
        vm.stopPrank();
    }

    /// Unlevered wrapped open/close (borrow == 0): no debt, no wrap, controller still released.
    function test_wrapped_unlevered_roundtrip() public {
        deal(MINT_TOKEN, user, INITIAL);
        vm.startPrank(user, user);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, 0, MIN_PT_OUT);
        (, uint256 debt,) = looper.getPosition(COLLATERAL_VAULT, DEBT_VAULT, YT);
        assertEq(debt, 0, "should be no debt");
        IERC20(YT).approve(address(looper), type(uint256).max);
        looper.close(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, 1);
        // re-open proves the controller was released even with zero debt
        deal(MINT_TOKEN, user, INITIAL);
        IERC20(MINT_TOKEN).approve(address(looper), INITIAL);
        looper.open(COLLATERAL_VAULT, DEBT_VAULT, WRAPPER, YT, INITIAL, 0, MIN_PT_OUT);
        vm.stopPrank();
    }
}
