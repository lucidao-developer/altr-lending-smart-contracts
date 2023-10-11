// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Lending} from "../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC721} from "../src/test/TestERC721.sol";
import {IPriceIndex} from "../src/IPriceIndex.sol";
import {TestPriceIndex} from "../src/test/TestPriceIndex.sol";
import {IUSDTPolygon} from "../src/test/IUSDTPolygon.sol";
import {TestLending} from "./Lending.t.sol";
import {TestAllowList} from "../src/test/TestAllowList.sol";

contract TestUSDTPolygon is Test {
    uint256 immutable WEEK_1 = 7 * 60 * 60 * 24;
    uint256 immutable MONTHS_1 = 60 * 60 * 24 * 30;
    uint256 immutable MONTHS_18 = 60 * 60 * 24 * 540;

    uint256 immutable INITIAL_TOKENS = 1_000_000e6;

    Lending public lending;
    IERC20 public token;
    TestERC721 public nft;
    TestPriceIndex public priceIndex;
    TestLending public test;
    TestAllowList public allowList;

    address admin = address(0x1);
    address borrower = address(0x2);
    address lender = address(0x3);
    address governanceTreasury = address(0x4);
    address liquidator = address(0x5);
    address treasuryManager = address(0xDA0);

    function setUp() public {
        vm.startPrank(admin);
        uint256 protocolFee = 150; // 1.5%
        uint256 repayGracePeriod = 60 * 60 * 24 * 5; // 5 days
        uint256 repayGraceFee = 250; // 2.5
        uint256[] memory originationFeeRanges = new uint256[](3);
        originationFeeRanges[0] = 50_000; // 50k
        originationFeeRanges[1] = 100_000; // 100k
        originationFeeRanges[2] = 500_000; // 500k
        uint256 liquidationFee = 500; // 5%
        uint256[] memory durations = new uint256[](6);
        durations[0] = WEEK_1;
        durations[1] = MONTHS_1;
        durations[2] = 3 * MONTHS_1;
        durations[3] = 6 * MONTHS_1;
        durations[4] = 12 * MONTHS_1;
        durations[5] = MONTHS_18;
        uint256[] memory interestRates = new uint256[](6);
        interestRates[0] = 660; // 6.6%
        interestRates[1] = 730; // 7.3%
        interestRates[2] = 800; // 8%
        interestRates[3] = 880; // 8.8%
        interestRates[4] = 970; // 9.7%
        interestRates[5] = 1070; // 10.7%
        uint256 baseOriginationFee = 100; // 1%
        uint256 lenderExclusiveLiquidationPeriod = 2 days;
        uint256 feeReductionFactor = 14_000; // 140%

        allowList = new TestAllowList();
        priceIndex = new TestPriceIndex();
        Lending.ConstructorParams memory lendingParams = Lending.ConstructorParams(address(priceIndex), governanceTreasury, address(allowList), protocolFee, repayGracePeriod, repayGraceFee, originationFeeRanges, liquidationFee, durations, interestRates, baseOriginationFee, lenderExclusiveLiquidationPeriod, feeReductionFactor);
        lending = new Lending(lendingParams);
        lending.grantRole(lending.TREASURY_MANAGER_ROLE(), treasuryManager);

        address usdtAddress = deployCode("USDTPolygon.sol:UChildERC20");
        IUSDTPolygon usdt = IUSDTPolygon(usdtAddress);
        token = IERC20(usdtAddress);
        usdt.initialize("USDTPolygon", "USDT", 6, admin);
        usdt.deposit(borrower, abi.encode(INITIAL_TOKENS));
        usdt.deposit(lender, abi.encode(INITIAL_TOKENS));
        usdt.deposit(liquidator, abi.encode(INITIAL_TOKENS));
        assertEq(usdt.balanceOf(borrower), INITIAL_TOKENS);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        lending.setTokens(tokens);

        nft = new TestERC721();

        address[] memory nfts = new address[](1);
        nfts[0] = address(nft);
        priceIndex.setValuation(address(nft), 1, 200_000, 50);
        priceIndex.setValuation(address(nft), 2, 200_000, 50);

        nft.mint(borrower, 1, "");
        nft.mint(borrower, 2, "");

        priceIndex.setValuation(address(0xC0113C71), 0, 1000, 50);

        address[] memory allowedAddresses = new address[](4);
        allowedAddresses[0] = borrower;
        allowedAddresses[1] = lender;
        allowedAddresses[2] = liquidator;
        allowedAddresses[3] = admin;
        allowList.allowAddresses(allowedAddresses);
        vm.stopPrank();

        vm.startPrank(borrower);
        token.approve(address(lending), 2 ** 256 - 1);
        nft.setApprovalForAll(address(lending), true);
        vm.stopPrank();

        vm.startPrank(lender);
        token.approve(address(lending), 2 ** 256 - 1);
        vm.stopPrank();

        vm.startPrank(liquidator);
        token.approve(address(lending), 2 ** 256 - 1);
        vm.stopPrank();

        test = new TestLending(lending, nft, priceIndex, allowList, 6);
    }

    function testLending() public {
        test.lendingTest(token);
    }

    function testGracePeriod() public {
        test.gracePeriod(token);
    }

    function testSetters() public {
        test.setters(token);
    }

    function testLiquidate() public {
        test.liquidate(token);
    }

    function testClaimNFT() public {
        test.claimNFT(token);
    }

    function testCancelLoan() public {
        test.cancelLoan(token);
    }

    function testLoanDeadline() public {
        test.loanDeadline(token);
    }

    function testRepayLoan() public {
        test.repayLoan(token);
    }

    function testZFuzz_Lending(uint256 amount, uint256 repaymentDuration) public {
        test.zFuzz_Lending(token, amount, repaymentDuration);
    }

    function testZFuzz_Liquidate(uint256 amount) public {
        test.zFuzz_Liquidate(token, amount);
    }
}
