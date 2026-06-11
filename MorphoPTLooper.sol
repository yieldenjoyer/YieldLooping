// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MorphoPTLooper — universal self-custodial leveraged Pendle PT on Morpho Blue
 * @notice ANY Pendle PT market + ANY matching Morpho Blue market, chosen per call.
 *         Each user deploys their OWN looper once per chain via the factory; after that
 *         every open()/close() takes the market as a parameter. One looper can hold
 *         positions in many markets simultaneously (Morpho positions are per-market).
 *
 *         The (market, PT, SY) triplet is VALIDATED on-chain from the YT you pass:
 *         PT and SY are read from the YT contract itself, the market's collateralToken
 *         must equal that PT, and the SY must accept/return the market's loanToken.
 *         A mismatched triplet reverts — it cannot silently misroute funds.
 *
 *         OPEN (one tx):  flash loanToken from Morpho (0 fee) -> mint PT+YT at par ->
 *                         supply PT to your own Morpho position -> borrow to repay flash.
 *                         YT goes straight to your wallet. open() is ADDITIVE per market.
 *
 *         CLOSE (one tx): flash exact debt -> repay by shares (exact despite interest
 *                         accrual) -> withdraw all PT -> redeem at par (return YT
 *                         pre-expiry; not needed post-expiry) -> repay flash ->
 *                         remainder to you.
 *
 *         ESCAPE HATCH:   execute() lets the owner raw-call anything as their looper.
 *                         Recovery never depends on this code being correct.
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

    /**
     * @param mp            the EXACT MarketParams of the target Morpho market
     * @param yt            the Pendle YT for the PT used as collateral (PT/SY derived from it)
     * @param initialAmount your capital in loanToken, pulled from your wallet (approve first)
     * @param flashAmount   leverage. Bound: <= initialAmount * lltv/(1-lltv) at oracle price,
     *                      minus margin. Overshooting reverts atomically — only gas lost.
     * @param minPtBps      min PT out per loanToken in, bps (e.g. 9950 = 0.5% tolerance)
     */
    function open(
        MarketParams calldata mp,
        address yt,
        uint256 initialAmount,
        uint256 flashAmount,
        uint256 minPtBps
    ) external onlyOwner lock {
        require(initialAmount > 0, "no capital");
        require(minPtBps <= 10_000, "bad bps");
        require(!IYT(yt).isExpired(), "market expired");
        _validate(mp, yt);
        IERC20(mp.loanToken).transferFrom(msg.sender, address(this), initialAmount);

        if (flashAmount == 0) {
            _openInner(mp, yt, 0, minPtBps); // unlevered: mint + supply only
        } else {
            MORPHO.flashLoan(mp.loanToken, flashAmount, abi.encode(ACTION_OPEN, mp, yt, minPtBps));
        }
    }

    // ==================== CLOSE ====================

    /**
     * @notice Full close of this market's position. Pre-expiry requires your YT balance
     *         >= PT collateral, approved to this contract (par redemption, zero slippage).
     * @param minOut floor on loanToken returned to you after debt + flash settlement
     */
    function close(MarketParams calldata mp, address yt, uint256 minOut) external onlyOwner lock {
        _validate(mp, yt);
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));
        require(collateral > 0, "no position");

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

        IERC20(mp.loanToken).approve(address(MORPHO), assets); // repayment pulled after return
    }

    // ==================== INTERNALS ====================

    function _openInner(MarketParams memory mp, address yt, uint256 flashAssets, uint256 minPtBps) internal {
        address pt = IYT(yt).PT();
        uint256 mintAmount = IERC20(mp.loanToken).balanceOf(address(this)); // own capital + flash

        // loanToken -> PT+YT at par (1:1 pair), never priced through an AMM
        IERC20(mp.loanToken).approve(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            yt,
            (mintAmount * minPtBps) / 10_000,
            TokenInput(
                mp.loanToken, mintAmount, mp.loanToken,
                address(0), address(0), SwapData(SwapType.NONE, address(0), "", false)
            )
        );

        // Position belongs to THIS contract = this user. msg.sender == onBehalf,
        // which Morpho permits natively — no authorization exists anywhere.
        IERC20(pt).approve(address(MORPHO), py);
        MORPHO.supplyCollateral(mp, py, address(this), "");

        if (flashAssets > 0) {
            // Borrow exactly the flash repayment. Reverts here if over-leveraged ->
            // the whole transaction unwinds, nothing at risk but gas.
            MORPHO.borrow(mp, flashAssets, 0, address(this), address(this));
        }

        IERC20(yt).transfer(owner, py); // yield/points leg straight to the user's wallet

        emit Opened(keccak256(abi.encode(mp)), mintAmount - flashAssets, flashAssets, py);
    }

    function _closeInner(MarketParams memory mp, address yt, uint256 flashAssets, uint256 minOut) internal {
        address pt = IYT(yt).PT();
        address sy = IYT(yt).SY();
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));

        // 1. Repay by SHARES — exact full repayment regardless of interest accrual.
        if (borrowShares > 0) {
            IERC20(mp.loanToken).approve(address(MORPHO), flashAssets);
            MORPHO.repay(mp, 0, borrowShares, address(this), "");
        }

        // 2. Withdraw all PT (zero debt -> always healthy)
        MORPHO.withdrawCollateral(mp, collateral, address(this), address(this));

        // 3. PT(+YT pre-expiry) -> SY -> loanToken, at par regardless of PT market price
        uint256 pyIn = collateral;
        IERC20(pt).approve(PENDLE_ROUTER, pyIn);
        if (!IYT(yt).isExpired()) {
            IERC20(yt).transferFrom(owner, address(this), pyIn);
            IERC20(yt).approve(PENDLE_ROUTER, pyIn);
        }
        uint256 syOut = IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), yt, pyIn, 0);
        ISYToken(sy).redeem(address(this), syOut, mp.loanToken, 0, false);

        // 4. Settle flash (pulled after callback returns); remainder to the user
        uint256 bal = IERC20(mp.loanToken).balanceOf(address(this));
        require(bal >= flashAssets, "redemption shortfall");
        uint256 toUser = bal - flashAssets;
        require(toUser >= minOut, "slippage");
        if (toUser > 0) IERC20(mp.loanToken).transfer(owner, toUser);

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

    /// @notice Position snapshot for one market. debtAssetsEstimate uses last-accrued
    ///         totals; the close path computes the exact figure on-chain.
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
