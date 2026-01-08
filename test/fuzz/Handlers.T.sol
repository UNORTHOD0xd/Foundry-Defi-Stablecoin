// SPDX-License-Identifier: MIT
// Handler is going to narrow down the way we call functions

//////////////////////////////////////////////////////////////////////////////
//                            HANDLER NOTES                                 //
//////////////////////////////////////////////////////////////////////////////
//
// WHAT IS A HANDLER?
// - A wrapper contract that the fuzzer calls INSTEAD of the target directly
// - Constrains random inputs to valid ranges so calls actually succeed
// - Sets up necessary preconditions (minting tokens, approvals, pranks)
//
// WHY USE A HANDLER?
// - Open invariant testing has low effectiveness (most calls revert)
// - Handlers ensure meaningful state transitions actually occur
// - You control which functions get fuzzed and how inputs are bounded
//
// KEY TECHNIQUES USED IN THIS HANDLER:
//
// 1. BOUNDING - bound(value, min, max)
//    Constrains random uint256 to a valid range. Example:
//    amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
//    This ensures we never deposit 0 or overflow-prone amounts.
//
// 2. SEEDING - Converting random values to valid options
//    _getCollateralFromSeed(collateralSeed) uses modulo to pick weth or wbtc
//    Any random number becomes a valid collateral choice.
//
// 3. PRECONDITION SETUP - Minting tokens before deposit
//    The handler mints tokens to msg.sender and approves the engine.
//    Without this, depositCollateral would always revert (no balance).
//
// 4. MAX_DEPOSIT_SIZE = type(uint96).max
//    Using uint96.max instead of uint256.max prevents overflow in USD
//    calculations when multiplying by price (e.g., 2000e8 for ETH).
//
//////////////////////////////////////////////////////////////////////////////

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    } 

    // redeem collateral <-

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
    }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock)
    {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;

    }
}