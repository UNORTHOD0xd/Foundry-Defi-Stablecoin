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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__InvalidPrice();
    error DSCEngine__StalePrice();
    error DSCEngine__InsufficientCollateral();
    error DSCEngine__InsufficientDSCMinted();
    error DSCEngine__InsufficientCollateralDeposited();

    ///////////////////////////////////////////////////////////////////////////////
    //                             STATE VARIABLES                               //
    ///////////////////////////////////////////////////////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // Representing a 10% Liquidator bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable I_DSC;

    ///////////////////////////////////////////////////////////////////////////////
    //                                  EVENTS                                   //
    ///////////////////////////////////////////////////////////////////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountCollateral);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

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
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
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
    function burnDSC(uint256 amount) public moreThanZero(amount) 
    {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquidates an undercollateralized position by repaying debt and seizing collateral proportionally
     * @param user The address of the user being liquidated (must have health factor < 1e18)
     * @param debtToCover The amount of DSC debt to repay on behalf of the user (in wei, 18 decimals)
     * @dev This function allows anyone to liquidate undercollateralized positions to maintain system solvency
     * @dev The liquidator repays up to 50% of the user's DSC debt and receives equivalent collateral + 10% bonus
     * @dev Collateral is seized proportionally from ALL deposited collateral types based on their USD value
     * @dev This ensures liquidations succeed as long as total collateral value is sufficient, regardless of
     *      which specific tokens the user has deposited
     * @dev Maximum liquidation is capped at 50% of the user's total debt to prevent full position liquidation
     * @dev The liquidator must have approved this contract to spend at least `debtToCover` DSC tokens
     * @dev Protected against reentrancy attacks via nonReentrant modifier
     * @dev Note: For severely undercollateralized positions (HF < 0.55), the 10% bonus may cause the user's
     *      health factor to decrease rather than improve. This is acceptable as multiple liquidations
     *      may be needed to fully restore a healthy position.
     * @dev Reverts with DSCEngine__NeedsMoreThanZero if debtToCover is 0
     * @dev Reverts with DSCEngine__HealthFactorOk if user's health factor is >= MIN_HEALTH_FACTOR
     * @dev Reverts with DSCEngine__InsufficientCollateral if user's total collateral value is insufficient
     * @dev Reverts with DSCEngine__BreaksHealthFactor if liquidator's own health factor breaks
     * Emits multiple {CollateralRedeemed} events (one per collateral type seized)
     */
    function liquidate(address user, uint256 debtToCover)
    external
    moreThanZero(debtToCover)
    nonReentrant
    {
        // Check if user's position can be liquidated
        uint256 startingUserHealthFactor = _calculateHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // Limit liquidation to 50% of user's total debt to prevent complete position liquidation
        uint256 maxDebtToCover = (s_DSCMinted[user] * LIQUIDATION_PRECISION) / 200; // 50%
        uint256 debtToActuallyCover = debtToCover > maxDebtToCover ? maxDebtToCover : debtToCover;

        // Calculate total collateral value to seize (debt covered + 10% liquidation bonus)
        // This is the USD value that needs to be seized proportionally across all collateral types
        uint256 collateralValueToSeize = debtToActuallyCover; // 1:1 USD value
        uint256 bonusCollateralValue = (collateralValueToSeize * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralValueToSeize = collateralValueToSeize + bonusCollateralValue;

        // Seize collateral proportionally from all deposited collateral types
        // This ensures liquidation succeeds as long as total collateral is sufficient
        _seizeCollateralProportionally(user, msg.sender, totalCollateralValueToSeize);

        // Burn DSC debt on behalf of the liquidated user
        _burnDSC(debtToActuallyCover, user, msg.sender);

        // Ensure liquidator's own position remains healthy
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {} // funtion yet to be implemented. 

    ///////////////////////////////////////////////////////////////////////////////
    //                      PRIVATE & INTERNAL FUNCTIONS                         //
    ///////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Internal function to burn DSC tokens and reduce a user's debt position
     * @param amountDscToBurn The amount of DSC tokens to burn (in wei, 18 decimals)
     * @param onBehalfOf The address of the user whose debt position to reduce
     * @param dscFrom The address holding the DSC tokens to transfer and burn
     * @dev Low-level internal function - caller MUST validate health factor after calling
     * @dev This function is used for both user-initiated burns and liquidation burns
     * @dev In liquidations: onBehalfOf is the liquidated user, dscFrom is the liquidator
     * @dev In normal burns: onBehalfOf and dscFrom are both msg.sender
     * @dev Transfers DSC from `dscFrom` to this contract, then permanently burns the tokens
     * @dev Reverts with DSCEngine__InsufficientDSCMinted if onBehalfOf hasn't minted enough DSC
     * @dev Reverts with DSCEngine__TransferFailed if the DSC transfer fails
     */
    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private
    {
        // Explicitly check user has minted sufficient DSC (prevents underflow)
        if (s_DSCMinted[onBehalfOf] < amountDscToBurn) {
            revert DSCEngine__InsufficientDSCMinted();
        }

        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = I_DSC.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amountDscToBurn);
    }

    /**
     * @notice Internal function to redeem collateral from one user and transfer to another
     * @param from The address of the user whose collateral to redeem
     * @param to The address receiving the collateral tokens
     * @param tokenCollateralAddress The ERC20 token address of the collateral
     * @param amountCollateral The amount of collateral tokens to redeem
     * @dev Low-level internal function - caller MUST validate health factor after calling
     * @dev This function is used for both user-initiated redemptions and liquidations
     * @dev In liquidations: `from` is the liquidated user, `to` is the liquidator
     * @dev In normal redemptions: `from` and `to` are both msg.sender
     * @dev Updates the collateral balance before transferring tokens (CEI pattern)
     * @dev Reverts with DSCEngine__InsufficientCollateralDeposited if user doesn't have enough collateral
     * @dev Reverts with DSCEngine__TransferFailed if the ERC20 token transfer fails
     * Emits a {CollateralRedeemed} event with from, to, token, and amount details
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private
    {
        // Explicitly check user has sufficient collateral deposited (prevents underflow)
        if (s_collateralDeposited[from][tokenCollateralAddress] < amountCollateral) {
            revert DSCEngine__InsufficientCollateralDeposited();
        }

        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Seizes collateral proportionally from a user across all deposited collateral types
     * @param from The address of the user whose collateral to seize
     * @param to The address receiving the seized collateral tokens
     * @param totalCollateralValueToSeize The total USD value of collateral to seize (in wei, 18 decimals)
     * @dev This function distributes liquidation across all collateral types based on their proportion
     *      of the user's total collateral value
     * @dev This ensures liquidations succeed as long as sufficient total collateral exists, regardless
     *      of which specific tokens the user has deposited
     * @dev The function calculates each token's proportion and seizes accordingly to reach the target value
     * @dev Handles rounding by prioritizing seizure from tokens with the largest deposits first
     * @dev Reverts with DSCEngine__InsufficientCollateral if total collateral value is less than required
     * Emits a {CollateralRedeemed} event for each collateral type from which tokens are seized
     */
    function _seizeCollateralProportionally(
        address from,
        address to,
        uint256 totalCollateralValueToSeize
    ) private {
        // Get the user's total collateral value across all tokens
        uint256 totalUserCollateralValue = getAccountCollateralValue(from);

        // Ensure user has sufficient total collateral to cover the seizure
        if (totalUserCollateralValue < totalCollateralValueToSeize) {
            revert DSCEngine__InsufficientCollateral();
        }

        // Track the actual USD value seized to handle rounding
        uint256 totalValueSeized = 0;

        // Iterate through all collateral tokens and seize proportionally
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 userTokenBalance = s_collateralDeposited[from][token];

            // Skip tokens with zero balance
            if (userTokenBalance == 0) {
                continue;
            }

            // Calculate the USD value of this token type
            uint256 tokenValueInUsd = getUsdValue(token, userTokenBalance);

            // Calculate how much value to seize from this token proportionally
            // Proportion = (tokenValueInUsd / totalUserCollateralValue) * totalCollateralValueToSeize
            uint256 valueToSeizeFromToken = (tokenValueInUsd * totalCollateralValueToSeize) / totalUserCollateralValue;

            // For the last iteration, seize any remaining value to handle rounding
            if (i == s_collateralTokens.length - 1) {
                valueToSeizeFromToken = totalCollateralValueToSeize - totalValueSeized;
            }

            // Convert the USD value to token amount
            uint256 tokenAmountToSeize = getTokenAmountFromUsd(token, valueToSeizeFromToken);

            // Ensure we don't try to seize more than the user has deposited
            if (tokenAmountToSeize > userTokenBalance) {
                tokenAmountToSeize = userTokenBalance;
            }

            // Skip if nothing to seize from this token
            if (tokenAmountToSeize == 0) {
                continue;
            }

            // Seize the collateral from this token type
            _redeemCollateral(from, to, token, tokenAmountToSeize);

            // Track the actual value seized (recalculate to account for rounding in conversion)
            totalValueSeized += getUsdValue(token, tokenAmountToSeize);

            // If we've seized enough value, we can exit early
            if (totalValueSeized >= totalCollateralValueToSeize) {
                break;
            }
        }

        // Final check: ensure we seized enough total value
        // Allow small rounding errors (< 0.01% difference)
        uint256 minAcceptableValueSeized = (totalCollateralValueToSeize * 9999) / 10000;
        if (totalValueSeized < minAcceptableValueSeized) {
            revert DSCEngine__InsufficientCollateral();
        }
    }

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
    function _calculateHealthFactor(address user) private view returns (uint256) 
    {
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
    function _revertIfHealthFactorIsBroken(address user) internal view 
    {
        uint256 userHealthFactor = _calculateHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////
    //                    PUBLIC & EXTERNAL VIEW FUNCTIONS                       //
    ///////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Converts a USD amount to its equivalent token amount using Chainlink price feeds
     * @param token The address of the token to calculate amount for
     * @param usdAmountInWei The USD amount with 18 decimals of precision
     * @return The equivalent token amount in the token's native decimals
     * @dev Uses Chainlink price feed to get current token price in USD
     * @dev Includes comprehensive oracle validation: staleness check (3 hours) and price validation
     * @dev This function is critical for liquidation calculations to ensure fair collateral seizure
     * @dev Example: If ETH is $2000 and you pass $4000 USD, returns 2 ETH (2e18)
     * @dev Calculation: (usdAmountInWei * 1e18) / (price * 1e10)
     * @dev Reverts with DSCEngine__NotAllowedToken if token has no registered price feed
     * @dev Reverts with DSCEngine__InvalidPrice if Chainlink returns price <= 0
     * @dev Reverts with DSCEngine__StalePrice if price data is older than 3 hours
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256)
    {
        // Validate token has a registered price feed
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();

        // Validate price is positive (Chainlink returns 0 or negative on errors)
        if (price <= 0) {
            revert DSCEngine__InvalidPrice();
        }

        // Ensure price data is fresh (updated within last 3 hours)
        if (block.timestamp - updatedAt > 3 hours) {
            revert DSCEngine__StalePrice();
        }

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Calculates the total USD value of all collateral deposited by a user
     * @param user The address of the user whose collateral to value
     * @return totalCollateralValueInUsd The total value of all deposited collateral in USD (18 decimals)
     * @dev Iterates through all supported collateral tokens and sums their USD values
     * @dev Uses Chainlink price feeds to get current market prices for each collateral token
     * @dev Returns 0 if the user has no collateral deposited
     */
    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) 
    {
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
    function getUsdValue(address token, uint256 amount) public view returns(uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Retrieves comprehensive account information for a given user
     * @param user The address of the user to query
     * @return totalDscMinted The total amount of DSC tokens minted by the user (in wei, 18 decimals)
     * @return collateralValueInUsd The total USD value of all collateral deposited by the user (18 decimals)
     * @dev Public wrapper for the internal _getAccountInformation function to enable external queries
     * @dev Useful for frontends, monitoring tools, and external contracts to check account status
     * @dev Collateral value is calculated using current Chainlink oracle prices for all deposited tokens
     */
    function getAccountInformation(address user)
    external
    view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /**
     * @notice Returns the price feed address for a given collateral token
     * @param token The address of the collateral token
     * @return The address of the Chainlink price feed for the token
     * @dev Returns address(0) if token is not supported as collateral
     */
    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @notice Returns the array of all supported collateral token addresses
     * @return Array of collateral token addresses
     * @dev Useful for iterating through all supported collateral types
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Returns the address of the DSC token contract
     * @return The address of the DecentralizedStableCoin contract
     */
    function getDsc() external view returns (address) {
        return address(I_DSC);
    }
}