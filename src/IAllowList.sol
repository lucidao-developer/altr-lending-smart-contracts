// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IAllowList {
    function isAddressAllowed(address user) external view returns (bool);
}
