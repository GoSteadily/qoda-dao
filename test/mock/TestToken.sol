// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestToken is ERC20 {
    /// @notice Number of decimal places
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    /// @notice Overrides the standard 18 decimal places of OZ ERC20 contract
    /// with user-set decimals from constructor
    /// @return uint8 Number of decimal places
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints tokens to a recipient. This is an external function
    /// with no permissions so anyone can mint themselves infinite tokens.
    /// Use for testnet purposes only.
    /// @param recipient Account to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address recipient, uint256 amount) external returns (bool) {
        _mint(recipient, amount);
        return true;
    }
}
