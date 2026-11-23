// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Test (TEST)
/// @notice Plain fixed-supply launch token. The launch factory receives the entire supply.
contract LaunchToken is ERC20 {
    constructor() ERC20("Test", "TEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
