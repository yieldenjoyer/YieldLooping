// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title EulerPTLooper — universal self-custodial leveraged Pendle PT on Euler v2 (EVK)
 * @notice Same family as MorphoPTLooper/AavePTLooper: per-user looper, markets chosen
 *         PER CALL, on-chain triplet validation, execute() escape hatch.
 *
 *         The Euler flavor needs NO external flash loan: the EVC defers account health
 *         checks to the end of a batch, so the looper borrows the full leverage target
 *         from the debt vault FIRST (transiently insolvent), mints PT+YT at par,
 *         deposits the PT, and passes a single health check on the final position.
 *         Zero flash fee; "flash" liquidity is the debt vault's own cash.
 *
 *         ONE ACTIVE MARKET AT A TIME: the EVC allows one controller (debt vault) per
 *         account. Close fully (controller released) before opening a different Euler
 *         market — or deploy another looper (free) for parallel positions.
 *
 *         WRAPPED DEBT ASSET SUPPORT: some Euler markets borrow a 4626 wrapper of the
 *         Pendle mint token (e.g. debt = eUSDe, mint = USDe). Pass that wrapper per call
 *         and the looper hops through deposit/redeem on it. Pass address(0) when the
 *         debt asset IS the mint token. FORK-TEST that the wrapper's deposit AND redeem
 *         are both open — pre-deposit vaults sometimes lock a side.
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

// ==================== EULER V2 ====================

interface IEVault {
    function asset() external view returns (address);
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function disableController() external;
}

interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }
    function batch(BatchItem[] calldata items) external payable;
    function enableCollateral(address account, address vault) external;
    function enableController(address account, address vault) external;
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

