// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {INRCoin} from "./INRCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title INRC Engine
 * @author w3rc
 *
 * The engine always takes into account that system is overcollaterized.
 *
 * @notice This contract governs the INRC token
 */
contract INRCEngine is ReentrancyGuard {
    ////////////////
    // Errors  /////
    ////////////////
    error INRCEngine__AmountShouldBeGreaterThanZero();
    error INRCEngine__NumberOfTokenAddressesAndPriceFeedAddressesShouldBeSame();
    error INRCEngine__TokenNotAllowed(address tokenAddress);
    error INRCEngine__TransferFailed();
    error INRCEngine__BreaksHealthFactor(uint256 healthFactor);
    error INRCEngine__MintFailed();
    error INRCEngine__FundsAreHealthy();
    error INRCEngine__FundsStillUnhealthy();

    /////////////////////////
    // State variables  /////
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralsDeposited;
    mapping(address user => uint256 amountOfINRCMinted) private s_INRCMinted;

    address[] private s_collateralTokens;

    uint256 private s_USDToINRPrice;

    INRCoin private immutable i_inrCoin;

    ////////////////
    // Events  /////
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers  //
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert INRCEngine__AmountShouldBeGreaterThanZero();
        }
        _;
    }

    modifier allowedTokensOnly(address tokenContractAddress) {
        if (s_priceFeeds[tokenContractAddress] == address(0)) {
            revert INRCEngine__TokenNotAllowed(tokenContractAddress);
        }
        _;
    }

    ////////////////
    // Functions  //
    ////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address inrcTokenContractAddress,
        uint256 intialUsdToInrConversionRate
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert INRCEngine__NumberOfTokenAddressesAndPriceFeedAddressesShouldBeSame();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_inrCoin = INRCoin(inrcTokenContractAddress);
        s_USDToINRPrice = intialUsdToInrConversionRate;
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////

    /**
     *
     * @param collateralContractAddress Address of the token to be deposited as collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param amountOfINRCToMint The amount of INRC to mint
     * @notice This function will be used to deposit collaterla and mint INRC
     */
    function depositCollateralAndMintINRC(
        address collateralContractAddress,
        uint256 collateralAmount,
        uint256 amountOfINRCToMint
    ) external {
        depositCollateral(collateralContractAddress, collateralAmount);
        mintINRC(amountOfINRCToMint);
    }

    /**
     * @param collateralContractAddress Address of the token to be deposited as collateral
     * @param collateralAmount Amount of collateral to deposit
     */
    function depositCollateral(address collateralContractAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        allowedTokensOnly(collateralContractAddress)
        nonReentrant
    {
        s_collateralsDeposited[msg.sender][collateralContractAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralContractAddress, collateralAmount);
        bool success = IERC20(collateralContractAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert INRCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress Address of the collateral token
     * @param collateralAmount Amount of collateral
     * @param inrcAmountToBurn Amount of INRC to burn
     */
    function redeemCollateralForINRC(address tokenCollateralAddress, uint256 collateralAmount, uint256 inrcAmountToBurn)
        external
    {
        burnINRC(inrcAmountToBurn);
        redeemCollateral(tokenCollateralAddress, collateralAmount);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountOfINRCToMint The amount of INRC to mint
     * @dev Check if collateral value is greater than INRC amount
     */
    function mintINRC(uint256 amountOfINRCToMint) public moreThanZero(amountOfINRCToMint) nonReentrant {
        s_INRCMinted[msg.sender] += amountOfINRCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_inrCoin.mint(msg.sender, amountOfINRCToMint);
        if (!minted) {
            revert INRCEngine__MintFailed();
        }
    }

    function burnINRC(uint256 amount) public moreThanZero(amount) {
        _burnINRC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // ???
    }

    /**
     * If someone is almost undercollaterized you will be paid to liquidate them
     * @param collateral The collateral token address
     * @param user The user whose health factor is broken. Healthfactor should always be below MIN_HEALTH_FACTOR
     * @param debtToCover AMount of INRC to burn to improve health factor of the user
     * @notice You will get liquidation bonus for taking user's funds
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _getHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert INRCEngine__FundsAreHealthy();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromInr(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnINRC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _getHealthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert INRCEngine__FundsStillUnhealthy();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function setUsdToInrPrice(uint256 value) external {
        s_USDToINRPrice = value;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _getHealthFactor(user);
    }

    ///////////////////////////////////
    // Private & Internal Functions  //
    ///////////////////////////////////

    function _redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount, address from, address to)
        private
    {
        s_collateralsDeposited[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(to, collateralAmount);
        if (!success) {
            revert INRCEngine__TransferFailed();
        }
    }

    function _burnINRC(uint256 amountOfINRCToBurn, address onBehalfOf, address inrcFrom) private {
        s_INRCMinted[onBehalfOf] -= amountOfINRCToBurn;

        bool success = i_inrCoin.transferFrom(inrcFrom, address(this), amountOfINRCToBurn);
        if (!success) {
            revert INRCEngine__TransferFailed();
        }
        i_inrCoin.burn(amountOfINRCToBurn);
    }

    function _getAccountInfo(address user)
        private
        view
        returns (uint256 totalINRCMinted, uint256 collateralValueInINR)
    {
        totalINRCMinted = s_INRCMinted[user];
        collateralValueInINR = getAccountCollateralValue(user);
    }

    /**
     * @notice Returns how close to liquidation user is. If its is below 1, they are liquidated
     * @param user Address of the user
     * @dev Health Factor = (Total INRC Minted/Total collateral value)
     */
    function _getHealthFactor(address user) private view returns (uint256) {
        (uint256 totalINRCMinted, uint256 totalCollateralValueInINR) = _getAccountInfo(user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInINR * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalINRCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _getHealthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert INRCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    ///////////////////////////////////
    // Public & External Functions  ///
    ///////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getTokenAmountFromInr(address token, uint256 inrAmountInWei) public view returns (uint256) {
        return getTokenAmountFromUsd(token, (inrAmountInWei / s_USDToINRPrice)) * s_USDToINRPrice;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInINR) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralsDeposited[user][token];
            totalCollateralValueInINR += getInrValue(token, amount);
        }
        return totalCollateralValueInINR;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getInrValue(address token, uint256 amount) public view returns (uint256) {
        return getUsdValue(token, amount) * s_USDToINRPrice;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalINRCMinted, uint256 collateralValueInINR)
    {
        return _getAccountInfo(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralDeposited(address user, address token) external view returns (uint256) {
        return s_collateralsDeposited[user][token];
    }
}
