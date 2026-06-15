// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
/**
 * @title AavePTLooper — universal self-custodial leveraged Pendle PT, flash-funded by Aave V3
 * @notice Same strategy as MorphoPTLooper; flash liquidity from Aave V3 (5 bps premium)
 *         for when Morpho lacks idle loan-token liquidity. EOA-only, one looper per user. 
 *
 *         v2 CHANGES: absolute `minPtOut` (see MorphoPTLooper for the slippage rationale),
 *         EOA-only deploy + open/close, YT allowance pre-check on close.
 *
 *         NOTE: this file requires `viaIR = true` (it is stack-too-deep on the legacy
 *         pipeline). foundry.toml sets it; if you compile elsewhere, enable viaIR.
 *         
 *         Made by 0xpepe 
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
interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
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
contract AaveUserPTLooper {
    using SafeERC20 for address;
    uint8 private constant ACTION_OPEN = 1;
    uint8 private constant ACTION_CLOSE = 2;
    IMorpho public immutable MORPHO;
    address public immutable AAVE_POOL;
    address public immutable PENDLE_ROUTER;
    address public immutable owner;
    uint256 private unlocked = 1;
    event Opened(bytes32 indexed marketId, uint256 ownCapital, uint256 flashAssets, uint256 premium, uint256 ptSupplied);
    event Closed(bytes32 indexed marketId, uint256 debtRepaid, uint256 premium, uint256 ptWithdrawn, uint256 loanTokenToUser);
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
    constructor(address _owner, address _morpho, address _aavePool, address _pendleRouter) {
        require(
            _owner != address(0) && _morpho != address(0) && _aavePool != address(0) && _pendleRouter != address(0),
            "bad address"
        );
        owner = _owner;
        MORPHO = IMorpho(_morpho);
        AAVE_POOL = _aavePool;
        PENDLE_ROUTER = _pendleRouter;
    }
    function _validate(MarketParams calldata mp, address yt) internal view returns (address pt, address sy) {
        pt = IYT(yt).PT();
        sy = IYT(yt).SY();
        require(mp.collateralToken == pt, "market PT != yt PT");
        require(ISYToken(sy).isValidTokenIn(mp.loanToken), "SY cannot mint from loanToken");
        require(ISYToken(sy).isValidTokenOut(mp.loanToken), "SY cannot redeem to loanToken");
    }
    /// @param minPtOut ABSOLUTE floor on PT minted (PT units). The Aave premium is added
    ///                 to your Morpho debt on open.
    function open(
        MarketParams calldata mp,
        address yt,
        uint256 initialAmount,
        uint256 flashAmount,
        uint256 minPtOut
    ) external onlyOwner onlyEOA lock {
        require(initialAmount > 0, "no capital");
        require(minPtOut > 0, "minPtOut required");
        require(!IYT(yt).isExpired(), "market expired");
        _validate(mp, yt);
        mp.loanToken.safeTransferFrom(msg.sender, address(this), initialAmount);
        if (flashAmount == 0) {
            _openInner(mp, yt, 0, 0, minPtOut);
        } else {
            IAavePool(AAVE_POOL).flashLoanSimple(
                address(this), mp.loanToken, flashAmount, abi.encode(ACTION_OPEN, mp, yt, minPtOut), 0
            );
        }
    }
    /// @param minOut floor on loanToken returned to you after debt + flash + premium
    function close(MarketParams calldata mp, address yt, uint256 minOut) external onlyOwner onlyEOA lock {
        require(minOut > 0, "minOut required");
        _validate(mp, yt);
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));
        require(collateral > 0, "no position");
        if (!IYT(yt).isExpired()) {
            require(IERC20(yt).balanceOf(owner) >= collateral, "pre-expiry close needs YT balance");
            require(IERC20(yt).allowance(owner, address(this)) >= collateral, "approve YT to looper first");
        }
        if (borrowShares == 0) {
            _closeInner(mp, yt, 0, 0, minOut);
        } else {
            uint256 debt = _debtAssets(mp, id, borrowShares);
            IAavePool(AAVE_POOL).flashLoanSimple(
                address(this), mp.loanToken, debt, abi.encode(ACTION_CLOSE, mp, yt, minOut), 0
            );
        }
    }
    /// @dev On Aave ANYONE can initiate a flash naming this contract as receiver 
    ///      the initiator check is load bearing. Do not remove it.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL, "only Aave pool");
        require(initiator == address(this), "untrusted initiator");
        require(unlocked == 2, "not in flight");
        (uint8 action, MarketParams memory mp, address yt, uint256 param) =
            abi.decode(params, (uint8, MarketParams, address, uint256));
        require(asset == mp.loanToken, "wrong asset");
        if (action == ACTION_OPEN) {
            _openInner(mp, yt, amount, premium, param);
        } else if (action == ACTION_CLOSE) {
            _closeInner(mp, yt, amount, premium, param);
        } else {
            revert("bad action");
        }
        mp.loanToken.forceApprove(AAVE_POOL, amount + premium);
        return true;
    }
    function _openInner(
        MarketParams memory mp,
        address yt,
        uint256 flashAssets,
        uint256 premium,
        uint256 minPtOut
    ) internal {
        address pt = IYT(yt).PT();
        uint256 mintAmount = IERC20(mp.loanToken).balanceOf(address(this));
        mp.loanToken.forceApprove(PENDLE_ROUTER, mintAmount);
        uint256 py = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
            address(this),
            yt,
            minPtOut,
            TokenInput(
                mp.loanToken, mintAmount, mp.loanToken,
                address(0), address(0), SwapData(SwapType.NONE, address(0), "", false)
            )
        );
        mp.loanToken.forceApprove(PENDLE_ROUTER, 0);
        pt.forceApprove(address(MORPHO), py);
        MORPHO.supplyCollateral(mp, py, address(this), "");
        if (flashAssets > 0) {
            MORPHO.borrow(mp, flashAssets + premium, 0, address(this), address(this));
        }
        pt.forceApprove(address(MORPHO), 0);
        yt.safeTransfer(owner, py);
        emit Opened(keccak256(abi.encode(mp)), mintAmount - flashAssets, flashAssets, premium, py);
    }
    function _closeInner(
        MarketParams memory mp,
        address yt,
        uint256 flashAssets,
        uint256 premium,
        uint256 minOut
    ) internal {
        address pt = IYT(yt).PT();
        address sy = IYT(yt).SY();
        bytes32 id = keccak256(abi.encode(mp));
        (, uint128 borrowShares, uint128 collateral) = MORPHO.position(id, address(this));
        if (borrowShares > 0) {
            mp.loanToken.forceApprove(address(MORPHO), flashAssets);
            MORPHO.repay(mp, 0, borrowShares, address(this), "");
            mp.loanToken.forceApprove(address(MORPHO), 0);
        }
        MORPHO.withdrawCollateral(mp, collateral, address(this), address(this));
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
        uint256 owed = flashAssets + premium;
        uint256 bal = IERC20(mp.loanToken).balanceOf(address(this));
        require(bal >= owed, "redemption shortfall");
        uint256 toUser = bal - owed;
        require(toUser >= minOut, "slippage");
        if (toUser > 0) mp.loanToken.safeTransfer(owner, toUser);
        emit Closed(id, flashAssets, premium, collateral, toUser);
    }
    function _debtAssets(MarketParams calldata mp, bytes32 id, uint128 borrowShares) internal returns (uint256) {
        MORPHO.accrueInterest(mp);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(id);
        return _mulDivUp(uint256(borrowShares), uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6);
    }
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
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
contract AavePTLooperFactory {
    address public immutable MORPHO;
    address public immutable AAVE_POOL;
    address public immutable PENDLE_ROUTER;
    mapping(address => address[]) public loopersOf;
    event LooperDeployed(address indexed user, address looper);
    constructor(address morpho, address aavePool, address pendleRouter) {
        require(morpho != address(0) && aavePool != address(0) && pendleRouter != address(0), "bad address");
        MORPHO = morpho;
        AAVE_POOL = aavePool;
        PENDLE_ROUTER = pendleRouter;
    }
    function createLooper() external returns (address looper) {
        require(msg.sender == tx.origin, "EOA only");
        looper = address(new AaveUserPTLooper(msg.sender, MORPHO, AAVE_POOL, PENDLE_ROUTER));
        loopersOf[msg.sender].push(looper);
        emit LooperDeployed(msg.sender, looper);
    }
    function loopersCount(address user) external view returns (uint256) {
        return loopersOf[user].length;
    }
}
