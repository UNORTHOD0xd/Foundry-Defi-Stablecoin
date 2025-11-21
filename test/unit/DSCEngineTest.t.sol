// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MaliciousToken} from "../../test/mocks/MaliciousToken.sol";

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

    ///////////////////////////////////////
    ///////// Health Factor Tests /////////
    ///////////////////////////////////////

    ///////////////////////////////////////
    /////// Getter Function Tests /////////
    ///////////////////////////////////////
}