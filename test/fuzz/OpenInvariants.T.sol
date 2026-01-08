// SPDX-License-Identifier: MIT

//////////////////////////////////////////////////////////////////////////////
//                         INVARIANT TESTING NOTES                          //
//////////////////////////////////////////////////////////////////////////////
//
// WHAT IS INVARIANT TESTING?
// - Invariants are properties that must ALWAYS hold true, no matter what
// - The fuzzer calls random functions with random inputs trying to break them
// - If any invariant fails, the test fails and shows the call sequence that broke it
//
// OPEN VS STATEFUL (HANDLER-BASED) INVARIANT TESTING:
// - OPEN (this file): Fuzzer calls ANY public function on the target contract
//   with completely random inputs. Simple to set up but often wastes runs on
//   invalid calls (e.g., depositing tokens you don't have, invalid addresses)
// - HANDLER-BASED: A "Handler" contract wraps the target and bounds inputs to
//   valid ranges. More setup but much more effective at finding real bugs.
//
// HOW IT WORKS:
// 1. setUp() runs once to deploy contracts
// 2. targetContract() tells the fuzzer which contract(s) to call
// 3. Fuzzer runs many "runs", each with multiple random function "calls"
// 4. After each run, ALL invariant_* functions are checked
// 5. If any assert fails, test fails and reports the breaking sequence
//
// COMMON PITFALLS:
// - Invariants must pass at initial state (after setUp, before any calls)
// - Use >= instead of > when zero values are valid (0 >= 0 is true, 0 > 0 is false)
// - Open testing often has low effectiveness due to invalid random inputs
//
//////////////////////////////////////////////////////////////////////////////

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        targetContract(address(dsce));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtwValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

        assert(wethValue + wbtwValue >= totalSupply);
    }

}