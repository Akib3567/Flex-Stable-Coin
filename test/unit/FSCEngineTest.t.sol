// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlexStableCoin} from "../../src/FlexStableCoin.sol";
import {FSCEngine} from "../../src/FSCEngine.sol";
import {DeployFSC} from "../../script/DeployFSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract FSCEngineTest is Test {
    DeployFSC deployer;
    FlexStableCoin fsc;
    FSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public RECEIVER = makeAddr("receiver");
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    uint256 public constant REDEEM_AMOUNT = 10 ether;
    uint256 public constant INITIAL_BALANCE = 200 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    function setUp() public {
        deployer = new DeployFSC();
        (fsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);

        deal(address(weth), USER, INITIAL_BALANCE);

        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), INITIAL_BALANCE);

        vm.prank(USER);
        engine.depositCollateral(address(weth), DEPOSIT_AMOUNT);
    }

    /////////////////////
    //    Price test   //
    /////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = (ethAmount * 2000);
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        //if eth value is $2000 then $100 = 0.05 ether
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////
    // Deposit collateral test //
    /////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(FSCEngine.FSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(FSCEngine.FSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    function testDepositedCollateral() public view {
        uint256 collateralAmount = engine.getCollateralDeposited(USER, address(weth));

        assertEq(collateralAmount, DEPOSIT_AMOUNT);
    }

    //////////////////////
    // Constructor test //
    //////////////////////
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(FSCEngine.FSCEngine__TokenAndPriceFeedAddressesMustBeSameLength.selector);
        new FSCEngine(tokenAddresses, priceFeedAddresses, address(fsc));
    }

    ///////////////////////////
    // Redeem & Minting test //
    ///////////////////////////
    function testRedeemCollateralSuccess() public {
        vm.prank(USER);
        engine.mintfsc(10 ether); 

        vm.prank(USER);
        engine.redeemCollateral(address(weth), REDEEM_AMOUNT);

        assertEq(engine.getCollateralDeposited(USER, address(weth)), DEPOSIT_AMOUNT - REDEEM_AMOUNT);
    }

    function testMintFscSuccess() public {
        uint256 amountToMint = 10 ether;

        vm.prank(USER);
        engine.mintfsc(amountToMint);

        uint256 fscMinted = engine.getFscMinted(USER);
        assertEq(fscMinted, amountToMint);
        //Check whether user balance increases or not
        assertEq(fsc.balanceOf(USER), amountToMint);   
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintFsc(weth, AMOUNT_COLLATERAL, 2 ether);
        vm.expectRevert(FSCEngine.FSCEngine__NeedsMoreThanZero.selector);
        engine.mintfsc(0);
        vm.stopPrank();
    }

    //////////////////////
    //   BurnFsc test   //
    //////////////////////
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintFsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(FSCEngine.FSCEngine__NeedsMoreThanZero.selector);
        engine.burnFsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnFsc(1);
    }

    ///////////////////////////
    //   Health Factor test  //
    ///////////////////////////

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintFsc(weth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();
        _;
    }

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 1100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);

        assertEq(healthFactor, expectedHealthFactor);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }
}
