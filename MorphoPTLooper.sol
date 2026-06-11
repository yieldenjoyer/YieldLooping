// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MorphoPTLooper — universal self-custodial leveraged Pendle PT on Morpho Blue
 * @notice ANY Pendle PT market + ANY matching Morpho Blue market, chosen per call.
 *         Each user deploys their OWN looper once per chain via the factory; after that
 *         every open()/close() takes the market as a parameter. One looper can hold
 *         positions in many markets simultaneously (Morpho positions are per-market).
 *
 *         HARDENING (this revision):
 *         - SafeERC20 for every token op: tolerates no-return tokens (USDT) and
 *           reverts on false. forceApprove() resets allowance to 0 first, so repeat
 *           opens on USDT-style markets don't revert and no approval is left dangling.
 *         - close() enforces minOut > 0 (no zero-slippage-floor exits).
 *         - close() fails fast if pre-expiry YT is missing, pointing you to execute()
 *           for a manual PT-sell exit rather than reverting confusingly mid-flash.
 *
 *         OPEN (one tx):  flash loanToken from Morpho (0 fee) -> mint PT+YT at par ->
 *                         supply PT to your own Morpho position -> borrow to repay flash.
 *         CLOSE (one tx): flash exact debt -> repay by shares -> withdraw all PT ->
 *                         redeem at par (return YT pre-expiry) -> repay flash -> rest to you.
 *         ESCAPE HATCH:   execute() lets the owner raw-call anything as their looper.
 *                         Recovery (incl. a manual PT-sell exit) never depends on this code.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @dev Minimal SafeERC20 — no external imports. Treats empty return as success
///      (USDT/BNB-style), reverts on explicit false, bubbles low-level reverts.
library SafeERC20 {
    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }

    /// @dev Reset to 0 then set — USDT reverts on approve(N) when allowance != 0,
    ///      and this guarantees no residual allowance is left after the op completes.
    function forceApprove(address token, address spender, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20.approve.selector, spender, uint256(0)));
        if (amount > 0) {
            _call(token, abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        }
    }

    function _call(address token, bytes memory data) private {
        require(token.code.length > 0, "not a contract");
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "ERC20 op failed");
    }
}

// ==================== MORPHO BLUE ====================

struct MarketParams {
    address loanToken;
    address collateralToken; // PT
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function supplyCollateral(MarketParams calldata mp, uint256 assets, address onBehalf, bytes calldata data) external;
    function withdrawCollateral(MarketParams calldata mp, uint256 assets, address onBehalf, address receiver) external;
    function borrow(MarketParams calldata mp, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams calldata mp, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function position(bytes32 id, address user)
        external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id)
        external view returns (
            uint128 totalSupplyAssets, uint128 totalSupplyShares,
            uint128 totalBorrowAssets, uint128 totalBorrowShares,
            uint128 lastUpdate, uint128 fee
        );
    function accrueInterest(MarketParams calldata mp) external;
}

// ==================== PENDLE ====================

enum SwapType { NONE, KYBERSWAP, ONE_INCH, ETH_WETH }

struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address bulk;
    address pendleSwap;
    SwapData swapData;
}

interface IPendleRouterV4 {
    function mintPyFromToken(address receiver, address YT, uint256 minPyOut, TokenInput calldata input)
        external payable returns (uint256 netPyOut);
    function redeemPyToSy(address receiver, address YT, uint256 netPyIn, uint256 minSyOut)
        external returns (uint256 netSyOut);
}

interface ISYToken {
    function redeem(address receiver, uint256 shares, address tokenOut, uint256 minTokenOut, bool burnFromInternalBalance)
        external returns (uint256 amountTokenOut);
    function isValidTokenIn(address token) external view returns (bool);
    function isValidTokenOut(address token) external view returns (bool);
}

interface IYT {
    function PT() external view returns (address);
    function SY() external view returns (address);
    function isExpired() external view returns (bool);
}

// ==================== USER LOOPER ====================

