// SPDX_License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20("TST20", "TST20") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
