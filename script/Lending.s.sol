// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Lending} from "../src/Lending.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdUtils.sol";

contract DeployLending is Script {
    function run() external {
        address GOVERNANCE_TREASURY_ADDRESS = vm.envAddress("GovernanceTreasuryAddress");
        address PRICE_INDEX_ADDRESS = vm.envAddress("PriceIndexAddress");
        uint256 protocolFee = 15000; // 1.5%
        uint256 repayGracePeriod = 3600; // 1hr
        uint256 repayGraceFee = 25000; // 2.5%
        uint256 feeReductionFactor = 14000; // 1.4%
        uint256[] memory originationFeeRanges = new uint256[](3);
        originationFeeRanges[0] = 50000e18; // 50k
        originationFeeRanges[1] = 100000e18; // 100k
        originationFeeRanges[2] = 500000e18; // 500k
        uint256 liquidationFee = 30000; // 3%

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Deploying Lending contract...");
        vm.startBroadcast(deployerPrivateKey);
        Lending lending = new Lending(
            PRICE_INDEX_ADDRESS,
            GOVERNANCE_TREASURY_ADDRESS,
            protocolFee,
            repayGracePeriod,
            repayGraceFee,
            originationFeeRanges,
            feeReductionFactor,
            liquidationFee
        );
        vm.stopBroadcast();
        console.log("Lending contract successfully deplyed at: ", address(lending));
    }
}
