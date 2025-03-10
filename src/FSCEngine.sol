// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {FlexStableCoin} from "./FlexStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/*
 * @title FSCEngine
 * @author Ahsan Habib Akib
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our FSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the FSC. (FSC is the symbol of our Stable Coin)
 *
 * @notice This contract is the core of the FlexStableCoin system. It handles all the logic
 * for minting and redeeming FSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract FSCEngine is ReentrancyGuard {
    /////***  Errors  ***/////
    error FSCEngine__NeedsMoreThanZero();
    error FSCEngine__TokenAndPriceFeedAddressesMustBeSameLength();
    error FSCEngine__NotAllowedToken();
    error FSCEngine__TransferFailed();
    error FSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error FSCEngine__mintFailed();
    error FSCEngine__HealthFactorOk();
    error FSCEngine__HealthFactorNotImproved();

    /////***  Types  ***/////
    using OracleLib for AggregatorV3Interface;

    /////***  State Variables ***/////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;   //which refers to 10% when divided by LIQUIDATION_PRECISION
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;   //TokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount)) s_collateralDeposited;
    mapping(address user => uint256 amountOfFscMinted) s_fscMinted;
    address[] private s_collateralTokens;

    FlexStableCoin private immutable i_fsc;

    /////*** Events ***/////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    /////*** Modifiers ***/////
    modifier moreThanZero(uint256 amount) {
        if(amount <= 0){
            revert FSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier tokenIsAllowed(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert FSCEngine__NotAllowedToken();
        }
        _;
    }

    /////*** Functions ***/////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address fscAddress) {
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert FSCEngine__TokenAndPriceFeedAddressesMustBeSameLength();
        }

        for(uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_fsc = FlexStableCoin(fscAddress);
    }


    //This function will deposit collateral and mint Fsc in one transaction
    function depositCollateralAndMintFsc(
        address tokenCollateralAddress, 
        uint256 collateralAmount, 
        uint256 amountFscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintfsc(amountFscToMint);
    }

    /*
    * @param tokenCollateralAddress - The address of the token that will be collateralized
    * @param collateralAmount - The amount of collateral to be deposited
    */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount) 
        public 
        moreThanZero(collateralAmount) 
        tokenIsAllowed(tokenCollateralAddress) 
        nonReentrant 
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        
        if(!success){
            revert FSCEngine__TransferFailed();
        }
    }
    
    //This function burns FSC and redeems collateral in one transaction
    function redeemCollateralForFsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountFscToBurn
    ) external {
        burnFsc(amountFscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    //In order redeem collateral, health factor must be greater than 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public 
        moreThanZero(amountCollateral)
        tokenIsAllowed(tokenCollateralAddress)
        nonReentrant 
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    *  @params amountFscToMint - The amount Flex Stable Coin to mint
    *  @notice They must have more collateral value than the amount they want to mint/Threshhold
    */
    function mintfsc(uint256 amountFscToMint) 
        public
        moreThanZero(amountFscToMint)
        nonReentrant
    {
        s_fscMinted[msg.sender] += amountFscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);  //If they have minted too much ($150 FSC, 100 ETH)

        bool minted = i_fsc.mint(msg.sender, amountFscToMint);
        if(!minted){
            revert FSCEngine__mintFailed();
        }
    }

    function burnFsc(uint256 amount) public moreThanZero(amount) {
        _burnFsc(amount, msg.sender, msg.sender);
        i_fsc.burn(amount);
    }


    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your FSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of FSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external 
        moreThanZero(debtToCover)
        nonReentrant 
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert FSCEngine__HealthFactorOk();
        }
        
        //We want to burn their FSC debt and take their collateral
        //User's $200 eth came down to less than $150, $100 FSC (which is less than 150%)
        // Debt to cover = $100 of FSC = ? eth 
        // Let's eth current price is $2000 so 100/2000 = 0.05 eth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        //And give the Liquidator a 10% bonus
        //0.05 * 0.1 = 0.005 bonus, total = 0.05 + 0.005 = 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnFsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert FSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}


    /////*** Internal & Private Functions ***/////

    function _burnFsc(uint256 amountFscToBurn, address onBehalfOf, address fscFrom) private {
        s_fscMinted[onBehalfOf] -= amountFscToBurn;

        bool success = i_fsc.transferFrom(fscFrom, address(this), amountFscToBurn);  //Liquidator will transfer FSC to engine
        if(!success){
            revert FSCEngine__TransferFailed();
        }
        i_fsc.burn(amountFscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        if(s_collateralDeposited[from][tokenCollateralAddress] < amountCollateral) {
            return;
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert FSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user) 
        private 
        view 
        returns(uint256 totalFscMinted, uint256 collateralValueInUsd) 
    {
        totalFscMinted = s_fscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they may get liquidated 
    */
    function _healthFactor(address user) private view returns(uint256) {
        (uint256 totalFscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        if (totalFscMinted == 0) {
            return type(uint256).max; // Return a very high health factor instead of reverting
        }
        return (collateralAdjustedForThreshold * PRECISION) / totalFscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert FSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }


    /////*** Public Functions ***/////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited and map it to the price to get the usd value
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;  // ((1000 * 1e8 * 1e10) * amount) / 1e18
    }

    function getCollateralDeposited(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getFscMinted(address user) public view returns(uint256) {
        return s_fscMinted[user];
    }

    function getHealthFactor(address user) public view returns(uint256) {
        return _healthFactor(user);
    }

    function getMinHealthFactor() public pure returns(uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getAccountInformation(address user) 
        external view returns(uint256 totalFscMinted, uint256 collateralValueInUsd)
    {
        (totalFscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}

