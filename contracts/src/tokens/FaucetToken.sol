// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FaucetToken
/// @notice Test-network ERC20: anyone can claim `faucetAmount` once per day, the owner can mint freely.
/// @dev For testnets only. Never deploy a token with a public faucet to mainnet.
contract FaucetToken is ERC20, Ownable {
    uint256 public constant FAUCET_COOLDOWN = 1 days;
    uint256 public immutable faucetAmount;

    mapping(address => uint256) public lastFaucetAt;

    error FaucetCooldown(uint256 availableAt);

    event FaucetClaimed(address indexed to, uint256 amount);

    constructor(string memory name, string memory symbol, uint256 _faucetAmount)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        faucetAmount = _faucetAmount;
    }

    /// @notice Claim free test tokens, once every 24 hours.
    function faucet() external {
        uint256 last = lastFaucetAt[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) {
            revert FaucetCooldown(last + FAUCET_COOLDOWN);
        }
        lastFaucetAt[msg.sender] = block.timestamp;
        _mint(msg.sender, faucetAmount);
        emit FaucetClaimed(msg.sender, faucetAmount);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
