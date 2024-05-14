// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "../../src/uniswap/IUniswapV2Factory.sol";

contract TestUniswapFactory is IUniswapV2Factory {
    function feeTo() external pure returns (address) {
        return address(0);
    }

    function feeToSetter() external pure returns (address) {
        return address(0);
    }

    function getPair(address tokenA, address tokenB) external pure returns (address pair) {
        pair = generateAddress(tokenA, tokenB);
    }

    function allPairs(uint256) external pure returns (address pair) {}

    function allPairsLength() external pure returns (uint256) {
        return 0;
    }

    function createPair(address tokenA, address tokenB) external pure returns (address pair) {
        pair = generateAddress(tokenA, tokenB);
    }

    function setFeeTo(address) external {}

    function setFeeToSetter(address) external {}

    function generateAddress(address addr1, address addr2) public pure returns (address) {
        // Concatenate the addresses and hash the result
        bytes32 hash = keccak256(abi.encodePacked(addr1, addr2));

        // Cast the bytes32 hash to an address
        return address(uint160(uint256(hash)));
    }
}
