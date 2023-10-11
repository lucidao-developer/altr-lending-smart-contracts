// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../IAllowList.sol";

contract TestAllowList is IAllowList, ERC165 {
    mapping(address => bool) private _isAddressAllowed;

    function allowAddresses(address[] calldata addresses) external {
        for (uint256 i = 0; i < addresses.length; i++) {
            _isAddressAllowed[addresses[i]] = true;
        }
    }

    function isAddressAllowed(address user) external view returns (bool) {
        return _isAddressAllowed[user];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAllowList).interfaceId || super.supportsInterface(interfaceId);
    }
}
