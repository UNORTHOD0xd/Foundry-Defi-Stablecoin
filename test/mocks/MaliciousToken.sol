// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";

/**
 * @title MaliciousToken
 * @notice A malicious ERC20 token that attempts reentrancy attacks during transfers
 * @dev Used for testing reentrancy protection in DSCEngine
 */
contract MaliciousToken is ERC20 {
    DSCEngine private immutable i_dscEngine;
    address private immutable i_attacker;
    bool private s_attackEnabled;
    AttackType private s_attackType;

    enum AttackType {
        DEPOSIT_REENTRANT,
        REDEEM_REENTRANT,
        MINT_REENTRANT
    }

    constructor(address dscEngine, address attacker) ERC20("Malicious", "MAL") {
        i_dscEngine = DSCEngine(dscEngine);
        i_attacker = attacker;
        s_attackEnabled = false;
    }

    /**
     * @notice Enable attack mode with specific attack type
     * @param attackType The type of reentrancy attack to perform
     */
    function enableAttack(AttackType attackType) external {
        s_attackEnabled = true;
        s_attackType = attackType;
    }

    /**
     * @notice Disable attack mode
     */
    function disableAttack() external {
        s_attackEnabled = false;
    }

    /**
     * @notice Mint tokens to an address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Override transferFrom to inject reentrancy attack
     * @dev Attempts reentrancy when attack is enabled
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Perform the normal transfer first
        bool success = super.transferFrom(from, to, amount);

        // If attack is enabled and transfer succeeded, attempt reentrancy
        if (s_attackEnabled && success && from == i_attacker) {
            s_attackEnabled = false; // Disable to prevent infinite recursion during testing

            if (s_attackType == AttackType.DEPOSIT_REENTRANT) {
                // Try to reenter depositCollateral
                i_dscEngine.depositCollateral(address(this), 1 ether);
            } else if (s_attackType == AttackType.REDEEM_REENTRANT) {
                // Try to reenter redeemCollateral
                i_dscEngine.redeemCollateral(address(this), 1 ether);
            } else if (s_attackType == AttackType.MINT_REENTRANT) {
                // Try to reenter mintDSC
                i_dscEngine.mintDSC(1 ether);
            }
        }

        return success;
    }

    /**
     * @notice Override transfer to inject reentrancy attack on transfers
     * @dev Used for testing redeemCollateral reentrancy
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Perform the normal transfer first
        bool success = super.transfer(to, amount);

        // If attack is enabled and transfer succeeded, attempt reentrancy
        if (s_attackEnabled && success && to == i_attacker) {
            s_attackEnabled = false; // Disable to prevent infinite recursion

            if (s_attackType == AttackType.REDEEM_REENTRANT) {
                // Try to reenter redeemCollateral during the transfer callback
                i_dscEngine.redeemCollateral(address(this), 1 ether);
            } else if (s_attackType == AttackType.DEPOSIT_REENTRANT) {
                // Try to reenter depositCollateral during the transfer callback
                i_dscEngine.depositCollateral(address(this), 1 ether);
            }
        }

        return success;
    }
}
