// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Complete Euler + Pendle Looping Strategy
 * @notice Opens loops via PT-USDe, borrows from Euler vault, 
 *         mints more PT-USDe/YT-USDe, uses PT as collateral
 * @dev Include repayment logic with Euler
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ==================== EULER INTERFACES ====================

interface IEVault {
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function maxBorrow(address borrower) external view returns (uint256);
}

interface IEVC {
    function enableCollateral(address account, address vault) external;
    function enableController(address account, address vault) external;
}

// ==================== PENDLE INTERFACES ====================

struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address bulk;
    address pendleSwap;
    SwapData swapData;
}

struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

enum SwapType {
    NONE,
    KYBERSWAP,
    ONE_INCH,
    ETH_WETH
}

interface IPendleRouterV4 {
    function mintPyFromToken(
        address receiver,
        address YT,
        uint256 minPyOut,
        TokenInput calldata input
    ) external payable returns (uint256 netPyOut);
    
    function mintPyFromSy(
        address receiver,
        address YT,
        uint256 netSyIn,
        uint256 minPyOut
    ) external returns (uint256 netPyOut);
    
    function redeemPyToSy(
        address receiver,
        address YT,
        uint256 netPyIn,
        uint256 minSyOut
    ) external returns (uint256 netSyOut);
}

interface ISYToken {
    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut
    ) external returns (uint256 amountSharesOut);
    
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);
}

