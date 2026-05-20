// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
/// @title FNBToken - ERC20 token representing FNB eBucks

contract FNBToken is ERC20 {
    /// @notice Deploys the token and mints the entire initial supply to the deployer
    /// @param initialSupply Total number of tokens to mint (in base units, 18 decimals)

    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply); // Mint the entire initial supply to the deployer
    }
}
