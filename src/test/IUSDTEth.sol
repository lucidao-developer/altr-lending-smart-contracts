//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IUSDTEth {
    function totalSupply() external returns (uint);
    function balanceOf(address who) external returns (uint);
    function transfer(address to, uint value) external;
    function allowance(address owner, address spender) external returns (uint);
    function transferFrom(address from, address to, uint value) external;
    function approve(address spender, uint value) external;
}