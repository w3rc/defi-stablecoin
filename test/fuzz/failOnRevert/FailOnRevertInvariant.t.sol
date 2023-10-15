// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.21;

// Invariants:
// protocol must never be insolvent / undercollateralized
// TODO: users cant create stablecoins with a bad health factor
// TODO: a user should only be able to be liquidated if they have a bad health factor

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {INRCEngine} from "../../../src/INRCEngine.sol";
import {INRCoin} from "../../../src/INRCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployINRC} from "../../../script/DeployINRC.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {FailOnRevertHandler} from "./FailOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

contract StopOnRevertInvariants is StdInvariant, Test {
    INRCEngine public engine;
    INRCoin public inrc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    address public constant USER = address(1);
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    FailOnRevertHandler public handler;

    function setUp() external {
        DeployINRC deployer = new DeployINRC();
        (inrc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new FailOnRevertHandler(engine, inrc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        uint256 totalSupply = inrc.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(engine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = engine.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() public view {
        engine.getAdditionalFeedPrecision();
        engine.getCollateralTokens();
        engine.getLiquidationBonus();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
        engine.getPrecision();
        engine.getInrc();
    }
}