// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * @title EulerPTLooper — universal self-custodial leveraged Pendle PT on Euler v2 (EVK)
 * @notice No external flash: the EVC defers account health checks to the end of a batch,
 *         so the looper borrows the full leverage target first, mints PT, deposits it, and
 *         passes a single health check on the final position. EOA-only, one looper per user.
 *         ONE ACTIVE EULER MARKET AT A TIME (EVC allows one controller per account).
 *
 *         v2 CHANGES:
 *         - absolute `minPtOut` (see MorphoPTLooper for the slippage rationale)
 *         - EOA-only deploy + open/close
 *         - CONTROLLER RELEASE FIX: close now releases the controller even on a zero-debt
 *           (unlevered) position, so it never gets stranded and block the next market.
 *         - close YT pre-check uses convertToAssets(shares) (exact PT), + allowance check.
 *
 *         WRAPPED DEBT ASSET: pass the 4626 wrapper when debt asset wraps the mint token
 *         (e.g. debt = eUSDe, mint = USDe), else address(0). Fork-test that the wrapper's
 *         deposit AND redeem are both open before using it.
 *         made by 0xpepe
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
library SafeERC20 {
    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }
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
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
interface IEVault {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
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
contract EulerUserPTLooper {
    using SafeERC20 for address;
    address public immutable EVC;
    address public immutable PENDLE_ROUTER;
    address public immutable owner;
    uint256 private unlocked = 1;
    event Opened(address indexed debtVault, uint256 ownCapital, uint256 borrowed, uint256 ptSupplied);
    event Closed(address indexed debtVault, uint256 debtRepaid, uint256 ptWithdrawn, uint256 mintTokenToUser);
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }
    /// @dev EOA-only. Excludes Safe/4337/smart-contract wallets by design.
    modifier onlyEOA() {
        require(msg.sender == tx.origin, "EOA only");
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
    function _validate(address collateralVault, address debtVault, address wrapper, address yt)
        internal view returns (address pt, address sy, address mintToken)
    {
        pt = IYT(yt).PT();
        sy = IYT(yt).SY();
        require(IEVault(collateralVault).asset() == pt, "collateral vault asset != yt PT");
        address debtAsset = IEVault(debtVault).asset();
        if (wrapper == address(0)) {
            mintToken = debtAsset;
        } else {
            require(debtAsset == wrapper, "wrapper must be the debt asset");
            mintToken = IERC4626(wrapper).asset();
        }
        require(ISYToken(sy).isValidTokenIn(mintToken), "SY cannot mint from token");
        require(ISYToken(sy).isValidTokenOut(mintToken), "SY cannot redeem to token");
    }
    /// @param minPtOut ABSOLUTE floor on PT minted, in PT units (compute off-chain). > 0.
    function open(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 initialAmount,
        uint256 borrowAmount,
        uint256 minPtOut
    ) external onlyOwner onlyEOA lock {
        require(initialAmount > 0, "no capital");
        require(minPtOut > 0, "minPtOut required");
        require(!IYT(yt).isExpired(), "market expired");
        (,, address mintToken) = _validate(collateralVault, debtVault, wrapper, yt);
        mintToken.safeTransferFrom(msg.sender, address(this), initialAmount);
        IEVC(EVC).enableCollateral(address(this), collateralVault);
        IEVC(EVC).enableController(address(this), debtVault);
        _runBatch(abi.encodeCall(this.openStep, (collateralVault, debtVault, wrapper, yt, borrowAmount, minPtOut)));
    }
    /// @param minOut floor on mint tokens returned to you after full debt repayment
    function close(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 minOut
    ) external onlyOwner onlyEOA lock {
        require(minOut > 0, "minOut required");
        _validate(collateralVault, debtVault, wrapper, yt);
        uint256 ptShares = IEVault(collateralVault).balanceOf(address(this));
        require(ptShares > 0, "no position");
        if (!IYT(yt).isExpired()) {
            uint256 ptAssets = IEVault(collateralVault).convertToAssets(ptShares);
            require(IERC20(yt).balanceOf(owner) >= ptAssets, "pre-expiry close needs YT balance");
            require(IERC20(yt).allowance(owner, address(this)) >= ptAssets, "approve YT to looper first");
        }
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
        IEVC(EVC).batch(items);
    }
    function openStep(
        address collateralVault,
        address debtVault,
        address wrapper,
        address yt,
        uint256 borrowAmount,
        uint256 minPtOut
    ) external {
        require(msg.sender == EVC, "only EVC");
        require(unlocked == 2, "not in flight");
        address pt = IYT(yt).PT();
        address mintToken = wrapper == address(0) ? IEVault(debtVault).asset() : IERC4626(wrapper).asset();
        // Borrow the full leverage target first — transient insolvency is fine inside the batch.
        // Track what the borrow produced IN MINT-TOKEN UNITS so the event math can't cross units.
        uint256 mintFromBorrow;
        if (borrowAmount > 0) {
            uint256 borrowed = IEVault(debtVault).borrow(borrowAmount, address(this));
            mintFromBorrow = wrapper == address(0)
                ? borrowed
                : IERC4626(wrapper).redeem(borrowed, address(this), address(this)); // unwrap to mint token
        }
        uint256 mintAmount = IERC20(mintToken).balanceOf(address(this));
        require(mintAmount > 0, "nothing to deploy");
        mintToken.forceApprove(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            yt,
            minPtOut,
            TokenInput(mintToken, mintAmount, mintToken, address(0), address(0), SwapData(SwapType.NONE, address(0), "", false))
        );
        mintToken.forceApprove(PENDLE_ROUTER, 0);
        pt.forceApprove(collateralVault, py);
        IEVault(collateralVault).deposit(py, address(this));
        pt.forceApprove(collateralVault, 0);
        yt.safeTransfer(owner, py);
        // ownCapital in mint-token units; mintAmount >= mintFromBorrow so this cannot underflow
        emit Opened(debtVault, mintAmount - mintFromBorrow, borrowAmount, py);
    }
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
        // 2. PT(+YT pre-expiry) -> SY -> mint token, at par
        uint256 pyIn = ptOut;
        pt.forceApprove(PENDLE_ROUTER, pyIn);
        if (!IYT(yt).isExpired()) {
            yt.safeTransferFrom(owner, address(this), pyIn);
            yt.forceApprove(PENDLE_ROUTER, pyIn);
        }
        uint256 syOut = IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), yt, pyIn, 0);
        pt.forceApprove(PENDLE_ROUTER, 0);
        if (!IYT(yt).isExpired()) yt.forceApprove(PENDLE_ROUTER, 0);
        ISYToken(sy).redeem(address(this), syOut, mintToken, 0, false);
        // 3. Repay FULL debt if any
        uint256 debt = IEVault(debtVault).debtOf(address(this));
        if (debt > 0) {
            if (wrapper != address(0)) {
                uint256 mintBal = IERC20(mintToken).balanceOf(address(this));
                mintToken.forceApprove(wrapper, mintBal);
                IERC4626(wrapper).deposit(mintBal, address(this));
                mintToken.forceApprove(wrapper, 0);
            }
            uint256 debtBal = IERC20(debtAsset).balanceOf(address(this));
            require(debtBal >= debt, "shortfall: transfer mint tokens to looper and retry");
            debtAsset.forceApprove(debtVault, debt);
            IEVault(debtVault).repay(type(uint256).max, address(this));
            debtAsset.forceApprove(debtVault, 0);
        }
        // 4. ALWAYS release the controller (open() always enabled it; debt is 0 now).
        //    This is the fix for unlevered/zero-debt closes stranding the controller.
        IEVault(debtVault).disableController();
        // 5. Unwrap any leftover debt asset back to the mint token (wrapper case)
        if (wrapper != address(0)) {
            uint256 leftover = IERC20(debtAsset).balanceOf(address(this));
            if (leftover > 0) {
                IERC4626(wrapper).redeem(leftover, address(this), address(this));
            }
        }
        // 6. Everything left goes to the user
        uint256 toUser = IERC20(mintToken).balanceOf(address(this));
        require(toUser >= minOut, "slippage");
        if (toUser > 0) mintToken.safeTransfer(owner, toUser);
        emit Closed(debtVault, debt, ptOut, toUser);
    }
    function getPosition(address collateralVault, address debtVault, address yt) external view returns (
        uint256 ptCollateralShares,
        uint256 debtAssets,
        uint256 ytNeededToClose
    ) {
        ptCollateralShares = IEVault(collateralVault).balanceOf(address(this));
        debtAssets = IEVault(debtVault).debtOf(address(this));
        ytNeededToClose = IYT(yt).isExpired() ? 0 : IEVault(collateralVault).convertToAssets(ptCollateralShares);
    }
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
    /// @notice Recover any ETH accidentally sent here (none is used in normal operation).
    function sweepETH() external onlyOwner {
        (bool ok, ) = payable(owner).call{value: address(this).balance}("");
        require(ok, "eth sweep failed");
    }
    receive() external payable {}
}
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
    function createLooper() external returns (address looper) {
        require(msg.sender == tx.origin, "EOA only");
        looper = address(new EulerUserPTLooper(msg.sender, EVC, PENDLE_ROUTER));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }
    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