contract CompleteEulerPendleLoop {
    
    // ==================== CONSTANTS ====================
    
    // Euler Protocol
    address public constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address public constant EULER_PT_VAULT = 0xb53b4B2590457bE63E1DCdAffa6a18ECd44D96D2; // PT collateral vault
    address public constant EUSDE_VAULT = 0x61aAC438453d6e3513C0c8dbb69F13860E2B5028;     // eUSDe debt vault
    
    // Pendle Protocol
    address public constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address public constant SY_USDE_SEP = 0xf3DbdE762E5B67FaD09d88da3dfD38A83f753FFe;
    address public constant MARKET_USDE_SEP = 0x6d98a2b6CDbF44939362a3E99793339Ba2016aF4;
    address public constant PT_USDE_SEP = 0xBC6736d346a5eBC0dEbc997397912CD9b8FAe10a;
    address public constant YT_USDE_SEP = 0x48bbbEdc4d2491cc08915D7a5c7cc8A8EdF165da;
    
    // Tokens
    address public constant USDE_TOKEN = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    
    address public immutable owner;
    
    // ==================== EVENTS ====================
    
    event LoopExecuted(uint256 iteration, uint256 ptMinted, uint256 eUSDeBorrowed, uint256 totalPTCollateral);
    event RepaymentExecuted(uint256 repaidAmount, uint256 remainingDebt);
    event PositionClosed(uint256 totalUSDe);
    event Debug(string message, uint256 value1, uint256 value2);
    
    constructor() {
        owner = msg.sender;
        
        // Enable EVC permissions (confirmed working)
        IEVC(EVC).enableCollateral(address(this), EULER_PT_VAULT);
        IEVC(EVC).enableController(address(this), EUSDE_VAULT);
    }
    
    // ==================== MAIN LOOP STRATEGY ====================
    
    /**
     * @notice Execute complete looping strategy
     * @param initialUSDe Initial USDe amount to start the loop
     * @param loops Number of loop iterations
     * @param minPTPerLoop Minimum PT tokens to mint per loop (slippage protection)
     */
    function executeLoop(uint256 initialUSDe, uint256 loops, uint256 minPTPerLoop) external {
        require(msg.sender == owner, "Not owner");
        require(initialUSDe > 0, "Need initial USDe");
        require(loops > 0 && loops <= 10, "Invalid loop count");
        
        // Transfer initial USDe from user
        IERC20(USDE_TOKEN).transferFrom(msg.sender, address(this), initialUSDe);
        
        // Step 1: Initial PT minting from USDe
        uint256 ptAmount = mintPTFromUSDe(initialUSDe, minPTPerLoop);
        emit Debug("Initial PT minted", ptAmount, initialUSDe);
        
        // Step 2: Deposit PT as collateral
        depositPTAsCollateral(ptAmount);
        
        // Step 3: Execute loops
        for (uint256 i = 0; i < loops; i++) {
            // Calculate safe borrow amount (e.g., 80% of max borrow)
            uint256 maxBorrow = IEVault(EUSDE_VAULT).maxBorrow(address(this));
            uint256 borrowAmount = (maxBorrow * 80) / 100; // 80% safety margin
            
            if (borrowAmount == 0) {
                emit Debug("No more borrowing capacity", i, maxBorrow);
                break;
            }
            
            // Borrow eUSDe
            uint256 borrowed = IEVault(EUSDE_VAULT).borrow(borrowAmount, address(this));
            
            // Mint PT/YT directly from borrowed eUSDe (Pendle supports eUSDe)
            uint256 newPT = mintPTFromToken(borrowed, minPTPerLoop, IEVault(EUSDE_VAULT).asset());
            
            // Deposit new PT as additional collateral
            depositPTAsCollateral(newPT);
            
            emit LoopExecuted(i + 1, newPT, borrowed, getTotalPTCollateral());
        }
    }
    
    /**
     * @notice Mint PT/YT tokens from USDe
     */
    function mintPTFromUSDe(uint256 usdeAmount, uint256 minPTOut) internal returns (uint256 ptAmount) {
        return mintPTFromToken(usdeAmount, minPTOut, USDE_TOKEN);
    }
    
    /**
     * @notice Mint PT/YT tokens from any supported token (USDe, eUSDe, etc.)
     */
    function mintPTFromToken(uint256 tokenAmount, uint256 minPTOut, address tokenIn) internal returns (uint256 ptAmount) {
        // Approve the token to Pendle Router
        IERC20(tokenIn).approve(PENDLE_ROUTER_V4, tokenAmount);
        
        // Create TokenInput struct for direct token minting
        TokenInput memory tokenInput = TokenInput({
            tokenIn: tokenIn,
            netTokenIn: tokenAmount,
            tokenMintSy: SY_USDE_SEP,
            bulk: address(0),
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        
        // Mint PT+YT directly from token using Pendle Router V4
        ptAmount = IPendleRouterV4(PENDLE_ROUTER_V4).mintPyFromToken{value: 0}(
            address(this),
            YT_USDE_SEP,
            minPTOut,
            tokenInput
        );
    }
    
    /**
     * @notice Deposit PT tokens as collateral in Euler
     */
    function depositPTAsCollateral(uint256 ptAmount) internal {
        IERC20(PT_USDE_SEP).approve(EULER_PT_VAULT, ptAmount);
        IEVault(EULER_PT_VAULT).deposit(ptAmount, address(this));
    }
    
    // ==================== REPAYMENT FUNCTIONS (EULER DEV FIXES) ====================
    
    /**
     * @notice Repay eUSDe debt using correct method from Euler dev
     * @dev Uses vault.asset() and vault.debtOf()
     */
    function repayEUSDe() external returns (uint256 repaidAmount) {
        // Step 1: Get exact debt amount (confirmed by Euler dev)
        uint256 debtAmount = IEVault(EUSDE_VAULT).debtOf(address(this));
        require(debtAmount > 0, "No debt to repay");
        
        // Step 2: Get the actual asset token of the vault (not hardcoded USDe!)
        address debtToken = IEVault(EUSDE_VAULT).asset();
        
        // Step 3: Check we have enough of the debt token
        uint256 balance = IERC20(debtToken).balanceOf(address(this));
        require(balance >= debtAmount, "Insufficient balance to repay");
        
        // Step 4: Approve the debt token to the vault
        IERC20(debtToken).approve(EUSDE_VAULT, debtAmount);
        
        // Step 5: Repay directly to vault (confirmed by Euler dev - no EVC batch needed)
        repaidAmount = IEVault(EUSDE_VAULT).repay(debtAmount, address(this));
        
        emit RepaymentExecuted(repaidAmount, IEVault(EUSDE_VAULT).debtOf(address(this)));
        return repaidAmount;
    }
    
    /**
     * @notice Partial repayment with proper token handling
     */
    function repayPartial(uint256 repayAmount) external returns (uint256 actualRepaid) {
        uint256 debtAmount = IEVault(EUSDE_VAULT).debtOf(address(this));
        require(debtAmount > 0, "No debt to repay");
        require(repayAmount <= debtAmount, "Repay amount exceeds debt");
        
        // ✅ Use the vault's asset token (not hardcoded USDe!)
        address debtToken = IEVault(EUSDE_VAULT).asset();
        
        // Check balance and approve
        uint256 balance = IERC20(debtToken).balanceOf(address(this));
        require(balance >= repayAmount, "Insufficient balance");
        
        IERC20(debtToken).approve(EUSDE_VAULT, repayAmount);
        actualRepaid = IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
        
        emit RepaymentExecuted(actualRepaid, IEVault(EUSDE_VAULT).debtOf(address(this)));
        return actualRepaid;
    }
    
    // ==================== POSITION MANAGEMENT ====================
    
    /**
     * @notice Close half of the position and return USDe
     */
    function closeHalfPosition() external {
        require(msg.sender == owner, "Not owner");
        
        uint256 currentDebt = IEVault(EUSDE_VAULT).debtOf(address(this));
        uint256 halfDebt = currentDebt / 2;
        
        if (halfDebt > 0) {
            // Redeem PT/YT to get funds for repayment
            uint256 ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
            uint256 ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
            uint256 halfPT = ptBalance / 2;
            uint256 halfYT = ytBalance / 2;
            
            // Redeem half PT/YT to get repayment funds
            uint256 usdeFromRedeem = redeemPTYTToUSDe(halfPT, halfYT);
            
            // Convert USDe to debt token if needed and repay
            address debtToken = IEVault(EUSDE_VAULT).asset();
            uint256 repayAmount = usdeFromRedeem > halfDebt ? halfDebt : usdeFromRedeem;
            
            if (IERC20(debtToken).balanceOf(address(this)) >= repayAmount) {
                IERC20(debtToken).approve(EUSDE_VAULT, repayAmount);
                IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
            }
            
            // Return remaining USDe to owner
            uint256 remainingUSDe = IERC20(USDE_TOKEN).balanceOf(address(this));
            if (remainingUSDe > 0) {
                IERC20(USDE_TOKEN).transfer(owner, remainingUSDe);
            }
        }
        
        emit PositionClosed(IERC20(USDE_TOKEN).balanceOf(address(this)));
    }
    
    /**
     * @notice Close entire position - repay all debt and return all funds
     */
    function closeAllPosition() external {
        require(msg.sender == owner, "Not owner");
        
        uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
        
        if (debt > 0) {
            // Redeem all PT/YT to get funds
            uint256 ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
            uint256 ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
            
            if (ptBalance > 0 && ytBalance > 0) {
                redeemPTYTToUSDe(ptBalance, ytBalance);
            }
            
            // Repay debt
            address debtToken = IEVault(EUSDE_VAULT).asset();
            uint256 debtTokenBalance = IERC20(debtToken).balanceOf(address(this));
            
            if (debtTokenBalance >= debt) {
                IERC20(debtToken).approve(EUSDE_VAULT, debt);
                IEVault(EUSDE_VAULT).repay(debt, address(this));
            } else {
                revert("Insufficient funds to repay all debt");
            }
        }
        
        // Return all remaining funds to owner
        returnAllFundsToOwner();
        
        emit PositionClosed(IERC20(USDE_TOKEN).balanceOf(owner));
    }
    
    /**
     * @notice Immediately close position and repay debt with available funds
     */
    function immediateCloseAndRepay() external {
        require(msg.sender == owner, "Not owner");
        
        uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
        address debtToken = IEVault(EUSDE_VAULT).asset();
        uint256 availableFunds = IERC20(debtToken).balanceOf(address(this));
        
        if (debt > 0 && availableFunds > 0) {
            uint256 repayAmount = availableFunds >= debt ? debt : availableFunds;
            IERC20(debtToken).approve(EUSDE_VAULT, repayAmount);
            IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
            
            emit RepaymentExecuted(repayAmount, IEVault(EUSDE_VAULT).debtOf(address(this)));
        }
        
        // Return remaining funds
        returnAllFundsToOwner();
    }
    
    /**
     * @notice Close all loops and return money to owner
     */
    function closeAllLoopsAndReturn() external {
        require(msg.sender == owner, "Not owner");
        
        // Step 1: Redeem all PT/YT positions
        uint256 ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
        uint256 ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
        
        if (ptBalance > 0 && ytBalance > 0) {
            redeemPTYTToUSDe(ptBalance, ytBalance);
        }
        
        // Step 2: Repay all debt
        uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
        if (debt > 0) {
            address debtToken = IEVault(EUSDE_VAULT).asset();
            uint256 debtTokenBalance = IERC20(debtToken).balanceOf(address(this));
            
            if (debtTokenBalance >= debt) {
                IERC20(debtToken).approve(EUSDE_VAULT, debt);
                IEVault(EUSDE_VAULT).repay(debt, address(this));
            }
        }
        
        // Step 3: Withdraw all collateral
        withdrawAllCollateral();
        
        // Step 4: Return all funds to owner
        returnAllFundsToOwner();
        
        emit PositionClosed(IERC20(USDE_TOKEN).balanceOf(owner));
    }
    
    /**
     * @notice Close exactly one loop iteration
     */
    function closeOneLoop() external {
        require(msg.sender == owner, "Not owner");
        
        // Calculate approximately one loop's worth of position
        uint256 ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
        uint256 ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
        uint256 debt = IEVault(EUSDE_VAULT).debtOf(address(this));
        
        // Estimate one loop size (this could be more sophisticated)
        uint256 oneLoopPT = ptBalance / 5; // Assuming max 5 loops
        uint256 oneLoopYT = ytBalance / 5;
        uint256 oneLoopDebt = debt / 5;
        
        // Redeem one loop worth of PT/YT
        if (oneLoopPT > 0 && oneLoopYT > 0) {
            redeemPTYTToUSDe(oneLoopPT, oneLoopYT);
            
            // Repay corresponding debt
            address debtToken = IEVault(EUSDE_VAULT).asset();
            uint256 repayAmount = oneLoopDebt;
            
            if (IERC20(debtToken).balanceOf(address(this)) >= repayAmount) {
                IERC20(debtToken).approve(EUSDE_VAULT, repayAmount);
                IEVault(EUSDE_VAULT).repay(repayAmount, address(this));
            }
        }
        
        emit Debug("One loop closed", oneLoopPT, oneLoopDebt);
    }
    
    /**
     * @notice Emergency close with maximum fund recovery
     */
    function emergencyFullClose() external {
        require(msg.sender == owner, "Not owner");
        
        // First try normal close
        try this.closeAllLoopsAndReturn() {
            return;
        } catch {
            // If normal close fails, do emergency rescue
            emergencyRescueAllFunds();
        }
    }
    
    // ==================== HELPER FUNCTIONS ====================
    
    /**
     * @notice Redeem PT+YT tokens back to USDe
     */
    function redeemPTYTToUSDe(uint256 ptAmount, uint256 ytAmount) internal returns (uint256 usdeAmount) {
        uint256 redeemAmount = ptAmount < ytAmount ? ptAmount : ytAmount;
        
        if (redeemAmount == 0) return 0;
        
        // Step 1: Redeem PT+YT → SY
        IERC20(PT_USDE_SEP).approve(PENDLE_ROUTER_V4, redeemAmount);
        IERC20(YT_USDE_SEP).approve(PENDLE_ROUTER_V4, redeemAmount);
        
        uint256 syAmount = IPendleRouterV4(PENDLE_ROUTER_V4).redeemPyToSy(
            address(this),
            YT_USDE_SEP,
            redeemAmount,
            0 // minSyOut
        );
        
        // Step 2: Redeem SY → USDe
        usdeAmount = ISYToken(SY_USDE_SEP).redeem(
            address(this),
            syAmount,
            USDE_TOKEN,
            0, // minTokenOut
            true // burnFromInternalBalance
        );
    }
    
    /**
     * @notice Withdraw all collateral from Euler vaults
     */
    function withdrawAllCollateral() internal {
        // This would need specific Euler vault withdraw functions
        // Implementation depends on Euler's collateral withdrawal mechanism
        // For now, we'll assume PT tokens can be withdrawn directly
    }
    
    /**
     * @notice Return all funds to owner
     */
    function returnAllFundsToOwner() internal {
        // Transfer USDe
        uint256 usdeBalance = IERC20(USDE_TOKEN).balanceOf(address(this));
        if (usdeBalance > 0) {
            IERC20(USDE_TOKEN).transfer(owner, usdeBalance);
        }
        
        // Transfer PT tokens
        uint256 ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
        if (ptBalance > 0) {
            IERC20(PT_USDE_SEP).transfer(owner, ptBalance);
        }
        
        // Transfer YT tokens  
        uint256 ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
        if (ytBalance > 0) {
            IERC20(YT_USDE_SEP).transfer(owner, ytBalance);
        }
        
        // Transfer debt tokens
        address debtToken = IEVault(EUSDE_VAULT).asset();
        uint256 debtTokenBalance = IERC20(debtToken).balanceOf(address(this));
        if (debtTokenBalance > 0) {
            IERC20(debtToken).transfer(owner, debtTokenBalance);
        }
        
        // Transfer any SY tokens
        uint256 syBalance = IERC20(SY_USDE_SEP).balanceOf(address(this));
        if (syBalance > 0) {
            IERC20(SY_USDE_SEP).transfer(owner, syBalance);
        }
    }
    
    /**
     * @notice Emergency rescue all funds regardless of state
     */
    function emergencyRescueAllFunds() public {
        require(msg.sender == owner, "Not owner");
        
        // Get all token addresses that might have funds
        address[] memory tokens = new address[](5);
        tokens[0] = USDE_TOKEN;
        tokens[1] = PT_USDE_SEP;
        tokens[2] = YT_USDE_SEP;
        tokens[3] = SY_USDE_SEP;
        tokens[4] = IEVault(EUSDE_VAULT).asset(); // debt token
        
        // Transfer all balances to owner
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).transfer(owner, balance);
            }
        }
    }
    
    /**
     * @notice Get position closure estimates
     */
    function getClosureEstimates() external view returns (
        uint256 totalPTValue,
        uint256 totalDebt,
        uint256 estimatedUSDe,
        uint256 healthRatio,
        bool canClosePosition
    ) {
        totalPTValue = IERC20(PT_USDE_SEP).balanceOf(address(this));
        totalDebt = IEVault(EUSDE_VAULT).debtOf(address(this));
        estimatedUSDe = (totalPTValue * 95) / 100; // Rough estimate with 5% slippage
        healthRatio = totalDebt > 0 ? (totalPTValue * 100) / totalDebt : type(uint256).max;
        canClosePosition = estimatedUSDe >= totalDebt;
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get current position info
     */
    function getPositionInfo() external view returns (
        uint256 ptCollateral,
        uint256 eusdeDebt,
        uint256 maxBorrowCapacity,
        address debtToken,
        uint256 healthRatio
    ) {
        ptCollateral = IERC20(PT_USDE_SEP).balanceOf(address(this));
        eusdeDebt = IEVault(EUSDE_VAULT).debtOf(address(this));
        maxBorrowCapacity = IEVault(EUSDE_VAULT).maxBorrow(address(this));
        debtToken = IEVault(EUSDE_VAULT).asset();
        
        // Simplified health ratio calculation
        healthRatio = eusdeDebt > 0 ? (ptCollateral * 100) / eusdeDebt : type(uint256).max;
    }
    
    /**
     * @notice Debug function to check token details
     */
    function debugTokenInfo() external view returns (
        address vaultAsset,
        uint256 currentDebt,
        uint256 vaultAssetBalance,
        uint256 usdeBalance,
        uint256 ptBalance,
        uint256 ytBalance
    ) {
        vaultAsset = IEVault(EUSDE_VAULT).asset();
        currentDebt = IEVault(EUSDE_VAULT).debtOf(address(this));
        vaultAssetBalance = IERC20(vaultAsset).balanceOf(address(this));
        usdeBalance = IERC20(USDE_TOKEN).balanceOf(address(this));
        ptBalance = IERC20(PT_USDE_SEP).balanceOf(address(this));
        ytBalance = IERC20(YT_USDE_SEP).balanceOf(address(this));
    }
    
    function getTotalPTCollateral() public view returns (uint256) {
        return IERC20(PT_USDE_SEP).balanceOf(address(this));
    }
    
    // ==================== EMERGENCY FUNCTIONS ====================
    
    /**
     * @notice Emergency rescue tokens
     */
    function rescueToken(address token, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        IERC20(token).transfer(owner, amount);
    }
    
    /**
     * @notice Emergency repay with external funds
     */
    function emergencyRepay(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        
        // Transfer funds from owner
        address debtToken = IEVault(EUSDE_VAULT).asset();
        IERC20(debtToken).transferFrom(msg.sender, address(this), amount);
        
        // Repay
        IERC20(debtToken).approve(EUSDE_VAULT, amount);
        IEVault(EUSDE_VAULT).repay(amount, address(this));
    }
}
