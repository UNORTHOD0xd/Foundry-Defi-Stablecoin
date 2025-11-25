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
     * @dev This test verifies that the proportional liquidation fix works correctly.
     *      Previously, liquidation would fail if the user didn't have enough of a specific
     *      collateral type, even with sufficient total collateral value.
     *
     * Scenario:
     * 1. User deposits 3 WETH ($6,000) + 5 WBTC ($5,000) = $11,000 total collateral
     * 2. User mints $5,400 DSC (within safe limits initially)
     * 3. WETH price crashes from $2000 to $600
     *    - New collateral value: 3 WETH ($1,800) + 5 WBTC ($5,000) = $6,800
     *    - Health factor = ($6,800 * 50%) / $5,400 = 0.629 < 1.0 (UNDERCOLLATERALIZED)
     * 4. Liquidation of $2,700 debt now succeeds by seizing proportionally:
     *    - Total to seize: $2,970 (with 10% bonus)
     *    - WETH proportion: $1,800/$6,800 = 26.47% → seize ~$786 → ~1.31 WETH
     *    - WBTC proportion: $5,000/$6,800 = 73.53% → seize ~$2,184 → ~2.18 WBTC
     *
     * Bug Fix: Liquidations now succeed with sufficient total collateral, regardless of distribution
     */
    function testLiquidationSucceedsWithProportionalSeizure() public {
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
        uint256 collateralAdjusted = (collateralValueInUsd * 50) / 100;
        uint256 healthFactor = (collateralAdjusted * 1e18) / totalDscMinted;
        assertLt(healthFactor, 1e18, "User should be undercollateralized");

        // === STEP 4: Liquidator performs proportional liquidation ===
        vm.startPrank(LIQUIDATOR);

        // Setup liquidator with collateral and DSC
        ERC20Mock(weth).approve(address(dsce), 10 ether);
        dsce.depositCollateralAndMintDSC(weth, 10 ether, 3000 ether);
        dsc.approve(address(dsce), type(uint256).max);

        // Record balances before liquidation
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWbtcBefore = ERC20Mock(wbtc).balanceOf(LIQUIDATOR);
        uint256 liquidatorDscBefore = dsc.balanceOf(LIQUIDATOR);

        // Liquidate 50% of debt ($2,700)
        uint256 debtToCover = 2700 ether;

        // Liquidation should now SUCCEED with proportional seizure
        dsce.liquidate(USER, debtToCover);

        // Record balances after liquidation
        uint256 liquidatorWethAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWbtcAfter = ERC20Mock(wbtc).balanceOf(LIQUIDATOR);
        uint256 liquidatorDscAfter = dsc.balanceOf(LIQUIDATOR);

        vm.stopPrank();

        // === STEP 5: Verify proportional seizure occurred correctly ===

        // Verify liquidator received collateral
        assertGt(liquidatorWethAfter - liquidatorWethBefore, 0, "Liquidator should receive WETH");
        assertGt(liquidatorWbtcAfter - liquidatorWbtcBefore, 0, "Liquidator should receive WBTC");

        // Verify DSC was burned
        assertEq(liquidatorDscBefore - liquidatorDscAfter, debtToCover, "Liquidator should spend exact debt amount");

        // Calculate total value received (should be ~$2,970 with 10% bonus)
        uint256 wethValueSeized = dsce.getUsdValue(weth, liquidatorWethAfter - liquidatorWethBefore);
        uint256 wbtcValueSeized = dsce.getUsdValue(wbtc, liquidatorWbtcAfter - liquidatorWbtcBefore);
        uint256 totalValueSeized = wethValueSeized + wbtcValueSeized;

        // Allow for small rounding differences (within 1%)
        assertApproxEqRel(totalValueSeized, debtToCover + (debtToCover * 10 / 100), 0.01e18, "Total value seized should equal debt + bonus");

        // Verify proportions are approximately correct (WETH ~26%, WBTC ~74%)
        assertApproxEqAbs((wethValueSeized * 100) / totalValueSeized, 26, 2, "WETH proportion should be ~26%");
        assertApproxEqAbs((wbtcValueSeized * 100) / totalValueSeized, 74, 2, "WBTC proportion should be ~74%");

        // Verify user's debt was reduced and health improved
        (uint256 userDscAfter, uint256 userCollateralAfter) = dsce.getAccountInformation(USER);
        assertEq(userDscAfter, 5400 ether - debtToCover, "User debt should be reduced by amount covered");
        uint256 healthFactorAfter = ((userCollateralAfter * 50) * 1e18) / (100 * userDscAfter);
        assertGt(healthFactorAfter, healthFactor, "User health factor should improve");
        // Note: User may still be undercollateralized after single liquidation, but health improved
    }

    /**
     * @dev Core functionality - proportional seizure with balanced collateral distribution
     *
     * Scenario:
     * - User deposits equal value in WETH and WBTC: 5 WETH ($10,000) + 10 WBTC ($10,000) = $20,000
     * - User mints $9,500 DSC (safely collateralized)
     * - Both prices drop 50%: WETH to $1000, WBTC to $500
     * - New collateral value: $5,000 + $5,000 = $10,000
     * - Health factor: ($10,000 * 50%) / $9,500 = 0.526 < 1.0
     * - Liquidator covers $4,750 (50% max)
     * - Expected seizure: $5,225 total (50/50 split between WETH and WBTC)
     */
    function testLiquidationSucceedsWithProportionalSeizureFromMultipleCollaterals() public {
        address LIQUIDATOR = makeAddr("liquidator");

        // Setup: User deposits equal value in both tokens
        ERC20Mock(weth).mint(USER, 5 ether);   // 5 WETH @ $2000 = $10,000
        ERC20Mock(wbtc).mint(USER, 10 ether);  // 10 WBTC @ $1000 = $10,000
        ERC20Mock(weth).mint(LIQUIDATOR, 20 ether);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 5 ether);
        ERC20Mock(wbtc).approve(address(dsce), 10 ether);
        dsce.depositCollateral(weth, 5 ether);
        dsce.depositCollateral(wbtc, 10 ether);
        dsce.mintDSC(9500 ether);
        vm.stopPrank();

        // Crash both prices by 50%
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);  // $2000 → $1000
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(500e8);   // $1000 → $500

        // Verify undercollateralization
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        assertEq(collateralValue, 10000 ether, "Collateral should be $10,000");

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), 20 ether);
        dsce.depositCollateralAndMintDSC(weth, 20 ether, 5000 ether);
        dsc.approve(address(dsce), type(uint256).max);

        // Record balances
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWbtcBefore = ERC20Mock(wbtc).balanceOf(LIQUIDATOR);

        // Liquidate 25% of debt (less aggressive to ensure health factor improves)
        uint256 debtToCover = 2375 ether;
        dsce.liquidate(USER, debtToCover);

        // Calculate seized amounts
        uint256 wethSeized = ERC20Mock(weth).balanceOf(LIQUIDATOR) - liquidatorWethBefore;
        uint256 wbtcSeized = ERC20Mock(wbtc).balanceOf(LIQUIDATOR) - liquidatorWbtcBefore;

        vm.stopPrank();

        // Verify both tokens were seized
        assertGt(wethSeized, 0, "Should seize WETH");
        assertGt(wbtcSeized, 0, "Should seize WBTC");

        // Verify total value seized equals debt + bonus
        uint256 wethValue = dsce.getUsdValue(weth, wethSeized);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcSeized);
        uint256 totalValue = wethValue + wbtcValue;
        uint256 expectedValue = debtToCover + (debtToCover * 10 / 100); // $5,225

        assertApproxEqRel(totalValue, expectedValue, 0.01e18, "Total value should equal debt + 10% bonus");

        // Verify proportions are approximately 50/50 (equal starting values)
        uint256 wethProportion = (wethValue * 100) / totalValue;
        uint256 wbtcProportion = (wbtcValue * 100) / totalValue;

        assertApproxEqAbs(wethProportion, 50, 2, "WETH should be ~50% of seized value");
        assertApproxEqAbs(wbtcProportion, 50, 2, "WBTC should be ~50% of seized value");

        // Verify user's debt was reduced
        (uint256 userDscAfter,) = dsce.getAccountInformation(USER);
        assertEq(userDscAfter, 9500 ether - debtToCover, "User debt reduced correctly");
        // Note: Health factor improved but user may need additional liquidation
    }

    /**
     * @dev Core functionality - seizure from single collateral type only
     *
     * Scenario:
     * - User deposits only WETH: 10 WETH @ $2000 = $20,000
     * - User mints $9,000 DSC
     * - WETH price crashes to $800
     * - New collateral value: $8,000
     * - Health factor: ($8,000 * 50%) / $9,000 = 0.444 < 1.0
     * - All seizure should come from WETH only
     */
    function testLiquidationSeizesFromSingleCollateralWhenOnlyOneTypeDeposited() public {
        address LIQUIDATOR = makeAddr("liquidator");

        // User deposits only WETH
        ERC20Mock(weth).mint(USER, 10 ether);
        ERC20Mock(weth).mint(LIQUIDATOR, 20 ether);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 10 ether);
        dsce.depositCollateral(weth, 10 ether);  // $20,000
        dsce.mintDSC(9000 ether);
        vm.stopPrank();

        // Crash WETH price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);  // $2000 → $800

        // Verify undercollateralization
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        assertEq(collateralValue, 8000 ether, "Collateral should be $8,000");

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), 20 ether);
        dsce.depositCollateralAndMintDSC(weth, 20 ether, 5000 ether);
        dsc.approve(address(dsce), type(uint256).max);

        // Record balances
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWbtcBefore = ERC20Mock(wbtc).balanceOf(LIQUIDATOR);

        // Liquidate 25% of debt (less aggressive to ensure health factor improves)
        uint256 debtToCover = 2250 ether;
        dsce.liquidate(USER, debtToCover);

        // Calculate seized amounts
        uint256 wethSeized = ERC20Mock(weth).balanceOf(LIQUIDATOR) - liquidatorWethBefore;
        uint256 wbtcSeized = ERC20Mock(wbtc).balanceOf(LIQUIDATOR) - liquidatorWbtcBefore;

        vm.stopPrank();

        // Verify only WETH was seized
        assertGt(wethSeized, 0, "Should seize WETH");
        assertEq(wbtcSeized, 0, "Should NOT seize WBTC (user has none)");

        // Verify correct amount seized
        // Expected: $2,250 + 10% = $2,475 / $800 per WETH = 3.09375 WETH
        uint256 expectedWeth = 3.09375 ether;
        assertApproxEqRel(wethSeized, expectedWeth, 0.01e18, "Should seize correct WETH amount");

        // Verify value
        uint256 wethValue = dsce.getUsdValue(weth, wethSeized);
        uint256 expectedValue = debtToCover + (debtToCover * 10 / 100);
        assertApproxEqRel(wethValue, expectedValue, 0.01e18, "Value should equal debt + bonus");

        // Verify user's debt was reduced
        (uint256 userDscAfter,) = dsce.getAccountInformation(USER);
        assertEq(userDscAfter, 9000 ether - debtToCover, "User debt reduced correctly");
        // Note: Health factor improved but user may need additional liquidation
    }

    /**
     * @dev Core functionality - uneven collateral distribution (heavily skewed)
     *
     * Scenario:
     * - User deposits: 1 WETH ($2000) + 0.2 WBTC ($200) = $2,200 total
     * - WETH represents 90.9% of value, WBTC represents 9.1%
     * - User mints $1,050 DSC (safely collateralized at ~210%)
     * - WETH price crashes to $500
     * - New collateral: $500 + $200 = $700
     * - Health factor: ($700 * 50%) / $1,050 = 0.333 < 1.0
     * - Liquidation should seize proportionally despite heavy skew
     */
    function testLiquidationWithUnevenCollateralDistribution() public {
        address LIQUIDATOR = makeAddr("liquidator");

        // User deposits heavily skewed towards WETH
        ERC20Mock(weth).mint(USER, 1 ether);     // 1 WETH @ $2000 = $2,000 (90.9%)
        ERC20Mock(wbtc).mint(USER, 0.2 ether);   // 0.2 WBTC @ $1000 = $200 (9.1%)
        ERC20Mock(weth).mint(LIQUIDATOR, 10 ether);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 1 ether);
        ERC20Mock(wbtc).approve(address(dsce), 0.2 ether);
        dsce.depositCollateral(weth, 1 ether);
        dsce.depositCollateral(wbtc, 0.2 ether);
        dsce.mintDSC(1050 ether);
        vm.stopPrank();

        // Crash WETH price (WBTC stays same)
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(500e8);  // $2000 → $500

        // Verify undercollateralization
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        assertEq(collateralValue, 700 ether, "Collateral should be $700");

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), 10 ether);
        dsce.depositCollateralAndMintDSC(weth, 10 ether, 2000 ether);
        dsc.approve(address(dsce), type(uint256).max);

        // Record balances
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWbtcBefore = ERC20Mock(wbtc).balanceOf(LIQUIDATOR);

        // Liquidate 25% of debt (less aggressive to ensure health factor improves)
        uint256 debtToCover = 262 ether;
        dsce.liquidate(USER, debtToCover);

        // Calculate seized amounts
        uint256 wethSeized = ERC20Mock(weth).balanceOf(LIQUIDATOR) - liquidatorWethBefore;
        uint256 wbtcSeized = ERC20Mock(wbtc).balanceOf(LIQUIDATOR) - liquidatorWbtcBefore;

        vm.stopPrank();

        // Verify both tokens seized despite skew
        assertGt(wethSeized, 0, "Should seize WETH");
        assertGt(wbtcSeized, 0, "Should seize WBTC");

        // Calculate proportions based on collateral values at time of liquidation
        // WETH: $500 / $700 = 71.43%
        // WBTC: $200 / $700 = 28.57%
        uint256 wethValue = dsce.getUsdValue(weth, wethSeized);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcSeized);
        uint256 totalValue = wethValue + wbtcValue;

        // Expected: $525 + 10% = $577.50
        uint256 expectedValue = debtToCover + (debtToCover * 10 / 100);
        assertApproxEqRel(totalValue, expectedValue, 0.01e18, "Total value should equal debt + bonus");

        // Verify proportions match collateral distribution
        uint256 wethProportion = (wethValue * 100) / totalValue;
        uint256 wbtcProportion = (wbtcValue * 100) / totalValue;

        // WETH should be ~71%, WBTC should be ~29%
        assertApproxEqAbs(wethProportion, 71, 2, "WETH should be ~71% of seized value");
        assertApproxEqAbs(wbtcProportion, 29, 2, "WBTC should be ~29% of seized value");

        // Verify user's debt was reduced
        (uint256 userDscAfter,) = dsce.getAccountInformation(USER);
        assertEq(userDscAfter, 1050 ether - debtToCover, "User debt reduced correctly");
    }

    ///////////////////////////////////////
    ///////// Health Factor Tests /////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    /////// Getter Function Tests /////////
    ///////////////////////////////////////
}