//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IUSDTEth {
    function totalSupply() external returns (uint256);
    function balanceOf(address who) external returns (uint256);
    function transfer(address to, uint256 value) external;
    function allowance(address owner, address spender) external returns (uint256);
    function transferFrom(address from, address to, uint256 value) external;
    function approve(address spender, uint256 value) external;
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external;
}
