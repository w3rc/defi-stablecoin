// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {DeployINRC} from "../script/DeployINRC.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {INRCoin} from "../src/INRCoin.sol";
import {INRCEngine} from "../src/INRCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract INRCEngineTest is Test {
    DeployINRC deployer;
    INRCoin inrc;
    INRCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployINRC();
        (inrc, engine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
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

    function testREevertsIfCollatoralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(INRCEngine.INRCEngine__AmountShouldBeGreaterThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
