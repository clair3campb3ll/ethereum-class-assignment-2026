// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNPToken - ERC20 token representing Pick n Pay Smart Shopper points

contract PNPToken is ERC20 {
    /// @notice Deploys the token and mints the entire initial supply to the deployer
    /// @param initialSupply Total number of tokens to mint (in base units, 18 decimals)

    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply); // Mint the entire initial supply to the deployer
    }
}
