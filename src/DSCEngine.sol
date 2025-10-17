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

/** @title Decentralized Stable Coin (DSC) Engine
 * @author unorthod0xd
 * @notice This contract is the core of the Decentralized Stable Coin system.
 * It handles all logic for minting and redeeming DSC, as well as maintaining
 * the collateralization ratio and liquidation mechanisms.
 * The DSC system is designed to be over-collateralized. All collateral <= the value of the DSC minted.
 * @notice This stablecoin is pegged to the USD ($1.00) and is backed by crypto assets (e.g., ETH, BTC).
 * - Exogenous: Pegged to USD via Chainlink oracles
 * - Decentralized: It is similar to DAI but has no governance, fees and is  only backed by wETH and wBTC
 * @dev This contract is a simplified version and does not include all functionalities.
 */

contract DSCEngine is ReentrancyGuard {


    ///////////// ERRORS ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAndPriceFeedLengthMismatch();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();


    /////////// STATE VARIABLES ////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDSCMinted) private s_DSCMinted;

    DecentralizedStableCoin private immutable I_DSC;

    ///////////// EVENTS ////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountCollateral);



    ///////////// MODIFIERS /////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }
    
    
    ///////////// FUNCTIONS /////////////
    constructor(address[] memory tokenAddresses, 
                address[] memory priceFeedAddresses, 
                address dscAddress
                ) {
                    if (tokenAddresses.length != priceFeedAddresses.length) {
                        revert DSCEngine__TokenAndPriceFeedLengthMismatch();
                    }

                    for (uint256 i = 0; i < tokenAddresses.length; i++) {
                        s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
                    }
                    I_DSC = DecentralizedStableCoin(dscAddress);
                }

    //////// EXTERNAL FUNCTIONS /////////
    function depositCollateralAndMintDSC() external {}

    /** Notice: This function allows users to deposit collateral (e.g., wETH, wBTC)
     * and mint DSC in a single transaction.
     * Notice: Follows CEI (Checks-Effects-Interactions) pattern to prevent reentrancy attacks.
     * @param tokenCollateralAddress The address of the collateral token to be deposited.
     * @param amountCollateral The amount of collateral to be deposited.
     * @dev Requirements:
     * - The caller must have approved the DSCEngine contract to spend the specified amount of collateral.
     * - The collateral must be sufficient to cover the minted DSC based on the required collateralization ratio.
     * Emits a {CollateralDeposited} event.
     */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral) 
        
        external 
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

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    /** Notice: This function allows users to mint DSC by providing collateral.
     * Notice: Follows CEI (Checks-Effects-Interactions) pattern to prevent reentrancy attacks.
     * @param amountDSCToMint The amount of DSC to be minted.
     * @dev Requirements:
     * - The caller must have sufficient collateral deposited to cover the minted DSC based on the required collateralization ratio.
     * - The caller must not exceed the maximum mintable DSC based on their collateral.
     * Emits a {DSCMinted} event.
     */
    function mintDSC(uint256 amountDSCToMint) external moreThanZero(amountDSCToMint) {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // check health factor
        // revert if not healthy
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}


    ///////// PRIVATE & INTERNAL FUNCTIONS /////////

    /** Notice: This function checks the health factor of a user.
     * @param user The address of the user to check.
     * @return bool True if the user's health factor is above the minimum threshold, false otherwise.
     * @dev The health factor is calculated based on the user's collateral and minted DSC.
     * A health factor below 1 indicates that the user's position is under-collateralized and may be subject to liquidation.
     */
    function _checkHealthFactor(address user) private view returns (bool) {
        // check health factor
        return true;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // check health factor
        // revert if not healthy
    }
}