// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {DeployINRC} from "../script/DeployINRC.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {INRCoin} from "../src/INRCoin.sol";
import {INRCEngine} from "../src/INRCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "forge-std/StdUtils.sol";

contract INRCEngineTest is Test {
    DeployINRC deployer;
    INRCoin inrc;
    INRCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public STARTING_ERC20_BALANCE = 10 ether;
    uint256 public USD_TO_INR_CONVERSION_RATE = 90;
    uint256 public MIN_HEALTH_FACTOR = 1;

    function setUp() public {
        deployer = new DeployINRC();
        (inrc, engine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    // Constructor Tests //
    function testRevertsIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);

        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(INRCEngine.INRCEngine__NumberOfTokenAddressesAndPriceFeedAddressesShouldBeSame.selector);
        new INRCEngine(tokenAddresses, priceFeedAddresses, address(inrc), USD_TO_INR_CONVERSION_RATE);
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 25e18;
        // 25e18 * 2000/ETH = 50_000e18
        uint256 expectedUsd = 50000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetInrValue() public {
        uint256 ethAmount = 25e18;
        // 25e18 * 2000/ETH = 50_000e18
        uint256 expectedInr = 50000e18 * USD_TO_INR_CONVERSION_RATE;

        uint256 actualInr = engine.getInrValue(weth, ethAmount);
        assertEq(expectedInr, actualInr);
    }

    function testGetTokenAmountFromInr() public {
        uint256 inrAmount = 100 ether * USD_TO_INR_CONVERSION_RATE;
        uint256 expedctedWeth = 0.05 ether * USD_TO_INR_CONVERSION_RATE;

        uint256 actualWeth = engine.getTokenAmountFromInr(weth, inrAmount);
        assertEq(expedctedWeth, actualWeth);
    }

    function testRevertsIfCollatoralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(INRCEngine.INRCEngine__AmountShouldBeGreaterThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnappovedCollateral() public {
        ERC20Mock testToken = new ERC20Mock("TEST", "TEST", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(INRCEngine.INRCEngine__TokenNotAllowed.selector, address(testToken)));
        engine.depositCollateral(address(testToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = inrc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalINRCMinted, uint256 collateralValueInINR) = engine.getAccountInformation(USER);
        assertEq(0, totalINRCMinted);

        uint256 expectedCollateralAmount = engine.getTokenAmountFromInr(weth, collateralValueInINR);
        assertEq(expectedCollateralAmount, AMOUNT_COLLATERAL * USD_TO_INR_CONVERSION_RATE);
    }
}
