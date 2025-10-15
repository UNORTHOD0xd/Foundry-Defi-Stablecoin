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

contract DSCEngine {
    function depositCollateralAndMintDSC() external {}

    function depositCollateral() external {}

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    function mintDSC() external {}

    function burnDSC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}