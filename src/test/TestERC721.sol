// SPDX_License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

contract TestERC721 is ERC721URIStorage {
    constructor() ERC721("TST721", "TST721") {}

    function mint(address to, uint256 tokenId, string memory uri) public {
        _mint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }
}
