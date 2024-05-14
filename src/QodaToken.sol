// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./CustomErrors.sol";
import "./uniswap/IUniswapV2Factory.sol";

contract QodaToken is ERC20, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Threshold in bps where fee for buying Qoda token cannot go beyond
    uint256 constant BUY_FEE_THRESHOLD_BPS = 500; // 5%

    /// @notice Default fee in bps for buying Qoda token that goes to revenue stream 1
    uint256 constant DEFAULT_BUY_FEE_REV_STREAM_1_BPS = 0; // 0%

    /// @notice Default fee in bps for buying Qoda token that goes to revenue stream 2
    uint256 constant DEFAULT_BUY_FEE_REV_STREAM_2_BPS = 0; // 0%

    /// @notice Threshold where fee for selling Qoda token cannot go beyond
    uint256 constant SELL_FEE_THRESHOLD_BPS = 500; // 5%

    /// @notice Default fee in bps for selling Qoda token that goes to revenue stream 1
    uint256 constant DEFAULT_SELL_FEE_REV_STREAM_1_BPS = 200; // 2%

    /// @notice Default fee in bps for selling Qoda token that goes to revenue stream 2
    uint256 constant DEFAULT_SELL_FEE_REV_STREAM_2_BPS = 0; // 0%

    /// @notice Scale factor for fee (1 = 10000 bps)
    uint256 public constant SCALE_FACTOR_FEE = 10000;

    /// @notice Total amount of Qoda token that will be issued
    uint256 constant TOTAL_TOKEN_SUPPLY = 1_000_000_000; // 1 billion

    // Fee charged when conversion to Qoda token is done, unit in basis point
    uint256 public buyRevStream1Fee;
    uint256 public buyRevStream2Fee;

    // Fee charged when conversion from Qoda token is done, unit in basis point
    uint256 public sellRevStream1Fee;
    uint256 public sellRevStream2Fee;

    // Wallet for fee collection
    address public revStream1Wallet;
    address public revStream2Wallet;

    // store addresses of AMM pairs
    mapping(address => bool) public automatedMarketMakerPairs;

    // exclude from fees
    mapping(address => bool) private _isExcludedFromFees;

    event ExcludeFromFees(address indexed account, bool indexed isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event RevStream1WalletUpdated(address indexed newWallet, address indexed oldWallet);

    event RevStream2WalletUpdated(address indexed newWallet, address indexed oldWallet);

    /// @param name_ Name of ERC20 token
    /// @param symbol_ Symbol of ERC20 token
    /// @param tokenAddress_ Token for creating initial uniswap pair
    /// @param uniswapFactory_ Uniswap Factory for swap pair creation
    /// @param revStream1Wallet_ Address for rev stream 1, can be set to 0 for token burning
    /// @param revStream2Wallet_ Address for rev stream 2, can be set to 0 for token burning
    constructor(
        string memory name_,
        string memory symbol_,
        address tokenAddress_,
        address uniswapFactory_,
        address revStream1Wallet_,
        address revStream2Wallet_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        // Create uniswap pair
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(uniswapFactory_);
        address uniswapV2Pair = uniswapFactory.createPair(address(this), tokenAddress_);
        setAutomatedMarketMakerPair(uniswapV2Pair, true);

        // Setting up default revenue stream wallet
        updateRevStream1Wallet(revStream1Wallet_);
        updateRevStream2Wallet(revStream2Wallet_);

        // Setting up default fee to be charged during token conversion
        updateBuyFees(DEFAULT_BUY_FEE_REV_STREAM_1_BPS, DEFAULT_BUY_FEE_REV_STREAM_2_BPS);
        updateSellFees(DEFAULT_SELL_FEE_REV_STREAM_1_BPS, DEFAULT_SELL_FEE_REV_STREAM_2_BPS);

        // exclude token address itself from paying fees
        excludeFromFees(address(this), true);

        // mint initial total supply, further minting will not be allowed
        super._update(address(0), msg.sender, TOTAL_TOKEN_SUPPLY * 10 ** decimals());
    }

    function _update(address from, address to, uint256 amount) internal override {
        // No further minting will be allowed
        if (from == address(0)) {
            revert CustomErrors.TransferFromZeroAddress();
        }

        // if any account belongs to _isExcludedFromFee account then remove the fee
        bool takeFee = !_isExcludedFromFees[from] && !_isExcludedFromFees[to];

        uint256 fees = 0;
        uint256 revStream1Fee = 0;
        uint256 revStream2Fee = 0;
        uint256 buyTotalFees = buyRevStream1Fee + buyRevStream2Fee;
        uint256 sellTotalFees = sellRevStream1Fee + sellRevStream2Fee;
        // only take fees on buys/sells, do not take on wallet transfers
        if (takeFee) {
            // on sell
            if (automatedMarketMakerPairs[to] && sellTotalFees > 0) {
                fees = amount * sellTotalFees / SCALE_FACTOR_FEE;
                revStream1Fee = fees * sellRevStream1Fee / sellTotalFees;
            }
            // on buy
            else if (automatedMarketMakerPairs[from] && buyTotalFees > 0) {
                fees = amount * buyTotalFees / SCALE_FACTOR_FEE;
                revStream1Fee = fees * buyRevStream1Fee / buyTotalFees;
            }

            revStream2Fee = fees - revStream1Fee;
            amount -= fees;

            // transfer fee to respective rev share wallet
            if (revStream1Fee > 0) {
                super._update(from, revStream1Wallet, revStream1Fee);
            }
            if (revStream2Fee > 0) {
                super._update(from, revStream2Wallet, revStream2Fee);
            }
        }

        if (amount > 0) {
            super._update(from, to, amount);
        }
    }

    //* ADMIN FUNCTIONS *//

    function updateBuyFees(uint256 revStream1Fee_, uint256 revStream2Fee_) public onlyOwner {
        if (revStream1Fee_ + revStream2Fee_ > BUY_FEE_THRESHOLD_BPS) {
            revert CustomErrors.BuyFeesTooHigh();
        }
        buyRevStream1Fee = revStream1Fee_;
        buyRevStream2Fee = revStream2Fee_;
    }

    function updateSellFees(uint256 revStream1Fee_, uint256 revStream2Fee_) public onlyOwner {
        if (revStream1Fee_ + revStream2Fee_ > SELL_FEE_THRESHOLD_BPS) {
            revert CustomErrors.SellFeesTooHigh();
        }
        sellRevStream1Fee = revStream1Fee_;
        sellRevStream2Fee = revStream2Fee_;
    }

    /// @notice Set address for rev stream 1, can be set to 0 for token burning
    function updateRevStream1Wallet(address revStream1Wallet_) public onlyOwner {
        emit RevStream1WalletUpdated(revStream1Wallet_, revStream1Wallet);
        revStream1Wallet = revStream1Wallet_;
    }

    /// @notice Set address for rev stream 2, can be set to 0 for token burning
    function updateRevStream2Wallet(address revStream2Wallet_) public onlyOwner {
        emit RevStream2WalletUpdated(revStream2Wallet_, revStream2Wallet);
        revStream2Wallet = revStream2Wallet_;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        if (account == address(0)) {
            revert CustomErrors.InvalidExclusionAddress();
        }
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        if (pair == address(0)) {
            revert CustomErrors.InvalidAutomatedMarketMakerPairs();
        }
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function burn(uint256 amount) public onlyOwner {
        _burn(msg.sender, amount);
    }
}
