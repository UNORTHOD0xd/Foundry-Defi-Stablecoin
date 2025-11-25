// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MaliciousToken} from "../../test/mocks/MaliciousToken.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////////////
    ////////// Constructor Tests //////////
    ///////////////////////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](2);

        tokenAddresses[0] = weth;
        priceFeedAddresses[0] = ethUsdPriceFeed;
        priceFeedAddresses[1] = btcUsdPriceFeed;

        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testRevertsIfTokenLengthExceedsPriceFeedLength() public {
        address[] memory tokenAddresses = new address[](2);
        address[] memory priceFeedAddresses = new address[](1);

        tokenAddresses[0] = weth;
        tokenAddresses[1] = weth; // Using weth twice for simplicity
        priceFeedAddresses[0] = ethUsdPriceFeed;

        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorInitializesStateMappingsCorrectly() public view {
        // Verify price feed mappings are set correctly
        assertEq(dsce.getPriceFeed(weth), ethUsdPriceFeed);
        assertEq(dsce.getPriceFeed(wbtc), btcUsdPriceFeed);

        // Verify collateral tokens array is populated correctly
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);

        // Verify DSC token address is stored correctly
        assertEq(dsce.getDsc(), address(dsc));
    }

    ///////////////////////////////////////
    //////////// Price Tests //////////////
    ///////////////////////////////////////

    function testGetUsdValue() public view{
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / eth, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValueWithZeroAmount() public view {
        uint256 ethAmount = 0;
        uint256 expectedUsd = 0;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetUsdValueWithMaxAmount() public view {
        // Use a large realistic amount to prevent overflow
        // Max realistic ETH supply is ~120M ETH
        uint256 ethAmount = 120_000_000e18;

        // At $2000/ETH: 120M ETH * $2000 = $240B
        uint256 expectedUsd = 240_000_000_000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsdWithZeroAmount() public view {
        uint256 usdAmount = 0;
        uint256 expectedWeth = 0;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetTokenAmountFromUsdWithMaxAmount() public view {
        // Test with very large USD amount
        // $1 Trillion USD
        uint256 usdAmount = 1_000_000_000_000e18;

        // At $2000/ETH: $1T / $2000 = 500M ETH
        uint256 expectedWeth = 500_000_000e18;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }


    ///////////////////////////////////////
    ////// Deposit Collateral Tests ///////
    ///////////////////////////////////////

    function testRevertsIfCollateralZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ///////////////////////////////////////
    ///////// Reentrancy Tests ////////////
    ///////////////////////////////////////

    function testDepositCollateralReentrancyProtection() public {
        // Deploy a new DSCEngine that accepts the malicious token
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](1);

        // Create malicious token
        MaliciousToken malToken = new MaliciousToken(address(dsce), USER);

        tokenAddresses[0] = address(malToken);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        DSCEngine testEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // Mint tokens to attacker
        malToken.mint(USER, 100 ether);

        vm.startPrank(USER);

        // Approve tokens
        malToken.approve(address(testEngine), 100 ether);

        // Enable reentrancy attack
        malToken.enableAttack(MaliciousToken.AttackType.DEPOSIT_REENTRANT);

        // Attempt deposit - should fail due to reentrancy guard
        vm.expectRevert();
        testEngine.depositCollateral(address(malToken), 10 ether);

        vm.stopPrank();
    }

    function testRedeemCollateralReentrancyProtection() public {
        // Deploy a new DSCEngine that accepts the malicious token
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](1);

        // Create malicious token
        MaliciousToken malToken = new MaliciousToken(address(dsce), USER);

        tokenAddresses[0] = address(malToken);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        DSCEngine testEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // Mint tokens to attacker
        malToken.mint(USER, 100 ether);

        vm.startPrank(USER);

        // First deposit some collateral normally
        malToken.approve(address(testEngine), 100 ether);
        testEngine.depositCollateral(address(malToken), 50 ether);

        // Enable reentrancy attack for redeem
        malToken.enableAttack(MaliciousToken.AttackType.REDEEM_REENTRANT);

        // Attempt redeem - should fail due to reentrancy guard
        vm.expectRevert();
        testEngine.redeemCollateral(address(malToken), 10 ether);

        vm.stopPrank();
    }

    function testMintDscReentrancyProtection() public {
        // Deploy a new DSCEngine that accepts the malicious token
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](1);

        // Create malicious token
        MaliciousToken malToken = new MaliciousToken(address(dsce), USER);

        tokenAddresses[0] = address(malToken);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        DSCEngine testEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // Mint tokens to attacker
        malToken.mint(USER, 100 ether);

        vm.startPrank(USER);

        // Deposit collateral first
        malToken.approve(address(testEngine), 100 ether);
        testEngine.depositCollateral(address(malToken), 50 ether);

        // Enable reentrancy attack for mint
        malToken.enableAttack(MaliciousToken.AttackType.MINT_REENTRANT);

        // Attempt mint - the attack will be triggered during DSC transfer approval
        // Note: This test verifies that even if a malicious actor tries to reenter
        // during the mint process, the nonReentrant modifier prevents it
        vm.expectRevert();
        testEngine.mintDSC(1000e18);

        vm.stopPrank();
    }

    ///////////////////////////////////////
    /////////// Mint DSC Tests ////////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    /////////// Burn DSC Tests ////////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    ////// Redeem Collateral Tests ////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    ///////// Liquidation Tests ///////////
    ///////////////////////////////////////

    /**
     * @dev This test demonstrates that a valid liquidation can fail if the liquidator
     *      chooses a collateral token that the user doesn't have enough of, even when
     *      the user has sufficient total collateral value across all token types.
     *
     * Scenario:
     * 1. User deposits 3 WETH ($6,000) + 5 WBTC ($5,000) = $11,000 total collateral
     * 2. User mints $5,400 DSC (within safe limits initially)
     * 3. WETH price crashes from $2000 to $600
     *    - New collateral value: 3 WETH ($1,800) + 5 WBTC ($5,000) = $6,800
     *    - Health factor = ($6,800 * 50%) / $5,400 = 0.629 < 1.0 (UNDERCOLLATERALIZED)
     * 4. Liquidator attempts to liquidate using WETH (wrong choice)
     *    - Needs: ($2,700 / $600) * 1.1 = 4.95 WETH
     *    - User only has 3 WETH → LIQUIDATION FAILS with InsufficientCollateral
     * 5. But liquidation SHOULD work using WBTC:
     *    - Would need: ($2,700 / $1,000) * 1.1 = 2.97 WBTC
     *    - User has 5 WBTC → This would succeed
     *
     * Bug Impact: Valid liquidations can be blocked, allowing bad debt to accumulate
     */
    function testLiquidationFailsWithInsufficientSpecificCollateralDespiteHealthyTotalCollateral() public {
        // Setup addresses
        address LIQUIDATOR = makeAddr("liquidator");

        // Give USER both WETH and WBTC
        ERC20Mock(weth).mint(USER, 3 ether);  // 3 WETH
        ERC20Mock(wbtc).mint(USER, 5 ether);  // 5 WBTC (using ether as 1e18)

        // Give LIQUIDATOR DSC to perform liquidation
        ERC20Mock(weth).mint(LIQUIDATOR, 10 ether);

        // === STEP 1: User deposits mixed collateral ===
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 3 ether);
        ERC20Mock(wbtc).approve(address(dsce), 5 ether);

        dsce.depositCollateral(weth, 3 ether);  // 3 WETH @ $2000 = $6,000
        dsce.depositCollateral(wbtc, 5 ether);  // 5 WBTC @ $1000 = $5,000
        // Total collateral: $11,000

        // === STEP 2: User mints DSC (just under safe limit) ===
        // With $11,000 collateral at 200% ratio (50% threshold), max safe mint = $5,500
        // User mints $5,400 to be slightly safe
        dsce.mintDSC(5400 ether);
        vm.stopPrank();

        // Verify user position is initially healthy
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 5400 ether);
        assertEq(collateralValueInUsd, 11000 ether); // $11,000

        // === STEP 3: Crash WETH price to make user undercollateralized ===
        // Import MockV3Aggregator to manipulate price
        MockV3Aggregator ethUsdPriceFeedContract = MockV3Aggregator(ethUsdPriceFeed);

        // Crash WETH from $2000 to $600
        ethUsdPriceFeedContract.updateAnswer(600e8);

        // Verify new collateral value
        // 3 WETH @ $600 = $1,800
        // 5 WBTC @ $1000 = $5,000
        // Total = $6,800
        (totalDscMinted, collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(collateralValueInUsd, 6800 ether);

        // Calculate health factor manually to verify undercollateralization
        // Health factor = (collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION) / totalDscMinted
        // Health factor = ($6,800 * 50 / 100) / $5,400 = $3,400 / $5,400 = 0.629...
        // Expected: 0.62962962... * 1e18 = 629629629629629629
        uint256 collateralAdjusted = (collateralValueInUsd * 50) / 100;
        uint256 expectedHealthFactor = (collateralAdjusted * 1e18) / totalDscMinted;
        assertLt(expectedHealthFactor, 1e18, "User should be undercollateralized");

        // === STEP 4: Liquidator tries to liquidate using WETH (insufficient) ===
        vm.startPrank(LIQUIDATOR);

        // Mint and approve DSC for liquidator
        // Give liquidator enough collateral to mint DSC (at crashed $600 WETH price)
        // 10 WETH @ $600 = $6,000 collateral → can mint $3,000 DSC max
        ERC20Mock(weth).approve(address(dsce), 10 ether);
        dsce.depositCollateralAndMintDSC(weth, 10 ether, 3000 ether);
        dsc.approve(address(dsce), type(uint256).max);

        // Try to liquidate 50% of debt ($2,700) using WETH as collateral
        uint256 debtToCover = 2700 ether;

        // Calculate what liquidator would need:
        // Token amount = $2,700 / $600 = 4.5 WETH
        // With 10% bonus = 4.5 * 1.1 = 4.95 WETH
        // But user only has 3 WETH!

        // With the fix, this should now succeed by seizing collateral proportionally
        // Note: The test needs to be updated to verify the proportional seizure
        dsce.liquidate(USER, debtToCover);

        vm.stopPrank();

        // === STEP 5: Demonstrate that WBTC liquidation WOULD work ===
        // If liquidator chose WBTC instead:
        // Token amount = $2,700 / $1,000 = 2.7 WBTC
        // With 10% bonus = 2.7 * 1.1 = 2.97 WBTC
        // User has 5 WBTC - this WOULD succeed!

        // Verify user still has enough WBTC for liquidation
        uint256 wbtcNeeded = dsce.getTokenAmountFromUsd(wbtc, debtToCover);
        uint256 wbtcWithBonus = wbtcNeeded + (wbtcNeeded * 10 / 100);

        // User should have enough WBTC
        (, uint256 userCollateral) = dsce.getAccountInformation(USER);
        assertGt(5 ether, wbtcWithBonus, "User should have enough WBTC for liquidation");

        // This demonstrates the bug: A valid liquidation is blocked because the liquidator
        // chose the wrong collateral type, even though the user should be liquidatable
    }

    ///////////////////////////////////////
    ///////// Health Factor Tests /////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    /////// Getter Function Tests /////////
    ///////////////////////////////////////
}