// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {INRCoin} from "../src/INRCoin.sol";
import {INRCEngine} from "../src/INRCEngine.sol";

contract DeployINRC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (INRCoin, INRCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUSDPriceFeed, address wbtcUSDPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUSDPriceFeed, wbtcUSDPriceFeed];

        vm.startBroadcast(deployerKey);

        INRCoin inrcCoin = new INRCoin();

        uint256 intialUsdToInrConversionRate = 90;
        INRCEngine inrcEngine =
            new INRCEngine(tokenAddresses, priceFeedAddresses, address(inrcCoin), intialUsdToInrConversionRate);

        inrcCoin.transferOwnership(address(inrcEngine));

        vm.stopBroadcast();
        return (inrcCoin, inrcEngine, config);
    }
}
