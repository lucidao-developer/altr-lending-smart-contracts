//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IUSDTPolygon {
    function initialize(string calldata name_, string calldata symbol_, uint8 decimals_, address childChainManager)
        external;
    function deposit(address user, bytes calldata depositData) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}
