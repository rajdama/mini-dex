// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pair, IPairDeployer} from "./Pair.sol";

/// @title Factory
/// @notice Creates one Pair per token pair, at an address anyone can compute in advance
///         (CREATE2 with the sorted token addresses as salt).
contract Factory is IPairDeployer {
    struct Parameters {
        address token0;
        address token1;
    }

    /// @notice Set only while a pair is being deployed; the Pair constructor reads it.
    ///         This keeps the Pair's init code (and so its CREATE2 address) independent of its tokens.
    Parameters public parameters;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error IdenticalTokens();
    error ZeroAddress();
    error PairExists();

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice keccak256 of the Pair creation code, for computing pair addresses off-chain.
    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalTokens();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        parameters = Parameters({token0: token0, token1: token1});
        pair = address(new Pair{salt: keccak256(abi.encodePacked(token0, token1))}());
        delete parameters;

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }
}