contract MorphoUserPTLooper {
    using SafeERC20 for address;

    uint8 private constant ACTION_OPEN = 1;
    uint8 private constant ACTION_CLOSE = 2;

    IMorpho public immutable MORPHO;
    address public immutable PENDLE_ROUTER;
    address public immutable owner; // the user — set once by the factory, forever

    uint256 private unlocked = 1;   // 1 = idle, 2 = mid open/close (flash in flight)

    event Opened(bytes32 indexed marketId, uint256 ownCapital, uint256 flashAssets, uint256 ptSupplied);
    event Closed(bytes32 indexed marketId, uint256 debtRepaid, uint256 ptWithdrawn, uint256 loanTokenToUser);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier lock() {
        require(unlocked == 1, "reentrancy");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor(address _owner, address _morpho, address _pendleRouter) {
        require(_owner != address(0) && _morpho != address(0) && _pendleRouter != address(0), "bad address");
        owner = _owner;
        MORPHO = IMorpho(_morpho);
        PENDLE_ROUTER = _pendleRouter;
    }

    // ==================== MARKET VALIDATION ====================

    /// @dev Derives PT/SY from the YT and proves the triplet is consistent.
    ///      A wrong yt or mp reverts here — funds cannot be misrouted by bad params.
    function _validate(MarketParams calldata mp, address yt) internal view returns (address pt, address sy) {
        pt = IYT(yt).PT();
        sy = IYT(yt).SY();
        require(mp.collateralToken == pt, "market PT != yt PT");
        require(ISYToken(sy).isValidTokenIn(mp.loanToken), "SY cannot mint from loanToken");
        require(ISYToken(sy).isValidTokenOut(mp.loanToken), "SY cannot redeem to loanToken");
    }

    // ==================== OPEN ====================

    function open(
        MarketParams calldata mp,
        address yt,
        uint256 initialAmount,
        uint256 flashAmount,
        uint256 minPtBps
    ) external onlyOwner lock {
        require(initialAmount > 0, "no capital");
        require(minPtBps > 0 && minPtBps <= 10_000, "bad bps");
        require(!IYT(yt).isExpired(), "market expired");
        _validate(mp, yt);
        mp.loanToken.safeTransferFrom(msg.sender, address(this), initialAmount);

        if (flashAmount == 0) {
            _openInner(mp, yt, 0, minPtBps); // unlevered: mint + supply only
        } else {
            MORPHO.flashLoan(mp.loanToken, flashAmount, abi.encode(ACTION_OPEN, mp, yt, minPtBps));
        }
    }

    // ==================== CLOSE ====================

    /**
     * @notice Full par-redemption close. Pre-expiry REQUIRES your YT balance >= PT
     *         collateral, approved to this contract. If you sold the YT, par close is
     *         impossible — use execute() to sell PT on Pendle and unwind manually.
     * @param minOut floor on loanToken returned to you after debt + flash settlement (> 0)
     */
    function close(MarketParams calldata mp, address yt, uint256 minOut) external onlyOwner lock {
        require(minOut > 0, "minOut required");
        _validate(mp, yt);
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));
        require(collateral > 0, "no position");

        // Fail fast, before any flash/state change, if the par-redemption precondition
        // (holding the YT pre-expiry) isn't met — clearer than reverting mid-flash.
        if (!IYT(yt).isExpired()) {
            address ytAddr = yt;
            require(
                IERC20(ytAddr).balanceOf(owner) >= collateral,
                "pre-expiry close needs YT: rebuy YT or use execute() to sell PT"
            );
        }

        if (borrowShares == 0) {
            _closeInner(mp, yt, 0, minOut); // no debt: withdraw + redeem only
        } else {
            uint256 debt = _debtAssets(mp, id, borrowShares); // accrues first — exact this block
            MORPHO.flashLoan(mp.loanToken, debt, abi.encode(ACTION_CLOSE, mp, yt, minOut));
        }
    }

    // ==================== FLASH CALLBACK ====================

    /// @dev Morpho only ever calls back the flash initiator, which is this contract,
    ///      so `data` is always our own encoding from open()/close().
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(MORPHO), "only Morpho");
        require(unlocked == 2, "not in flight");

        (uint8 action, MarketParams memory mp, address yt, uint256 param) =
            abi.decode(data, (uint8, MarketParams, address, uint256));

        if (action == ACTION_OPEN) {
            _openInner(mp, yt, assets, param);
        } else if (action == ACTION_CLOSE) {
            _closeInner(mp, yt, assets, param);
        } else {
            revert("bad action");
        }

        mp.loanToken.forceApprove(address(MORPHO), assets); // repayment pulled after return
    }

    // ==================== INTERNALS ====================

    function _openInner(MarketParams memory mp, address yt, uint256 flashAssets, uint256 minPtBps) internal {
        address pt = IYT(yt).PT();
        uint256 mintAmount = IERC20(mp.loanToken).balanceOf(address(this)); // own capital + flash

        // loanToken -> PT+YT at par (1:1 pair), never priced through an AMM
        mp.loanToken.forceApprove(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            yt,
            (mintAmount * minPtBps) / 10_000,
            TokenInput(
                mp.loanToken, mintAmount, mp.loanToken,
                address(0), address(0), SwapData(SwapType.NONE, address(0), "", false)
            )
        );
        mp.loanToken.forceApprove(PENDLE_ROUTER, 0); // clear any residual mint allowance

        // Position belongs to THIS contract = this user. msg.sender == onBehalf,
        // which Morpho permits natively — no authorization exists anywhere.
        pt.forceApprove(address(MORPHO), py);
        MORPHO.supplyCollateral(mp, py, address(this), "");

        if (flashAssets > 0) {
            // Borrow exactly the flash repayment. Reverts here if over-leveraged ->
            // the whole transaction unwinds, nothing at risk but gas.
            MORPHO.borrow(mp, flashAssets, 0, address(this), address(this));
        }

        pt.forceApprove(address(MORPHO), 0); // no residual collateral allowance
        yt.safeTransfer(owner, py);           // yield/points leg straight to the user's wallet

        emit Opened(keccak256(abi.encode(mp)), mintAmount - flashAssets, flashAssets, py);
    }

    function _closeInner(MarketParams memory mp, address yt, uint256 flashAssets, uint256 minOut) internal {
        address pt = IYT(yt).PT();
        address sy = IYT(yt).SY();
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));

        // 1. Repay by SHARES — exact full repayment regardless of interest accrual.
        if (borrowShares > 0) {
            mp.loanToken.forceApprove(address(MORPHO), flashAssets);
            MORPHO.repay(mp, 0, borrowShares, address(this), "");
            mp.loanToken.forceApprove(address(MORPHO), 0);
        }

        // 2. Withdraw all PT (zero debt -> always healthy)
        MORPHO.withdrawCollateral(mp, collateral, address(this), address(this));

        // 3. PT(+YT pre-expiry) -> SY -> loanToken, at par regardless of PT market price.
        //    close() already guaranteed the owner holds the YT pre-expiry.
        uint256 pyIn = collateral;
        pt.forceApprove(PENDLE_ROUTER, pyIn);
        if (!IYT(yt).isExpired()) {
            yt.safeTransferFrom(owner, address(this), pyIn);
            yt.forceApprove(PENDLE_ROUTER, pyIn);
        }
        uint256 syOut = IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), yt, pyIn, 0);
        pt.forceApprove(PENDLE_ROUTER, 0);
        if (!IYT(yt).isExpired()) yt.forceApprove(PENDLE_ROUTER, 0);
        ISYToken(sy).redeem(address(this), syOut, mp.loanToken, 0, false);

        // 4. Settle flash (pulled after callback returns); remainder to the user.
        //    The aggregate minOut floor is the real slippage guard — close() forces it > 0.
        uint256 bal = IERC20(mp.loanToken).balanceOf(address(this));
        require(bal >= flashAssets, "redemption shortfall");
        uint256 toUser = bal - flashAssets;
        require(toUser >= minOut, "slippage");
        if (toUser > 0) mp.loanToken.safeTransfer(owner, toUser);

        emit Closed(id, flashAssets, collateral, toUser);
    }

    /// @dev Exact debt in assets for a share amount. Accrues interest first, so within
    ///      this transaction the result matches repay-by-shares to the wei (same formula,
    ///      same upward rounding as Morpho's SharesMathLib.toAssetsUp).
    function _debtAssets(MarketParams calldata mp, bytes32 id, uint128 borrowShares) internal returns (uint256) {
        MORPHO.accrueInterest(mp);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
        return _mulDivUp(uint256(borrowShares), uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    // ==================== VIEWS ====================

    function getPosition(MarketParams calldata mp) external view returns (
        uint256 ptCollateral,
        uint256 borrowShares,
        uint256 debtAssetsEstimate
    ) {
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 shares, uint128 collateral) = MORPHO.position(id, address(this));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
        ptCollateral = collateral;
        borrowShares = shares;
        debtAssetsEstimate = totalBorrowShares == 0 ? 0 : _mulDivUp(
            uint256(shares), uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6
        );
    }

    // ==================== FULL USER CONTROL ====================

    /// @notice Raw escape hatch: the owner can make this contract call ANYTHING.
    ///         Use this to sell PT on Pendle and unwind manually if you've sold the YT
    ///         and can't par-close. Funds safety depends on Morpho and Pendle, not this code.
    function execute(address target, uint256 value, bytes calldata data)
        external payable onlyOwner returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "execute failed");
        return ret;
    }

    function sweep(address token) external onlyOwner {
        token.safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    receive() external payable {}
}

// ==================== FACTORY (one per chain) ====================

contract MorphoPTLooperFactory {

    address public immutable MORPHO;
    address public immutable PENDLE_ROUTER;

    mapping(address => address[]) public loopersOf;

    event LooperDeployed(address indexed user, address looper);

    constructor(address morpho, address pendleRouter) {
        require(morpho != address(0) && pendleRouter != address(0), "bad address");
        MORPHO = morpho;
        PENDLE_ROUTER = pendleRouter;
    }

    /// @notice Deploy YOUR personal looper — works with every present and future
    ///         Pendle PT x Morpho market on this chain. The factory holds no power over it.
    function createLooper() external returns (address looper) {
        looper = address(new MorphoUserPTLooper(msg.sender, MORPHO, PENDLE_ROUTER));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }

    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
