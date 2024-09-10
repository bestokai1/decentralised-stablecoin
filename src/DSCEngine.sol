// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";


/**
 * @title Decentralized Stable Coin
 * @author Tshediso Matsasa
 * This system is designed to be as minimal as possible and maintain a 1 token == $1 peg.
 * This stablecoin has the following properties:
 * - Exogenous collateral
 * - Dollar-pegged
 * - Algorithmic stability
 * 
 * This stablecoin is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
 * Our DSC system should always be overcollaterized. At no point should the value of all collateral <= the $-backed value of all DSC.
 * 
 * @notice This contract is the core of this DSC system. It handles all the logic for minting and redeeming DSC, as well as, depositing and withdrawing collateral.
 * @notice This contract is loosely based on the MakerDAO DSS (DAI) system. 
 */

contract DSCEngine is ReentrancyGuard{
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__MintFailed();


    using OracleLib for AggregatorV3Interface;


    mapping (address token => address priceFeed) private s_priceFeeds;
    mapping (address user => mapping (address token => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 dscAmountMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    uint256 private constant E_10 = 1e10;
    uint256 private constant E_18 = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PERCENTAGE = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;


    DecentralizedStableCoin private immutable i_dsc;

    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);


    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }


    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @param collateralTokenAddress: The address of the token to deposit as collateral. 
     * @param collateralAmount: The amount of collateral to deposit.
     * @param dscAmountToMint: The amount of decentralized stablecoin to mint.
     * @notice This function will deposit your collateral and mint dsc all in one transaction.
     */

    function depositCollateralAndMintDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmountToMint) external{
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDSC(dscAmountToMint);
    }

    /**
     * @param tokenCollateralAddress: The address of the token to deposit as collateral.
     * @param collateralAmount: The amount of collateral to deposit.
     */

   function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount) public moreThanZero(collateralAmount) isAllowedToken(tokenCollateralAddress) nonReentrant{
    s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
    emit collateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
    bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
    if (!success) {
        revert DSCEngine__TransferFailed();
    }
   }

   /**
    * @param collateralTokenAddress: The collateral token address to redeem.
    * @param collateralAmount: The amount of collateral to redeem.
    * @param dscAmountToBurn: The amount of decentralized stablecoin to burn.
    * @notice This function burns DSC and reddems collateral all in one function.
    */

    function redeemCollateralForDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmountToBurn) external{
        burnDSC(dscAmountToBurn);
        redeemCollateral(collateralTokenAddress, collateralAmount);
    }

    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount) public moreThanZero(collateralAmount) nonReentrant{
        _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI.
     * @param dscAmountToMint: The amount of decentralized stablecoin to mint.
     * @notice collateral value must be more than the minimum threshold.
     */

    function mintDSC(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant{
        s_dscMinted[msg.sender] += dscAmountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public{
        _burnDSC(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateralAddress: The ERC20 collateral address to liquidate from user. 
     * @param user: The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR.
     * @param debtToCover: The amount of DSC one would want burn to improve the user's health factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user's funds.
     * @notice This function working assumes the protocol will be roughly 200% over collateralized in order for this to work.
     * @notice A known bug would be if they were 100%, or less, collateralized, then we wouldn't be able to incentivise the liquidators.
     * 
     */

    function liquidate(address collateralAddress, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateralAddress, debtToCover);
        uint256 bonusCollateralAmount = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PERCENTAGE;
        _redeemCollateral(user, msg.sender, collateralAddress, bonusCollateralAmount);
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view{

    }

    function _getAccountInfo(address user) private view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD){
        totalDSCMinted = s_dscMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /**
     * This checks how close a user is to liquidation.
     * If a user goes below 1 then they get liquidated.
     */

    function _healthFactor(address user) private view returns(uint256){
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInfo(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PERCENTAGE;
        return (collateralAdjustedForThreshold / totalDSCMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view{
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(userHealthFactor);
        }
    }

    function _redeemCollateral(address from, address to, address collateralTokenAddress, uint256 collateralAmount) private{
        s_collateralDeposited[from][collateralTokenAddress] -= collateralAmount;
        emit collateralRedeemed(from, to, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev low-level internal function. Do not call unless function calling it is checking if health factor is broken.
     */

    function _burnDSC(address onBehalfOf, address dscFrom, uint256 dscAmountToBurn) private{
        s_dscMinted[onBehalfOf] -= dscAmountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), dscAmountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(dscAmountToBurn);
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUSD){
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUSDValue(token, amount);
        }

        return totalCollateralValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * E_10) * amount) / E_18;
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256){
        return s_collateralDeposited[user][token];
    }

    function getTokenAmountFromUSD(address token, uint256 usdAmountInWei) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * E_18) / (uint256(price) * E_10);
    }

    function getAccountInfo(address user) external view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD){
        (totalDSCMinted, collateralValueInUSD) = _getAccountInfo(user);
    }
}