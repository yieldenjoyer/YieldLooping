// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title AavePTLooper — self-custodial atomic leveraged Pendle PT, flash-funded by Aave V3
 * @notice Identical strategy to MorphoPTLooper — the position still lives on the user's
 *         own Morpho Blue account — but flash liquidity comes from Aave V3. Use this when
 *         the flash size exceeds Morpho's idle loanToken liquidity. Costs Aave's flash
 *         premium (5 bps at current protocol settings):
 *           OPEN  — the premium is financed as Morpho debt (debt = flash + premium).
 *           CLOSE — PT redemption must cover flash + premium.
 *
 *         Everything else matches MorphoPTLooper: per-user looper via factory, no shared
 *         authorization, no admin, additive open(), repay-by-shares exact close,
 *         execute() escape hatch.
 *
 * @dev Chain-agnostic: all protocol addresses are constructor parameters.
 *      Aave V3 Pool differs per chain (Ethereum 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
 *      Base 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5) — see README.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

// ==================== MORPHO BLUE (money market for the loop) ====================

struct MarketParams {
    address loanToken;
    address collateralToken; // PT
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
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

// ==================== AAVE V3 (flash source) ====================

interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
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

contract AaveUserPTLooper {

    // Morpho SharesMathLib constants — keep in sync with deployed Morpho Blue
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    uint8 private constant ACTION_OPEN = 1;
    uint8 private constant ACTION_CLOSE = 2;

    IMorpho public immutable MORPHO;
    address public immutable AAVE_POOL;
    address public immutable PENDLE_ROUTER;

    address public immutable owner; // the user — set once by the factory, forever
    bytes32 public immutable marketId;
    address public immutable LOAN;  // marketParams.loanToken (e.g. USDe)
    address public immutable SY;
    address public immutable PT;    // marketParams.collateralToken
    address public immutable YT;

    MarketParams public marketParams; // set once in constructor, no setters

    uint256 private unlocked = 1; // 1 = idle, 2 = mid open/close (flash in flight)

    event Opened(uint256 ownCapital, uint256 flashAssets, uint256 premium, uint256 ptSupplied);
    event Closed(uint256 debtRepaid, uint256 premium, uint256 ptWithdrawn, uint256 loanTokenToUser);

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
        address _aavePool,
        address _pendleRouter,
        MarketParams memory mp,
        address sy,
        address yt
    ) {
        require(
            _owner != address(0) && _morpho != address(0) && _aavePool != address(0) && _pendleRouter != address(0),
            "bad address"
        );
        require(mp.loanToken != address(0) && mp.collateralToken != address(0), "bad market");
        require(sy != address(0) && yt != address(0), "bad pendle");
        owner = _owner;
        MORPHO = IMorpho(_morpho);
        AAVE_POOL = _aavePool;
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
     *                      minus margin. NOTE: the Aave premium is added to your Morpho debt.
     * @param minPtBps      min PT out per loanToken in, bps (e.g. 9950 = 0.5% tolerance)
     */
    function open(uint256 initialAmount, uint256 flashAmount, uint256 minPtBps)
        external onlyOwner lock
    {
        require(initialAmount > 0, "no capital");
        require(minPtBps <= 10_000, "bad bps");
        IERC20(LOAN).transferFrom(msg.sender, address(this), initialAmount);

        if (flashAmount == 0) {
            _openInner(0, 0, minPtBps); // unlevered: mint + supply only
        } else {
            IAavePool(AAVE_POOL).flashLoanSimple(
                address(this), LOAN, flashAmount, abi.encode(ACTION_OPEN, minPtBps), 0
            );
        }
    }

    // ==================== CLOSE ====================

    /**
     * @notice Full close. Pre-expiry requires your YT balance >= PT collateral,
     *         approved to this contract (par redemption, zero slippage).
     * @param minOut floor on loanToken returned to you after debt + flash + premium
     */
    function close(uint256 minOut) external onlyOwner lock {
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(marketId, address(this));
        require(collateral > 0, "no position");

        if (borrowShares == 0) {
            _closeInner(0, 0, minOut); // no debt: withdraw + redeem only
        } else {
            uint256 debt = _debtAssets(borrowShares); // accrues first — exact this block
            IAavePool(AAVE_POOL).flashLoanSimple(
                address(this), LOAN, debt, abi.encode(ACTION_CLOSE, minOut), 0
            );
        }
    }

    // ==================== FLASH CALLBACK ====================

    /// @dev On Aave ANYONE can initiate a flash loan naming this contract as receiver —
    ///      the initiator check is load-bearing. Do not remove it.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL, "only Aave pool");
        require(initiator == address(this), "untrusted initiator");
        require(asset == LOAN, "wrong asset");
        require(unlocked == 2, "not in flight");

        (uint8 action, uint256 param) = abi.decode(params, (uint8, uint256));
        if (action == ACTION_OPEN) {
            _openInner(amount, premium, param);
        } else if (action == ACTION_CLOSE) {
            _closeInner(amount, premium, param);
        } else {
            revert("bad action");
        }

        IERC20(LOAN).approve(AAVE_POOL, amount + premium); // pool pulls amount + premium
        return true;
    }

    // ==================== INTERNALS ====================

    function _openInner(uint256 flashAssets, uint256 premium, uint256 minPtBps) internal {
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
            // Borrow flash + premium: the Aave fee is financed as Morpho debt.
            // Reverts here if over-leveraged -> whole tx unwinds, nothing at risk but gas.
            MORPHO.borrow(marketParams, flashAssets + premium, 0, address(this), address(this));
        }

        IERC20(YT).transfer(owner, py); // yield/points leg straight to the user's wallet

        emit Opened(mintAmount - flashAssets, flashAssets, premium, py);
    }

    function _closeInner(uint256 flashAssets, uint256 premium, uint256 minOut) internal {
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

        // 4. Settle flash + premium (pulled after callback returns); remainder to user
        uint256 owed = flashAssets + premium;
        uint256 bal = IERC20(LOAN).balanceOf(address(this));
        require(bal >= owed, "redemption shortfall");
        uint256 toUser = bal - owed;
        require(toUser >= minOut, "slippage");
        if (toUser > 0) IERC20(LOAN).transfer(owner, toUser);

        emit Closed(flashAssets, premium, collateral, toUser);
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
    ///         Funds safety depends on Morpho, Pendle and Aave — not on this code.
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

contract AavePTLooperFactory {

    address public immutable MORPHO;
    address public immutable AAVE_POOL;
    address public immutable PENDLE_ROUTER;
    address public immutable SY;
    address public immutable YT;
    MarketParams public marketParams; // set once, no setters, no admin

    mapping(address => address[]) public loopersOf;

    event LooperDeployed(address indexed user, address looper);

    constructor(
        address morpho,
        address aavePool,
        address pendleRouter,
        MarketParams memory mp,
        address sy,
        address yt
    ) {
        require(morpho != address(0) && aavePool != address(0) && pendleRouter != address(0), "bad address");
        require(mp.loanToken != address(0) && mp.collateralToken != address(0), "bad market");
        require(sy != address(0) && yt != address(0), "bad pendle");
        MORPHO = morpho;
        AAVE_POOL = aavePool;
        PENDLE_ROUTER = pendleRouter;
        marketParams = mp;
        SY = sy;
        YT = yt;
    }

    /// @notice Deploy YOUR personal looper. The factory holds no power over it — ever.
    function createLooper() external returns (address looper) {
        looper = address(new AaveUserPTLooper(msg.sender, MORPHO, AAVE_POOL, PENDLE_ROUTER, marketParams, SY, YT));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }

    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
