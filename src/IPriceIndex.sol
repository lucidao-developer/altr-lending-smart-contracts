// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPriceIndex {
    struct Valuation {
        uint256 timestamp;
        uint256 price;
        uint256 ltv;
    }

    function getValuation(address nftCollection, uint256 tokenId)
        external
        view
        returns (Valuation calldata valuation);
}
