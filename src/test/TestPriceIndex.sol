// SPDX_License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "../IPriceIndex.sol";

contract TestPriceIndex is IPriceIndex, ERC165 {
    mapping(address => mapping(uint256 => Valuation)) public valuations;

    function setValuation(address nftCollection, uint256 tokenId, uint256 price, uint256 ltv) external {
        valuations[nftCollection][tokenId] = Valuation(block.timestamp, price, ltv);
    }

    function getValuation(address nftCollection, uint256 tokenId) external view returns (Valuation memory valuation) {
        return valuations[nftCollection][tokenId];
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return type(IPriceIndex).interfaceId == interfaceId || super.supportsInterface(interfaceId);
    }
}
