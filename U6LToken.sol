// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract U6LToken is ERC20, Ownable {
    using Math for uint256;

    // Fee variables
    uint256 public liquidityFee = 3;
    uint256 public reflectionFee = 2;
    uint256 public stakingFee = 2;
    uint256 public marketingFee = 3;
    uint256 public totalFees = 10; // 10% total fees

    // Fee recipients
    address public marketingWallet;
    address public stakingWallet;

    // Uniswap router and pair addresses
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    // Rebase variables
    uint256 public rebaseFrequency = 24 hours;
    uint256 public lastRebaseTime;
    uint256 public rebaseRate = 1; // 0.1% daily rebase

    // Trading control
    bool public tradingEnabled = false;
    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExcludedFromRebase;

    // Anti-whale mechanism
    uint256 public maxTransactionAmount;
    uint256 public maxWalletAmount;

    // Events
    event Rebase(uint256 totalSupply, uint256 rebaseRate);
    event FeesUpdated(uint256 liquidityFee, uint256 reflectionFee, uint256 stakingFee, uint256 marketingFee);
    event ExcludeFromFees(address indexed account, bool excluded);
    event ExcludeFromRebase(address indexed account, bool excluded);
    event TradingEnabled(bool enabled);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity);

    // Constructor
    constructor(
        address _marketingWallet,
        address _stakingWallet,
        address _router
    ) ERC20("U6L Token", "U6L") Ownable(msg.sender) {
        marketingWallet = _marketingWallet;
        stakingWallet = _stakingWallet;

        // Set up Uniswap router (using QuickSwap on Polygon)
        uniswapV2Router = IUniswapV2Router02(_router);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());

        // Initial supply: 21 million (like Bitcoin)
        uint256 initialSupply = 21_000_000 * 10**decimals();
        
        // Set max transaction and wallet amounts
        maxTransactionAmount = initialSupply * 1 / 100; // 1% of total supply
        maxWalletAmount = initialSupply * 2 / 100; // 2% of total supply

        // Exclude contract and fee recipients from fees and rebase
        _excludeFromFeesAndRebase(address(this));
        _excludeFromFeesAndRebase(owner());
        _excludeFromFeesAndRebase(marketingWallet);
        _excludeFromFeesAndRebase(stakingWallet);
        _excludeFromFeesAndRebase(address(0xdead));

        // Mint initial supply to deployer
        _mint(msg.sender, initialSupply);
        
        // Set initial rebase timestamp
        lastRebaseTime = block.timestamp;
    }

    // Override transfer function to implement fees and limits
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Check trading status
        if (!tradingEnabled && 
            from != owner() && 
            to != owner() && 
            from != address(0) && 
            to != address(0xdead)) {
            revert("Trading not enabled yet");
        }

        // Check transaction limits
        if (from != owner() && to != owner() && to != address(0) && from != address(0)) {
            // Max transaction amount check
            if (amount > maxTransactionAmount) {
                revert("Transfer amount exceeds the max transaction amount");
            }

            // Max wallet amount check
            if (to != uniswapV2Pair) {
                uint256 toBalance = balanceOf(to);
                if (toBalance + amount > maxWalletAmount) {
                    revert("Recipient would exceed max wallet amount");
                }
            }
        }

        // Check if rebase should occur
        if (block.timestamp >= lastRebaseTime + rebaseFrequency) {
            _rebase();
        }

        // Process fees if applicable
        if (!isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            uint256 fees = amount * totalFees / 100;
            uint256 liquidityAmount = amount * liquidityFee / 100;
            uint256 reflectionAmount = amount * reflectionFee / 100;
            uint256 stakingAmount = amount * stakingFee / 100;
            uint256 marketingAmount = amount * marketingFee / 100;

            // Transfer fees to contract for processing
            super._update(from, address(this), liquidityAmount);
            
            // Reflection fee is redistributed to holders
            if (reflectionAmount > 0) {
                _redistribute(reflectionAmount);
            }
            
            // Transfer staking fee to staking wallet
            if (stakingAmount > 0) {
                super._update(from, stakingWallet, stakingAmount);
            }
            
            // Transfer marketing fee to marketing wallet
            if (marketingAmount > 0) {
                super._update(from, marketingWallet, marketingAmount);
            }
            
            // Adjust amount to transfer after fees
            amount -= fees;
        }

        // Execute the transfer
        super._update(from, to, amount);
    }

    // Rebase function to implement auto-staking
    function _rebase() internal {
        if (totalSupply() == 0) return;

        // Calculate rebase amount (0.1% of total supply)
        uint256 rebaseAmount = totalSupply() * rebaseRate / 1000;
        
        // Mint new tokens to this contract
        _mint(address(this), rebaseAmount);
        
        // Distribute to non-excluded holders
        _redistributeRebase(rebaseAmount);
        
        // Update last rebase time
        lastRebaseTime = block.timestamp;
        
        emit Rebase(totalSupply(), rebaseRate);
    }

    // Redistribute reflection fees to holders
    function _redistribute(uint256 amount) internal {
        // Burn the reflection amount (effectively redistributing to all holders proportionally)
        super._update(address(this), address(0xdead), amount);
    }

    // Redistribute rebase tokens to non-excluded holders
    function _redistributeRebase(uint256 amount) internal {
        // Simple implementation: burn tokens to redistribute proportionally
        // A more complex implementation would directly distribute to holders
        super._update(address(this), address(0xdead), amount);
    }

    // Process accumulated tokens for liquidity
    function swapAndLiquify() external {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) return;
        
        // Split the contract balance into halves
        uint256 half = contractBalance / 2;
        uint256 otherHalf = contractBalance - half;
        
        // Capture the contract's current ETH balance
        uint256 initialBalance = address(this).balance;
        
        // Swap tokens for ETH
        _swapTokensForEth(half);
        
        // Calculate how much ETH was received
        uint256 newBalance = address(this).balance - initialBalance;
        
        // Add liquidity to Uniswap
        _addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    // Swap tokens for ETH
    function _swapTokensForEth(uint256 tokenAmount) private {
        // Generate the Uniswap pair path of token -> WETH
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        // Approve the router to spend tokens
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // Make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // Accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    // Add liquidity to Uniswap
    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // Approve token transfer to router
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // Add the liquidity
        uniswapV2Router.addLiquidityETH{
            value: ethAmount
        }(
            address(this),
            tokenAmount,
            0, // Slippage is unavoidable
            0, // Slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    // Exclude account from fees and rebase
    function _excludeFromFeesAndRebase(address account) private {
        isExcludedFromFees[account] = true;
        isExcludedFromRebase[account] = true;
    }

    // Owner functions to manage the token
    function setFees(
        uint256 _liquidityFee,
        uint256 _reflectionFee,
        uint256 _stakingFee,
        uint256 _marketingFee
    ) external onlyOwner {
        liquidityFee = _liquidityFee;
        reflectionFee = _reflectionFee;
        stakingFee = _stakingFee;
        marketingFee = _marketingFee;
        totalFees = _liquidityFee + _reflectionFee + _stakingFee + _marketingFee;
        
        // Ensure total fees don't exceed 25%
        require(totalFees <= 25, "Total fees cannot exceed 25%");
        
        emit FeesUpdated(_liquidityFee, _reflectionFee, _stakingFee, _marketingFee);
    }

    function setRebaseRate(uint256 _rebaseRate) external onlyOwner {
        require(_rebaseRate <= 10, "Rebase rate cannot exceed 1%");
        rebaseRate = _rebaseRate;
    }

    function setRebaseFrequency(uint256 _rebaseFrequency) external onlyOwner {
        rebaseFrequency = _rebaseFrequency;
    }

    function setMaxTransactionAmount(uint256 _maxTxAmount) external onlyOwner {
        maxTransactionAmount = _maxTxAmount;
    }

    function setMaxWalletAmount(uint256 _maxWalletAmount) external onlyOwner {
        maxWalletAmount = _maxWalletAmount;
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function excludeFromRebase(address account, bool excluded) external onlyOwner {
        isExcludedFromRebase[account] = excluded;
        emit ExcludeFromRebase(account, excluded);
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled(true);
    }

    function updateMarketingWallet(address _marketingWallet) external onlyOwner {
        require(_marketingWallet != address(0), "Marketing wallet cannot be zero address");
        marketingWallet = _marketingWallet;
    }

    function updateStakingWallet(address _stakingWallet) external onlyOwner {
        require(_stakingWallet != address(0), "Staking wallet cannot be zero address");
        stakingWallet = _stakingWallet;
    }

    // Required to receive ETH from swaps
    receive() external payable {}
}
