  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.19;

  /**
   * @title Euler + Pendle PT-USDe Looping Strategy (This contract CAN be used for looping other assets on Pendle X Euler (if available) 
   * @notice Loop: borrow eUSDe -> unwrap to USDe -> mint PT+YT -> deposit PT as collateral.
   *         Unwind: single EVC batch (deferred health checks) -> withdraw ALL PT,
   *         redeem PT+YT to USDe, wrap to eUSDe, repay.
   *
   * VERIFIED ON-CHAIN (Ethereum mainnet, June 2026):
   *   - EUSDE_VAULT.asset() == eUSDe (0x90D2...) which is ERC-4626 over USDe
   *   - SY-USDe getTokensIn() == getTokensOut() == [USDe] only
   *
   * MUST FORK-TEST BEFORE FUNDING:
   *   1. eUSDe.redeem() AND eUSDe.deposit() are currently open (pre-deposit vaults can lock a side)
   *   2. Full cycle: executeLoop -> unwind leaves debt == 0 and all funds at owner
   *   3. Post-expiry: unwind still works after PT maturity
   */

  interface IERC20 {
      function balanceOf(address) external view returns (uint256);
      function transfer(address, uint256) external returns (bool);
      function approve(address, uint256) external returns (bool);
      function transferFrom(address, address, uint256) external returns (bool);
  }

  interface IERC4626 {
      function deposit(uint256 assets, address receiver) external returns
  (uint256 shares);
      function redeem(uint256 shares, address receiver, address owner) external
  returns (uint256 assets);
  }

  // ==================== EULER ====================

  interface IEVault {
      function deposit(uint256 amount, address receiver) external returns
  (uint256);
      function redeem(uint256 shares, address receiver, address owner) external
  returns (uint256);
      function borrow(uint256 amount, address receiver) external returns
  (uint256);
      function repay(uint256 amount, address receiver) external returns
  (uint256);
      function debtOf(address account) external view returns (uint256);
      function asset() external view returns (address);
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

  struct SwapData { SwapType swapType; address extRouter; bytes extCalldata;
  bool needScale; }
  enum SwapType { NONE, KYBERSWAP, ONE_INCH, ETH_WETH }

  struct TokenInput {
      address tokenIn;
      uint256 netTokenIn;
      address tokenMintSy;
      address bulk;
      address pendleSwap;
      SwapData swapData;
  }

  interface IPendleRouterV4 {
      function mintPyFromToken(address receiver, address YT, uint256 minPyOut,
  TokenInput calldata input)
          external payable returns (uint256 netPyOut);
      function redeemPyToSy(address receiver, address YT, uint256 netPyIn,
  uint256 minSyOut)
          external returns (uint256 netSyOut);
  }

  interface ISYToken {
      function redeem(address receiver, uint256 shares, address tokenOut,
  uint256 minTokenOut, bool burnFromInternalBalance)
          external returns (uint256 amountTokenOut);
  }

  interface IYT {
      function isExpired() external view returns (bool);
  }

  contract EulerPendleLoop {

      // ==================== CONSTANTS (Ethereum mainnet) ====================

      address public constant EVC             =
  0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
      address public constant EULER_PT_VAULT  =
  0xb53b4B2590457bE63E1DCdAffa6a18ECd44D96D2; // PT collateral vault
      address public constant EUSDE_VAULT     =
  0x61aAC438453d6e3513C0c8dbb69F13860E2B5028; // eUSDe debt vault
      address public constant EUSDE           =
  0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F; // Ethena eUSDe (4626 over USDe)

      address public constant PENDLE_ROUTER   =
  0x888888888889758F76e7103c6CbF23ABbF58F946;
      address public constant SY_USDE         =
  0xf3DbdE762E5B67FaD09d88da3dfD38A83f753FFe;
      address public constant PT_USDE         =
  0xBC6736d346a5eBC0dEbc997397912CD9b8FAe10a;
      address public constant YT_USDE         =
  0x48bbbEdc4d2491cc08915D7a5c7cc8A8EdF165da;
      address public constant USDE            =
  0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

      address public immutable owner;

      // Unwind params staged for the EVC-batch callback; zeroed when idle.
      uint256 private _unwindBps;
      uint256 private _unwindMinUsdeOut;

      // ==================== EVENTS ====================

      event LoopStep(uint256 iteration, uint256 borrowedEusde, uint256
  usdeMinted, uint256 ptMinted);
      event Unwound(uint256 sharesRedeemed, uint256 usdeRecovered, uint256
  debtRepaid, uint256 debtRemaining);

      modifier onlyOwner() {
          require(msg.sender == owner, "not owner");
          _;
      }

      constructor() {
          owner = msg.sender;
          IEVC(EVC).enableCollateral(address(this), EULER_PT_VAULT);
          IEVC(EVC).enableController(address(this), EUSDE_VAULT);
      }

      // ==================== ENTRY ====================

      /**
       * @notice Open/extend the loop.
       * @param initialUsde USDe pulled from owner to seed the position (0 to
  only re-loop).
       * @param borrowAmounts eUSDe to borrow per iteration, sized off-chain by
  owner.
       *        Each borrow must pass the vault's own health check or the tx
  reverts.
       * @param minPtBps min PT out per 1 USDe in, in bps (e.g. 9950 = 0.5%
  tolerance).
       */
      function executeLoop(uint256 initialUsde, uint256[] calldata
  borrowAmounts, uint256 minPtBps)
          external onlyOwner
      {
          if (initialUsde > 0) {
              IERC20(USDE).transferFrom(msg.sender, address(this), initialUsde);
              _depositPT(_mintPT(initialUsde, minPtBps));
          }

          for (uint256 i = 0; i < borrowAmounts.length; i++) {
              uint256 borrowed = IEVault(EUSDE_VAULT).borrow(borrowAmounts[i], address(this));
              // eUSDe -> USDe (verified: SY only accepts USDe)
              uint256 usde = IERC4626(EUSDE).redeem(borrowed, address(this), address(this));
              uint256 pt = _mintPT(usde, minPtBps);
              _depositPT(pt);
              emit LoopStep(i + 1, borrowed, usde, pt);
          }
      }

      function _mintPT(uint256 usdeAmount, uint256 minPtBps) internal returns (uint256 ptOut) {
          IERC20(USDE).approve(PENDLE_ROUTER, usdeAmount);
          ptOut = IPendleRouterV4(PENDLE_ROUTER).mintPyFromToken(
              address(this),
              YT_USDE,
              (usdeAmount * minPtBps) / 10_000,
              TokenInput({
                  tokenIn: USDE,
                  netTokenIn: usdeAmount,
                  tokenMintSy: USDE, // the SY-accepted token
                  bulk: address(0),
                  pendleSwap: address(0),
                  swapData: SwapData(SwapType.NONE, address(0), "", false)
              })
          );
      }

      function _depositPT(uint256 ptAmount) internal {
          IERC20(PT_USDE).approve(EULER_PT_VAULT, ptAmount);
          IEVault(EULER_PT_VAULT).deposit(ptAmount, address(this));
      }

      // ==================== EXIT (single EVC batch, deferred checks) ====================

      /**
       * @notice Unwind sharePctBps of the position (10_000 = full close).
       *         Health checks defer to batch end, so collateral comes ou BEFORE repay.
       *         Collateral only ever flows back to this contract; funds then go to hardcoded owner.
       */
      function unwind(uint256 sharePctBps, uint256 minUsdeOut) external onlyOwner {
          require(sharePctBps > 0 && sharePctBps <= 10_000, "bad pct");
          _unwindBps = sharePctBps;
          _unwindMinUsdeOut = minUsdeOut;

          IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
          items[0] = IEVC.BatchItem({
              targetContract: address(this),
              onBehalfOfAccount: address(this),
              value: 0,
              data: abi.encodeCall(this.unwindStep, ())
          });
          IEVC(EVC).batch(items);

          _unwindBps = 0;
          _unwindMinUsdeOut = 0;
          _sweepToOwner();
      }

      /// @dev Only reachable via EVC.batch initiated by unwind() (flag-gated). 
    function unwindStep() external {
          require(msg.sender == EVC, "only EVC");
          uint256 bps = _unwindBps;
          require(bps != 0, "not unwinding");

          // 1. Pull PT collateral back into this contract (status check deferred)
          uint256 shares = (IEVault(EULER_PT_VAULT).balanceOf(address(this)) *  bps) / 10_000;
          uint256 ptOut = IEVault(EULER_PT_VAULT).redeem(shares, address(this), address(this));

          // 2. PT (+YT pre or post expiry) -> SY -> USDe
          uint256 usdeOut = _redeemPY(ptOut);
          require(usdeOut >= _unwindMinUsdeOut, "slippage");

          // 3. USDe -> eUSDe -> repay
          IERC20(USDE).approve(EUSDE, usdeOut);
          uint256 eusdeBal = IERC4626(EUSDE).deposit(usdeOut, address(this));
          uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
          uint256 repayAmount = eusdeBal < debt ? eusdeBal : debt;
          if (repayAmount > 0) {
              IERC20(EUSDE).approve(EUSDE_VAULT, repayAmount);
              IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
          }

          uint256 remaining = IEVault(EUSDE_VAULT).debtOf(address(this));
          if (bps == 10_000) {
              require(remaining == 0, "shortfall: top up via emergencyRepayUSDe first");
              IEVault(EUSDE_VAULT).disableController(); // fully release the account
          }
          // Partial unwinds settle at batch end: proportional withdraw+repay keeps health.
             emit Unwound(shares, usdeOut, repayAmount, remaining);
      }

      function _redeemPY(uint256 ptAmount) internal returns (uint256 usdeOut) {
          if (ptAmount == 0) return 0;
          uint256 pyIn = ptAmount;
          IERC20(PT_USDE).approve(PENDLE_ROUTER, pyIn);
          if (!IYT(YT_USDE).isExpired()) {
              // Pre-expiry burns PT+YT 1:1; both never leave the contract so balances match.
              uint256 ytBal = IERC20(YT_USDE).balanceOf(address(this));
              if (ytBal < pyIn) pyIn = ytBal;
              IERC20(YT_USDE).approve(PENDLE_ROUTER, pyIn);
          }
          uint256 syOut =
  IPendleRouterV4(PENDLE_ROUTER).redeemPyToSy(address(this), YT_USDE, pyIn, 0);
          // burnFromInternalBalance
          usdeOut = ISYToken(SY_USDE).redeem(address(this), syOut, USDE, 0, false);
      }

      // ==================== RECOVERY ====================

      /// @notice Owner injects USDe to cover a debt shortfall (wrapped to eUSDe and repaid).
      function emergencyRepayUSDe(uint256 usdeAmount) external onlyOwner {
          IERC20(USDE).transferFrom(msg.sender, address(this), usdeAmount);
          IERC20(USDE).approve(EUSDE, usdeAmount);
          uint256 eusdeBal = IERC4626(EUSDE).deposit(usdeAmount, address(this));
          uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
          uint256 repayAmount = eusdeBal < debt ? eusdeBal : debt;
          IERC20(EUSDE).approve(EUSDE_VAULT, repayAmount);
          IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
      }

      function rescueToken(address token, uint256 amount) external onlyOwner {
          IERC20(token).transfer(owner, amount);
      }

      /// @notice Sweep every known token including Euler PT-vault shares to owner.
      ///  Share transfer only passes EVC checks at zero debt
      function emergencyRescueAllFunds() external onlyOwner {
          _sweepToOwner();
          uint256 shares = IERC20(EULER_PT_VAULT).balanceOf(address(this));
          if (shares > 0) IERC20(EULER_PT_VAULT).transfer(owner, shares);
      }

      function _sweepToOwner() internal {
          address[5] memory tokens = [USDE, EUSDE, PT_USDE, YT_USDE, SY_USDE];
          for (uint256 i = 0; i < tokens.length; i++) {
              uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
              if (bal > 0) IERC20(tokens[i]).transfer(owner, bal);
          }
      }

      // ==================== VIEWS ====================

      function getPositionInfo() external view returns (
          uint256 ptCollateralShares,
          uint256 ytHeld,
          uint256 eusdeDebt
      ) {
          ptCollateralShares = IEVault(EULER_PT_VAULT).balanceOf(address(this));
          ytHeld = IERC20(YT_USDE).balanceOf(address(this));
          eusdeDebt = IEVault(EUSDE_VAULT).debtOf(address(this));
      }
  }
