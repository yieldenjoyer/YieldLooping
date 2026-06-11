// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MorphoPTLooper — self-custodial atomic leveraged Pendle PT, flash-funded by Morpho Blue
 * @notice Each user deploys their OWN looper through the factory. Their position lives on
 *         their looper's Morpho account. No shared authorization, no admin, no deployer
 *         privileges, no upgradability. Morpho flash loans are 0-fee.
 *
 *         OPEN (one tx):  flash loanToken -> mint PT+YT at par via Pendle -> supply PT to
 *                         own Morpho position -> borrow loanToken to repay flash.
 *                         YT goes straight to the user's wallet.
 *                         One flash collapses the entire iterative loop: max leverage is
 *                         bounded by lltv/(1-lltv) at the market oracle price.
 *                         open() is ADDITIVE — call again any time to loop more.
 *
 *         CLOSE (one tx): flash exact debt -> repay by shares (exact despite interest
 *                         accrual) -> withdraw all PT -> redeem at par (user returns YT
 *                         pre-expiry; not needed post-expiry) -> repay flash -> remainder
 *                         to user.
 *
 *         ESCAPE HATCH:   execute() lets the owner raw-call anything as their looper.
 *                         Recovery never depends on this code being correct.
 *
 * @dev Chain-agnostic: all protocol addresses are constructor parameters. Deploy the
 *      factory once per (chain, Morpho market, Pendle maturity).
 *      The Morpho market's loanToken MUST be the same token the Pendle SY mints from.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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
}

interface IYT {
    function isExpired() external view returns (bool);
}

// ==================== USER LOOPER ====================

