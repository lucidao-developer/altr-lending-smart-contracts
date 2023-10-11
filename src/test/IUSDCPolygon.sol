//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IUSDCPolygon {
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        string memory tokenCurrency,
        uint8 tokenDecimals,
        address newMasterMinter,
        address newPauser,
        address newBlacklister,
        address newOwner
    ) external;
    function mint(address _to, uint256 _amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function initializeV2(string calldata name_) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function blacklist(address _account) external;
    function unBlacklist(address _account) external;
}