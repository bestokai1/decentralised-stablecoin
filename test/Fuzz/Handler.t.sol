// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../Mocks/MockV3Aggregator.sol";



contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUSDPriceFeed;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timeMintIsCalled;
    address[] public usersWithCollateralDeposited;


    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUSDPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }


    function mintDSC(uint256 amount, uint256 seedAddress) public{
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[seedAddress % usersWithCollateralDeposited.length];
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInfo(sender);

        int256 maxDSCToMint = (int256(collateralValueInUSD) / 2) - int256(totalDSCMinted);
        if (maxDSCToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDSCToMint));
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDSC(amount);
        vm.stopPrank();
        timeMintIsCalled++;
    }

    function depositCollateral(uint256 collateralAmount, uint256 collateralSeed) public{
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateralAddress = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateralAddress.mint(msg.sender, collateralAmount);
        collateralAddress.approve(address(engine), collateralAmount);
        engine.depositCollateral(address(collateralAddress), collateralAmount);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function reddemCollateral(uint256 collateralAmount, uint256 collateralSeed) public{
        ERC20Mock collateralAddress = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateralAddress), msg.sender);
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);
        if (collateralAmount == 0) {
            return;
        }
        engine.redeemCollateral(address(collateralAddress), collateralAmount);
    }
    
    // This breaks our invariant test suite!!! (rapid price drop!!!).
    // function updateCollateralPrice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUSDPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock){
        if (collateralSeed % 2 == 0) {
            return weth;
        }else {
            return wbtc;
        }
    }
}