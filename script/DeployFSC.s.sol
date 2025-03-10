// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FlexStableCoin} from "../src/FlexStableCoin.sol";
import {FSCEngine} from "../src/FSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployFSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns(FlexStableCoin, FSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = 
            config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        FlexStableCoin fsc = new FlexStableCoin();
        FSCEngine engine = new FSCEngine(tokenAddresses, priceFeedAddresses, address(fsc));
        fsc.transferOwnership(address(engine)); 
        vm.stopBroadcast();

        return(fsc, engine, config);
    }
}

