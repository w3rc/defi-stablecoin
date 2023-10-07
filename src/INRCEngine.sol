// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {INRCoin} from "./INRStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /////////////////////////
    // State variables  /////
    /////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralsDeposited;

    INRCoin private immutable inrCoin;

    ////////////////
    // Events  /////
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
        inrCoin = INRCoin(inrcTokenContractAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////
    function depositCollateralAndMintINRC() external {}

    /**
     * @param collateralContractAddress Address of the token to be deposited as collateral
     * @param collateralAmount Amount of collateral to deposit
     */
    function depositCollateral(address collateralContractAddress, uint256 collateralAmount)
        external
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

    function redeemCollateralForINRC() external {}

    function redeemCollateral() external {}

    function mintINRC() external {}

    function burnINRC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
