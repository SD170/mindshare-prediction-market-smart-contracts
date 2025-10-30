// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract StakeToken is ERC20 {
    constructor() ERC20("CourseToken", "CTKN") {
        _mint(msg.sender, 1e27); // 1B CTKN (18dp)
    }
}