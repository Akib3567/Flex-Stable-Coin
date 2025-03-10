// SPDX-License-Identifier: MIT
//What are our invariants?

// 1. The total supply of FSC should be less than the total value of collateral
// 2. Getter view functions should never revert

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FlexStableCoin} from "../../src/FlexStableCoin.sol";
import {FSCEngine} from "../../src/FSCEngine.sol";
import {DeployFSC} from "../../script/DeployFSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployFSC deployer;
    FlexStableCoin fsc;
    FSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc; 
    Handler handler;

    function setUp() external {
        deployer = new DeployFSC();
        (fsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        //targetContract(address(engine));
        handler = new Handler(engine, fsc);
        targetContract(address(handler));
    }

    function invariant_ProtocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = fsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalSupply);
    }

}
