// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/** @title Decentralized Stable Coin (DSC) Engine
 * @author unorthod0xd
 * @notice This contract is the core of the Decentralized Stable Coin system.
 * It handles all logic for minting and redeeming DSC, as well as maintaining
 * the collateralization ratio and liquidation mechanisms.
 * The DSC system is designed to be over-collateralized. All collateral >= the value of the DSC minted.
 * @notice This stablecoin is pegged to the USD ($1.00) and is backed by crypto assets (e.g., ETH, BTC).
 * - Exogenous: Pegged to USD via Chainlink oracles
 * - Decentralized: It is similar to DAI but has no governance, fees and is  only backed by wETH and wBTC
 * @notice This contract is not audited and should not be used in production environments!
 * @dev This contract is a simplified version and does not include all functionalities.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////////////////////////////////////////////////////////////////
    //                                  ERRORS                                   //
    ///////////////////////////////////////////////////////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAndPriceFeedLengthMismatch();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);

    ///////////////////////////////////////////////////////////////////////////////
    //                             STATE VARIABLES                               //
    ///////////////////////////////////////////////////////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable I_DSC;

    ///////////////////////////////////////////////////////////////////////////////
    //                                  EVENTS                                   //
    ///////////////////////////////////////////////////////////////////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountCollateral);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    ///////////////////////////////////////////////////////////////////////////////
    //                                MODIFIERS                                  //
    ///////////////////////////////////////////////////////////////////////////////
    /**
     * @notice Ensures that the provided amount is greater than zero
     * @param amount The amount to validate
     * @dev Reverts with DSCEngine__NeedsMoreThanZero if amount is zero
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @notice Validates that the token is supported as collateral in the system
     * @param token The address of the token to validate
     * @dev Checks if the token has a registered price feed in the s_priceFeeds mapping
     * @dev Reverts with DSCEngine__NotAllowedToken if the token is not supported
     */
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////////////////////////////////////////////////////////////////
    //                                FUNCTIONS                                  //
    ///////////////////////////////////////////////////////////////////////////////

    // Constructor
    /**
     * @notice Initializes the DSCEngine contract with supported collateral tokens and their price feeds
     * @param tokenAddresses Array of ERC20 token addresses that can be used as collateral (e.g., wETH, wBTC)
     * @param priceFeedAddresses Array of Chainlink price feed addresses corresponding to each collateral token
     * @param dscAddress The address of the DecentralizedStableCoin (DSC) token contract
     * @dev The tokenAddresses and priceFeedAddresses arrays must have matching lengths and indices
     * @dev Each token address is mapped to its corresponding price feed for USD value calculations
     * @dev Reverts with DSCEngine__TokenAndPriceFeedLengthMismatch if array lengths don't match
     */
    constructor(address[] memory tokenAddresses,
                address[] memory priceFeedAddresses,
                address dscAddress)
                {
                    if (tokenAddresses.length != priceFeedAddresses.length) {
                        revert DSCEngine__TokenAndPriceFeedLengthMismatch();
                    }

                    for (uint256 i = 0; i < tokenAddresses.length; i++) {
                        s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
                        s_collateralTokens.push(tokenAddresses[i]);
                    }
                    I_DSC = DecentralizedStableCoin(dscAddress);
                }

    ///////////////////////////////////////////////////////////////////////////////
    //                           EXTERNAL FUNCTIONS                              //
    ///////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deposits collateral and mints DSC tokens in a single transaction
     * @param tokenCollateralAddress The ERC20 token address of the collateral being deposited
     * @param amountCollateral The amount of collateral tokens to deposit
     * @param amountDSCToMint The amount of DSC tokens to mint (in wei, 18 decimals)
     * @dev This is a convenience function that combines depositCollateral() and mintDSC() operations
     * @dev The caller must have approved this contract to spend at least `amountCollateral` tokens
     * @dev Both operations must succeed for the transaction to complete
     * @dev The health factor is checked after minting to ensure the position remains overcollateralized
     * @dev Reverts with DSCEngine__NeedsMoreThanZero if amountCollateral or amountDSCToMint is 0
     * @dev Reverts with DSCEngine__NotAllowedToken if the token is not supported
     * @dev Reverts with DSCEngine__TransferFailed if the collateral token transfer fails
     * @dev Reverts with DSCEngine__BreaksHealthFactor if the health factor is insufficient after minting
     * @dev Protected against reentrancy attacks via nonReentrant modifier on called functions
     * Emits a {CollateralDeposited} event upon successful collateral deposit
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint) external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice Allows users to deposit ERC20 collateral tokens (wETH, wBTC) into the protocol
     * @param tokenCollateralAddress The ERC20 token address of the collateral being deposited
     * @param amountCollateral The amount of collateral tokens to deposit
     * @dev This function follows the CEI (Checks-Effects-Interactions) pattern to prevent reentrancy attacks
     * @dev The caller must have approved this contract to spend at least `amountCollateral` tokens
     * @dev Only tokens with registered price feeds are accepted as collateral
     * @dev Reverts with DSCEngine__NeedsMoreThanZero if amountCollateral is 0
     * @dev Reverts with DSCEngine__NotAllowedToken if the token is not supported
     * @dev Reverts with DSCEngine__TransferFailed if the token transfer fails
     * Emits a {CollateralDeposited} event upon successful deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral)

        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Burns DSC tokens and redeems collateral in a single transaction
     * @param tokenCollateralAddress The ERC20 token address of the collateral to redeem
     * @param amountCollateral The amount of collateral tokens to redeem
     * @param amountDscToBurn The amount of DSC tokens to burn (in wei, 18 decimals)
     * @dev This is a convenience function that combines burnDSC() and redeemCollateral() operations
     * @dev Burns DSC first to improve health factor before withdrawing collateral
     * @dev The caller must have approved this contract to spend at least `amountDscToBurn` DSC tokens
     * @dev The caller must have at least `amountCollateral` of the specified collateral deposited
     * Emits a {CollateralRedeemed} event upon successful collateral redemption
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral,
    uint256 amountDscToBurn)
    external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks health factor
    }

    /**
     * @notice Allows users to redeem (withdraw) their deposited collateral tokens
     * @param tokenCollateralAddress The ERC20 token address of the collateral to redeem
     * @param amountCollateral The amount of collateral tokens to withdraw
     * @dev This function allows users to withdraw collateral while maintaining system health
     * @dev The user must have at least `amountCollateral` of the specified token deposited
     * @dev The health factor is checked after withdrawal to ensure position remains overcollateralized
     * @dev Protected against reentrancy attacks via nonReentrant modifier
     * Emits a {CollateralRedeemed} event upon successful withdrawal
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public
    moreThanZero(amountCollateral)
    nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mints DSC (Decentralized Stablecoin) tokens to the caller's address
     * @param amountDSCToMint The amount of DSC tokens to mint (in wei, 18 decimals)
     * @dev This function follows the CEI (Checks-Effects-Interactions) pattern
     * @dev The caller must have sufficient collateral deposited to maintain health factor above 1
     * @dev The health factor is checked after minting to ensure the position remains overcollateralized
     * @dev Reverts with DSCEngine__NeedsMoreThanZero if amountDSCToMint is 0
     * @dev Reverts if the health factor breaks after minting (undercollateralized position)
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant 
    {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = I_DSC.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Burns (destroys) DSC tokens to reduce the caller's debt position
     * @param amount The amount of DSC tokens to burn (in wei, 18 decimals)
     * @dev This function allows users to burn DSC tokens they have minted to reduce their debt
     * @dev The caller must have at least `amount` DSC tokens minted via this contract
     * @dev The caller must have approved this contract to spend at least `amount` DSC tokens
     * @dev Burning DSC improves the user's health factor by reducing their debt
     */
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = I_DSC.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////////////////////////////////////////////////
    //                      PRIVATE & INTERNAL FUNCTIONS                         //
    ///////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Retrieves the account information for a given user
     * @param user The address of the user to query
     * @return totalDSCMinted The total amount of DSC tokens minted by the user
     * @return collateralValueInUsd The total USD value of all collateral deposited by the user
     * @dev This is a helper function used internally to calculate health factors and account status
     * @dev The collateral value is calculated by aggregating all deposited collateral tokens at current prices
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * @notice Calculates the health factor for a given user's position
     * @param user The address of the user whose health factor to calculate
     * @return healthFactor The calculated health factor with 18 decimal precision
     * @dev Health factor = (collateralValueInUsd * LIQUIDATION_THRESHOLD * PRECISION) / (LIQUIDATION_PRECISION * totalDSCMinted)
     * @dev A health factor below 1e18 (1.0) indicates an undercollateralized position eligible for liquidation
     * @dev A health factor of 1e18 means exactly at the liquidation threshold (e.g., 50% for 200% collateral ratio)
     * @dev Health factor above 1e18 indicates a healthy, overcollateralized position
     * @dev Returns type(uint256).max if no DSC has been minted (infinite health factor)
     */
    function _calculateHealthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    /**
     * @notice Calculates health factor given DSC minted and collateral value
     * @param totalDSCMinted The total amount of DSC tokens minted
     * @param collateralValueInUsd The total collateral value in USD
     * @return healthFactor The calculated health factor with 18 decimal precision
     * @dev This is an internal helper for health factor calculations
     */
    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    /**
     * @notice Checks if a user's health factor is below the minimum threshold and reverts if so
     * @param user The address of the user to check
     * @dev Calculates the user's current health factor and compares it to MIN_HEALTH_FACTOR (1e18)
     * @dev Reverts with DSCEngine__BreaksHealthFactor if the health factor is below the minimum
     * @dev This function is called after operations that could affect collateralization (minting, withdrawing)
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _calculateHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////
    //                    PUBLIC & EXTERNAL VIEW FUNCTIONS                       //
    ///////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculates the total USD value of all collateral deposited by a user
     * @param user The address of the user whose collateral to value
     * @return totalCollateralValueInUsd The total value of all deposited collateral in USD (18 decimals)
     * @dev Iterates through all supported collateral tokens and sums their USD values
     * @dev Uses Chainlink price feeds to get current market prices for each collateral token
     * @dev Returns 0 if the user has no collateral deposited
     */
    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        for(uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Converts a token amount to its equivalent USD value using Chainlink price feeds
     * @param token The address of the token to price
     * @param amount The amount of tokens to convert (in token's native decimals)
     * @return The USD value of the token amount with 18 decimals of precision
     * @dev Fetches the latest price from the Chainlink price feed for the given token
     * @dev Chainlink prices typically have 8 decimals, so we multiply by ADDITIONAL_FEED_PRECISION (1e10)
     * @dev Example: 1 ETH at $3500 -> Chainlink returns 3500e8 -> Result is 3500e18
     * @dev The final calculation is: (price * 1e10 * amount) / 1e18
     */
    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}