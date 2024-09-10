// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";




contract OpenInvariantsTest is StdInvariant, Test {
    DSCEngine engine;
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;


    function setUp() external{
        deployer = new DeployDSCEngine();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
    }

    function openInvariant_protocolMustHaveMoreCollateralThenDSC() public view{
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWETHDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWBTCDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUSDValue(weth, totalWETHDeposited);
        uint256 wbtcValue = engine.getUSDValue(wbtc, totalWBTCDeposited);

        console.log('weth value: ', wethValue);
        console.log('wbtc value: ', wbtcValue);
        console.log('total supply: ', totalSupply);

        assert(wethValue + wbtcValue >= totalSupply);
    }
}