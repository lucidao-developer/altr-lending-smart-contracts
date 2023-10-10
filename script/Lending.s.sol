// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Lending} from "../src/Lending.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdUtils.sol";

contract DeployLending is Script {
    uint256 immutable WEEK_1 = 7 * 60 * 60 * 24;
    uint256 immutable MONTHS_1 = 60 * 60 * 24 * 30;
    address GOVERNANCE_TREASURY_ADDRESS = vm.envAddress("GovernanceTreasuryAddress");
    address PRICE_INDEX_ADDRESS = vm.envAddress("PriceIndexAddress");
    address ALLOW_LIST_ADDRESS = vm.envAddress("AllowListAddress");
    address TREASURY_MANAGER = vm.envAddress("TreasuryManager");

    function run() external {
        uint256 protocolFee = 150; // 1.5%
        uint256 repayGracePeriod = 60 * 60 * 24 * 5; // 5 days
        uint256 repayGraceFee = 250; // 2.5%
        uint256[] memory originationFeeRanges = new uint256[](3);
        originationFeeRanges[0] = 50_000; // 50k
        originationFeeRanges[1] = 100_000; // 100k
        originationFeeRanges[2] = 500_000; // 500k
        uint256 liquidationFee = 500; // 5%
        uint256[] memory durations = new uint256[](5);
        durations[0] = WEEK_1;
        durations[1] = MONTHS_1;
        durations[2] = 3 * MONTHS_1;
        durations[3] = 6 * MONTHS_1;
        durations[4] = 12 * MONTHS_1;
        uint256[] memory interestRates = new uint256[](5);
        interestRates[0] = 660; // 6.6%
        interestRates[1] = 730; // 7.3 %
        interestRates[2] = 800; // 8 %
        interestRates[3] = 880; // 8.8 %
        interestRates[4] = 970; // 9.7 %
        uint256 baseOriginationFee = 100; // 1%
        uint256 lenderExclusiveLiquidationPeriod = 2 days;
        uint256 feeReductionFactor = 14_000; // 140%

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Deploying Lending contract...");
        vm.startBroadcast(deployerPrivateKey);
        Lending.ConstructorParams memory lendingParams = Lending.ConstructorParams(PRICE_INDEX_ADDRESS, GOVERNANCE_TREASURY_ADDRESS, ALLOW_LIST_ADDRESS, protocolFee, repayGracePeriod, repayGraceFee, originationFeeRanges, liquidationFee, durations, interestRates, baseOriginationFee, lenderExclusiveLiquidationPeriod, feeReductionFactor);
        Lending lending = new Lending(lendingParams);
        lending.grantRole(lending.TREASURY_MANAGER_ROLE(), TREASURY_MANAGER);
        vm.stopBroadcast();
        console.log("Lending contract successfully deplyed at: ", address(lending));
    }
}