contract MorphoUserPTLooper {

    // Morpho SharesMathLib constants — keep in sync with deployed Morpho Blue
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    uint8 private constant ACTION_OPEN = 1;
    uint8 private constant ACTION_CLOSE = 2;

    IMorpho public immutable MORPHO;
    address public immutable PENDLE_ROUTER;

    address public immutable owner; // the user — set once by the factory, forever
    bytes32 public immutable marketId;
    address public immutable LOAN;  // marketParams.loanToken (e.g. USDe)
    address public immutable SY;
    address public immutable PT;    // marketParams.collateralToken
    address public immutable YT;

    MarketParams public marketParams; // set once in constructor, no setters

    uint256 private unlocked = 1; // 1 = idle, 2 = mid open/close (flash in flight)

    event Opened(uint256 ownCapital, uint256 flashAssets, uint256 ptSupplied);
    event Closed(uint256 debtRepaid, uint256 ptWithdrawn, uint256 loanTokenToUser);

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

    constructor(
        address _owner,
        address _morpho,
        address _pendleRouter,
        MarketParams memory mp,
        address sy,
        address yt
    ) {
        require(_owner != address(0) && _morpho != address(0) && _pendleRouter != address(0), "bad address");
        require(mp.loanToken != address(0) && mp.collateralToken != address(0), "bad market");
        require(sy != address(0) && yt != address(0), "bad pendle");
        owner = _owner;
        MORPHO = IMorpho(_morpho);
        PENDLE_ROUTER = _pendleRouter;
        marketParams = mp;
        marketId = keccak256(abi.encode(mp));
        LOAN = mp.loanToken;
        PT = mp.collateralToken;
        SY = sy;
        YT = yt;
    }

    // ==================== OPEN ====================

    /**
     * @param initialAmount your capital in loanToken, pulled from your wallet (approve first)
     * @param flashAmount   leverage. Bound: <= initialAmount * lltv/(1-lltv) at oracle price,
     *                      minus margin. Overshooting reverts atomically — only gas lost.
     * @param minPtBps      min PT out per loanToken in, bps (e.g. 9950 = 0.5% tolerance)
     */
    function open(uint256 initialAmount, uint256 flashAmount, uint256 minPtBps)
        external onlyOwner lock
    {
        require(initialAmount > 0, "no capital");
        require(minPtBps <= 10_000, "bad bps");
        IERC20(LOAN).transferFrom(msg.sender, address(this), initialAmount);

        if (flashAmount == 0) {
            _openInner(0, minPtBps); // unlevered: mint + supply only
        } else {
            MORPHO.flashLoan(LOAN, flashAmount, abi.encode(ACTION_OPEN, minPtBps));
        }
    }

    // ==================== CLOSE ====================

    /**
     * @notice Full close. Pre-expiry requires your YT balance >= PT collateral,
     *         approved to this contract (par redemption, zero slippage).
     * @param minOut floor on loanToken returned to you after debt + flash settlement
     */
    function close(uint256 minOut) external onlyOwner lock {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, address(this));
        require(collateral > 0, "no position");

        if (borrowShares == 0) {
            _closeInner(0, minOut); // no debt: withdraw + redeem only
        } else {
            uint256 debt = _debtAssets(borrowShares); // accrues first — exact this block
            MORPHO.flashLoan(LOAN, debt, abi.encode(ACTION_CLOSE, minOut));
        }
    }

    // ==================== FLASH CALLBACK ====================

    /// @dev Morpho only ever calls back the flash initiator, which is this contract.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(MORPHO), "only Morpho");
        require(unlocked == 2, "not in flight");

        (uint8 action, uint256 param) = abi.decode(data, (uint8, uint256));
        if (action == ACTION_OPEN) {
            _openInner(assets, param);
        } else if (action == ACTION_CLOSE) {
            _closeInner(assets, param);
        } else {
            revert("bad action");
        }

        IERC20(LOAN).approve(address(MORPHO), assets); // repayment pulled after return
    }

    // ==================== INTERNALS ====================

    function _openInner(uint256 flashAssets, uint256 minPtBps) internal {
        uint256 mintAmount = IERC20(LOAN).balanceOf(address(this)); // own capital + flash

        // loanToken -> PT+YT at par (1:1 pair), never priced through an AMM
        IERC20(LOAN).approve(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            YT,
            (mintAmount * minPtBps) / 10_000,
            TokenInput(LOAN, mintAmount, LOAN, address(0), address(0), SwapData(SwapType.NONE, address(0), "", false))
        );

        // Position belongs to THIS contract = this user. msg.sender == onBehalf,
        // which Morpho permits natively — no authorization exists anywhere.
        IERC20(PT).approve(address(MORPHO), py);
        MORPHO.supplyCollateral(marketParams, py, address(this), "");

        if (flashAssets > 0) {
            // Borrow exactly the flash repayment. Reverts here if over-leveraged ->
            // the whole transaction unwinds, nothing at risk but gas.
            MORPHO.borrow(marketParams, flashAssets, 0, address(this), address(this));
        }

        IERC20(YT).transfer(owner, py); // yield/points leg straight to the user's wallet

        emit Opened(mintAmount - flashAssets, flashAssets, py);
    }

    function _closeInner(uint256 flashAssets, uint256 minOut) internal {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, address(this));

        // 1. Repay by SHARES — exact full repayment regardless of interest accrual.
        if (borrowShares > 0) {
            IERC20(LOAN).approve(address(MORPHO), flashAssets);
            MORPHO.repay(marketParams, 0, borrowShares, address(this), "");
        }

        // 2. Withdraw all PT (zero debt -> always healthy)
        MORPHO.withdrawCollateral(marketParams, collateral, address(this), address(this));

        // 3. PT(+YT pre-expiry) -> SY -> loanToken, at par regardless of PT market price
        uint256 pyIn = collateral;
        IERC20(PT).approve(PENDLE_ROUTER, pyIn);
        if (!IYT(YT).isExpired()) {
            IERC20(YT).transferFrom(owner, address(this), pyIn);
            IERC20(YT).approve(PENDLE_ROUTER, pyIn);
        }
        uint256 syOut = IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), YT, pyIn, 0);
        ISYToken(SY).redeem(address(this), syOut, LOAN, 0, false);

        // 4. Settle flash (pulled after callback returns); remainder to the user
        uint256 bal = IERC20(LOAN).balanceOf(address(this));
        require(bal >= flashAssets, "redemption shortfall");
        uint256 toUser = bal - flashAssets;
        require(toUser >= minOut, "slippage");
        if (toUser > 0) IERC20(LOAN).transfer(owner, toUser);

        emit Closed(flashAssets, collateral, toUser);
    }

    /// @dev Exact debt in assets for a share amount. Accrues interest first, so within
    ///      this transaction the result matches repay-by-shares to the wei (same formula,
    ///      same upward rounding as Morpho's SharesMathLib.toAssetsUp).
    function _debtAssets(uint128 borrowShares) internal returns (uint256) {
        MORPHO.accrueInterest(marketParams);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        return _mulDivUp(
            uint256(borrowShares),
            uint256(totalBorrowAssets) + VIRTUAL_ASSETS,
            uint256(totalBorrowShares) + VIRTUAL_SHARES
        );
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    // ==================== VIEWS ====================

    /// @notice Position snapshot. debtAssetsEstimate uses last-accrued totals;
    ///         the close path computes the exact figure on-chain.
    function getPosition() external view returns (
        uint256 ptCollateral,
        uint256 borrowShares,
        uint256 debtAssetsEstimate
    ) {
        (, uint128 shares, uint128 collateral) = MORPHO.position(marketId, address(this));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        ptCollateral = collateral;
        borrowShares = shares;
        debtAssetsEstimate = totalBorrowShares == 0 ? 0 : _mulDivUp(
            uint256(shares),
            uint256(totalBorrowAssets) + VIRTUAL_ASSETS,
            uint256(totalBorrowShares) + VIRTUAL_SHARES
        );
    }

    // ==================== FULL USER CONTROL ====================

    /// @notice Raw escape hatch: the owner can make this contract call ANYTHING.
    ///         If open/close ever break, repay/withdraw on Morpho directly yourself.
    ///         Funds safety depends on Morpho and Pendle — not on this code.
    function execute(address target, uint256 value, bytes calldata data)
        external payable onlyOwner returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "execute failed");
        return ret;
    }

    function sweep(address token) external onlyOwner {
        IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
    }

    receive() external payable {}
}

// ==================== FACTORY ====================

contract MorphoPTLooperFactory {

    address public immutable MORPHO;
    address public immutable PENDLE_ROUTER;
    address public immutable SY;
    address public immutable YT;
    MarketParams public marketParams; // set once, no setters, no admin

    mapping(address => address[]) public loopersOf;

    event LooperDeployed(address indexed user, address looper);

    constructor(address morpho, address pendleRouter, MarketParams memory mp, address sy, address yt) {
        require(morpho != address(0) && pendleRouter != address(0), "bad address");
        require(mp.loanToken != address(0) && mp.collateralToken != address(0), "bad market");
        require(sy != address(0) && yt != address(0), "bad pendle");
        MORPHO = morpho;
        PENDLE_ROUTER = pendleRouter;
        marketParams = mp;
        SY = sy;
        YT = yt;
    }

    /// @notice Deploy YOUR personal looper. The factory holds no power over it — ever.
    function createLooper() external returns (address looper) {
        looper = address(new MorphoUserPTLooper(msg.sender, MORPHO, PENDLE_ROUTER, marketParams, SY, YT));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }

    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
