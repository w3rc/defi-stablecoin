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
    error INRCEngine__TokenNotAllowed();
    error INRCEngine__TransferFailed();
    error INRCEngine__BreaksHealthFactor(uint256 healthFactor);
    error INRCEngine__MintFailed();

    /////////////////////////
    // State variables  /////
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

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
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

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
            revert INRCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////
    // Functions  //
    ////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address inrcTokenContractAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert INRCEngine__NumberOfTokenAddressesAndPriceFeedAddressesShouldBeSame();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }
        i_inrCoin = INRCoin(inrcTokenContractAddress);
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
        s_collateralsDeposited[msg.sender][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, collateralAmount);
        if (!success) {
            revert INRCEngine__TransferFailed();
        }
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
        s_INRCMinted[msg.sender] -= amount;

        bool success = i_inrCoin.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert INRCEngine__TransferFailed();
        }
        i_inrCoin.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // ???
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////
    // Private & Internal Functions  //
    ///////////////////////////////////

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
}
