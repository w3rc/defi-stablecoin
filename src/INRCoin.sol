// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin INRC
 * @author w3rc
 * Collatoral: Exogenous(ETH/BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to 1 INR
 *
 * This contract is ERC20 implementation of the stablecoin. Governed by DSCEngine.sol
 */
contract INRCoin is ERC20Burnable, Ownable {
    error INRCoin__CannotBurnLessThanZero();
    error INRCoin__BurnAmountExceedsBalance();
    error INRCoin__CannotMintToZeroAddress();
    error INRCoin__MustMintMoreThanZero();

    constructor() ERC20("INRCoin", "INRC") Ownable(address(msg.sender)) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert INRCoin__CannotBurnLessThanZero();
        }
        if (balance < _amount) {
            revert INRCoin__BurnAmountExceedsBalance();
        }   
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert INRCoin__CannotMintToZeroAddress();
        }   
        if (_amount <=0) {
            revert INRCoin__MustMintMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