contract EulerUserPTLooper {

    address public immutable EVC;
    address public immutable PENDLE_ROUTER;
    address public immutable owner; // the user — set once by the factory, forever

    uint256 private unlocked = 1;   // 1 = idle, 2 = mid open/close (EVC batch in flight)

    event Opened(address indexed debtVault, uint256 ownCapital, uint256 borrowed, uint256 ptSupplied);
    event Closed(address indexed debtVault, uint256 debtRepaid, uint256 ptWithdrawn, uint256 mintTokenToUser);

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

    constructor(address _owner, address _evc, address _pendleRouter) {
        require(_owner != address(0) && _evc != address(0) && _pendleRouter != address(0), "bad address");
        owner = _owner;
        EVC = _evc;
        PENDLE_ROUTER = _pendleRouter;
    }

    // ==================== MARKET VALIDATION ====================

    /// @dev Derives PT/SY from the YT, resolves the mint token through the optional
    ///      wrapper, and proves the whole set is consistent. Bad params revert —
    ///      funds cannot be misrouted.
    function _validate(address collateralVault, address debtVault, address wrapper, address yt)
        internal view returns (address pt, address sy, address mintToken)
    {
        pt = IYT(yt).PT();
        sy = IYT(yt).SY();
        require(IEVault(collateralVault).asset() == pt, "collateral vault asset != yt PT");

        address debtAsset = IEVault(debtVault).asset();
        if (wrapper == address(0)) {
            mintToken = debtAsset; // debt asset IS the Pendle mint token
        } else {
            require(debtAsset == wrapper, "wrapper must be the debt asset");
            mintToken = IERC4626(wrapper).asset(); // e.g. debt = eUSDe (4626), mint = USDe
        }
        require(ISYToken(sy).isValidTokenIn(mintToken), "SY cannot mint from token");
        require(ISYToken(sy).isValidTokenOut(mintToken), "SY cannot redeem to token");
    }

    // ==================== OPEN ====================

    /**
     * @param collateralVault Euler eVault holding the PT (its asset() must equal yt.PT())
     * @param debtVault       Euler eVault to borrow from (becomes this looper's controller)
     * @param wrapper         4626 wrapper when the debt asset wraps the mint token, else address(0)
     * @param yt              the Pendle YT (PT/SY derived and validated from it)
     * @param initialAmount   your capital in the MINT token (approve it to the looper first)
     * @param borrowAmount    leverage in DEBT-asset units, health-checked ONCE on the final
     *                        position. Bound at oracle price: <= initial * LTV/(1-LTV), minus
     *                        margin. Also capped by the debt vault's available cash.
     * @param minPtBps        min PT out per mint token in, bps (e.g. 9950)
     */
    function open(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 initialAmount,
        uint256 borrowAmount,
        uint256 minPtBps
    ) external onlyOwner lock {
        require(initialAmount > 0, "no capital");
        require(minPtBps <= 10_000, "bad bps");
        require(!IYT(yt).isExpired(), "market expired");
        (,, address mintToken) = _validate(collateralVault, debtVault, wrapper, yt);
        IERC20(mintToken).transferFrom(msg.sender, address(this), initialAmount);

        // Idempotent for the active market. A second, DIFFERENT controller makes the
        // batch-end account check revert — the EVC itself enforces one market at a time.
        IEVC(EVC).enableCollateral(address(this), collateralVault);
        IEVC(EVC).enableController(address(this), debtVault);

        _runBatch(abi.encodeCall(this.openStep, (collateralVault, debtVault, wrapper, yt, borrowAmount, minPtBps)));
    }

    // ==================== CLOSE ====================

    /**
     * @notice Full close. Pre-expiry requires your YT balance >= PT collateral, approved
     *         to this contract. If redemption can't cover the debt (rates ran hot),
     *         transfer extra mint tokens to the looper first and retry.
     * @param minOut floor on mint tokens returned to you after full debt repayment
     */
    function close(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 minOut
    ) external onlyOwner lock {
        _validate(collateralVault, debtVault, wrapper, yt);
        require(IEVault(collateralVault).balanceOf(address(this)) > 0, "no position");
        _runBatch(abi.encodeCall(this.closeStep, (collateralVault, debtVault, wrapper, yt, minOut)));
    }

    function _runBatch(bytes memory data) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: data
        });
        IEVC(EVC).batch(items); // health checks deferred to the end of this call
    }

    // ==================== EVC BATCH STEPS ====================

    /// @dev Only reachable via the EVC batch initiated by open() — gated by the lock state.
    function openStep(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 borrowAmount,
        uint256 minPtBps
    ) external {
        require(msg.sender == EVC, "only EVC");
        require(unlocked == 2, "not in flight");

        address pt = IYT(yt).PT();
        address mintToken = wrapper == address(0) ? IEVault(debtVault).asset() : IERC4626(wrapper).asset();

        // 1. Borrow the FULL target first — transient insolvency is fine inside the batch
        if (borrowAmount > 0) {
            uint256 borrowed = IEVault(debtVault).borrow(borrowAmount, address(this));
            if (wrapper != address(0)) {
                IERC4626(wrapper).redeem(borrowed, address(this), address(this)); // unwrap to mint token
            }
        }

        // 2. Mint PT+YT from everything, at par via the SY — never priced through an AMM
        uint256 mintAmount = IERC20(mintToken).balanceOf(address(this));
        require(mintAmount > 0, "nothing to deploy");
        IERC20(mintToken).approve(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            yt,
            (mintAmount * minPtBps) / 10_000,
            TokenInput(mintToken, mintAmount, mintToken, address(0), address(0), SwapData(SwapType.NONE, address(0), "", false))
        );

        // 3. Deposit all PT as collateral; single health check fires at batch end
        IERC20(pt).approve(collateralVault, py);
        IEVault(collateralVault).deposit(py, address(this));

        // 4. Yield/points leg straight to the user's wallet
        IERC20(yt).transfer(owner, py);

        emit Opened(debtVault, mintAmount - borrowAmount, borrowAmount, py);
    }

    /// @dev Only reachable via the EVC batch initiated by close().
    function closeStep(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 minOut
    ) external {
        require(msg.sender == EVC, "only EVC");
        require(unlocked == 2, "not in flight");

        address pt = IYT(yt).PT();
        address sy = IYT(yt).SY();
        address debtAsset = IEVault(debtVault).asset();
        address mintToken = wrapper == address(0) ? debtAsset : IERC4626(wrapper).asset();

        // 1. Pull ALL PT collateral back (status check deferred — debt still open here)
        uint256 shares = IEVault(collateralVault).balanceOf(address(this));
        uint256 ptOut = IEVault(collateralVault).redeem(shares, address(this), address(this));

        // 2. PT(+YT pre-expiry) -> SY -> mint token, at par regardless of PT market price
        uint256 pyIn = ptOut;
        IERC20(pt).approve(PENDLE_ROUTER, pyIn);
        if (!IYT(yt).isExpired()) {
            IERC20(yt).transferFrom(owner, address(this), pyIn);
            IERC20(yt).approve(PENDLE_ROUTER, pyIn);
        }
        uint256 syOut = IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), yt, pyIn, 0);
        ISYToken(sy).redeem(address(this), syOut, mintToken, 0, false);

        // 3. Repay FULL debt. type(uint256).max = exact full repayment in EVK, immune
        //    to per-second interest accrual.
        uint256 debt = IEVault(debtVault).debtOf(address(this));
        if (debt > 0) {
            if (wrapper != address(0)) {
                uint256 mintBal = IERC20(mintToken).balanceOf(address(this));
                IERC20(mintToken).approve(wrapper, mintBal);
                IERC4626(wrapper).deposit(mintBal, address(this)); // wrap back to debt asset
            }
            uint256 debtBal = IERC20(debtAsset).balanceOf(address(this));
            require(debtBal >= debt, "shortfall: transfer mint tokens to looper and retry");
            IERC20(debtAsset).approve(debtVault, debt);
            IEVault(debtVault).repay(type(uint256).max, address(this));
            IEVault(debtVault).disableController(); // release the account for the next market

            if (wrapper != address(0)) {
                uint256 leftover = IERC20(debtAsset).balanceOf(address(this));
                if (leftover > 0) {
                    IERC4626(wrapper).redeem(leftover, address(this), address(this)); // unwrap remainder
                }
            }
        }

        // 4. Everything left goes to the user
        uint256 toUser = IERC20(mintToken).balanceOf(address(this));
        require(toUser >= minOut, "slippage");
        if (toUser > 0) IERC20(mintToken).transfer(owner, toUser);

        emit Closed(debtVault, debt, ptOut, toUser);
    }

    // ==================== VIEWS ====================

    function getPosition(address collateralVault, address debtVault, address yt) external view returns (
        uint256 ptCollateralShares,
        uint256 debtAssets,
        uint256 ytNeededToClose
    ) {
        ptCollateralShares = IEVault(collateralVault).balanceOf(address(this));
        debtAssets = IEVault(debtVault).debtOf(address(this));
        ytNeededToClose = IYT(yt).isExpired() ? 0 : ptCollateralShares;
    }

    // ==================== FULL USER CONTROL ====================

    /// @notice Raw escape hatch — see README runbook.
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

contract EulerPTLooperFactory {

    address public immutable EVC;
    address public immutable PENDLE_ROUTER;

    mapping(address => address[]) public loopersOf;

    event LooperDeployed(address indexed user, address looper);

    constructor(address evc, address pendleRouter) {
        require(evc != address(0) && pendleRouter != address(0), "bad address");
        EVC = evc;
        PENDLE_ROUTER = pendleRouter;
    }

    /// @notice Deploy YOUR personal looper — works with every present and future
    ///         Pendle PT x Euler market on this chain. The factory holds no power over it.
    function createLooper() external returns (address looper) {
        looper = address(new EulerUserPTLooper(msg.sender, EVC, PENDLE_ROUTER));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }

    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
