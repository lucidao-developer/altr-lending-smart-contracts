// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Lending} from "../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC721} from "../src/test/TestERC721.sol";
import {IPriceIndex} from "../src/IPriceIndex.sol";
import {TestPriceIndex} from "../src/test/TestPriceIndex.sol";
import {IUSDTEth} from "../src/test/IUSDTEth.sol";
import {TestLending} from "./Lending.t.sol";
import {TestAllowList} from "../src/test/TestAllowList.sol";

contract TestUSDTEth is Test {
    uint256 immutable WEEK_1 = 7 * 60 * 60 * 24;
    uint256 immutable MONTHS_1 = 60 * 60 * 24 * 30;
    uint256 immutable MONTHS_12 = 60 * 60 * 24 * 360;
    uint256 immutable DECIMALS = 10 ** 6;

    uint256 immutable INITIAL_TOKENS = 1_000_000e6;

    Lending public lending;
    IERC20 public token;
    IUSDTEth public usdt;
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
        uint256[] memory durations = new uint256[](3);
        durations[0] = 3 * MONTHS_1;
        durations[1] = 6 * MONTHS_1;
        durations[2] = 12 * MONTHS_1;
        uint256[] memory interestRates = new uint256[](3);
        interestRates[0] = 800; // 8%
        interestRates[1] = 880; // 8.8%
        interestRates[2] = 970; // 9.7%
        uint256 baseOriginationFee = 0; // 0%
        uint256 lenderExclusiveLiquidationPeriod = 2 days;
        uint256 feeReductionFactor = 14_000; // 140%

        allowList = new TestAllowList();
        priceIndex = new TestPriceIndex();
        Lending.ConstructorParams memory lendingParams = Lending.ConstructorParams(
            address(priceIndex),
            governanceTreasury,
            treasuryManager,
            address(allowList),
            protocolFee,
            repayGracePeriod,
            repayGraceFee,
            originationFeeRanges,
            liquidationFee,
            durations,
            interestRates,
            baseOriginationFee,
            lenderExclusiveLiquidationPeriod,
            feeReductionFactor
        );
        lending = new Lending(lendingParams);
        bytes memory tetherParams = abi.encode(4 * INITIAL_TOKENS, "Tether", "USDT", uint256(6));
        address usdtAddress = deployCode("USDTEth.sol:TetherToken", tetherParams);
        usdt = IUSDTEth(usdtAddress);
        token = IERC20(usdtAddress);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        lending.setTokens(tokens);

        usdt.transfer(borrower, INITIAL_TOKENS);
        usdt.transfer(lender, INITIAL_TOKENS);
        usdt.transfer(liquidator, INITIAL_TOKENS);
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
        usdt.approve(address(lending), type(uint256).max);
        nft.setApprovalForAll(address(lending), true);
        vm.stopPrank();

        vm.startPrank(lender);
        usdt.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdt.approve(address(lending), type(uint256).max);
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

    function testLendingWithParamUpdate() public {
        test.lendingTestWithParamUpdate(token);
    }

    function testZFuzz_Lending(uint256 collateralValue, uint256 repaymentDuration) public {
        test.zFuzz_Lending(token, collateralValue, repaymentDuration);
    }

    function testZFuzz_Liquidate(uint256 collateralValue) public {
        test.zFuzz_Liquidate(token, collateralValue);
    }

    function testZFuzz_LendingWithTokenFee(uint256 collateralValue, uint256 repaymentDuration) public {
        vm.assume(collateralValue > DECIMALS && collateralValue < type(uint256).max / (DECIMALS * 50));
        vm.assume(repaymentDuration > 1 days);
        vm.startPrank(admin);
        usdt.setParams(1, 49);
        vm.stopPrank();
        uint256 loanDuration = MONTHS_12;
        vm.assume(repaymentDuration < loanDuration);
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 1, collateralValue, 50);
        vm.stopPrank();
        uint256 maxBorrowAmount = collateralValue * DECIMALS / 2;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), maxBorrowAmount, address(nft), 1, loanDuration, MONTHS_12);
        assertEq(lending.lastLoanId(), 1);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, maxBorrowAmount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, loanDuration);

        vm.startPrank(lender);
        if (maxBorrowAmount > INITIAL_TOKENS) {
            return;
        }
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(repaymentDuration);

        vm.startPrank(borrower);
        uint256 feePlusInterest = lending.getDebtWithPenalty(
            maxBorrowAmount,
            lending.aprFromDuration(loanDuration) + lending.protocolFee(),
            loanDuration,
            block.timestamp
        ) + lending.getOriginationFee(maxBorrowAmount, address(token));
        uint256 interest = lending.getDebtWithPenalty(
            maxBorrowAmount, lending.aprFromDuration(loanDuration), loanDuration, repaymentDuration
        );

        if (maxBorrowAmount + feePlusInterest > INITIAL_TOKENS) {
            return;
        }
        lending.repayLoan(1);
        vm.stopPrank();

        assertApproxEqAbs(
            (borrowerStartBalance - token.balanceOf(borrower)) / DECIMALS, feePlusInterest / DECIMALS, 100 * DECIMALS
        );
        assertApproxEqAbs(
            (token.balanceOf(lender) - lenderStartBalance) / DECIMALS, interest / DECIMALS, 100 * DECIMALS
        );
        assertApproxEqAbs(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / DECIMALS,
            (feePlusInterest - interest) / DECIMALS,
            100 * DECIMALS
        );
    }

    function testZFuzz_LiquidateWithTokenFee(uint256 collateralValue) public {
        vm.assume(collateralValue > DECIMALS && collateralValue < type(uint256).max / (DECIMALS * 50));
        vm.startPrank(admin);
        usdt.setParams(1, 49);
        vm.stopPrank();
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);
        uint256 liquidatorStartBalance = token.balanceOf(liquidator);
        uint256 loanDuration = MONTHS_12;

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 1, collateralValue, 50);
        vm.stopPrank();
        uint256 maxBorrowAmount = collateralValue * DECIMALS / 2;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), maxBorrowAmount, address(nft), 1, loanDuration, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(lender);
        if (maxBorrowAmount > INITIAL_TOKENS) {
            return;
        }
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert("Lending: too early");
        lending.liquidateLoan(1);
        vm.warp(MONTHS_12 + lending.repayGracePeriod() + lending.lenderExclusiveLiquidationPeriod() + 1);
        uint256 feePlusInterest = lending.getDebtWithPenalty(
            maxBorrowAmount,
            lending.aprFromDuration(loanDuration) + lending.protocolFee(),
            loanDuration,
            block.timestamp
        ) + lending.getOriginationFee(maxBorrowAmount, address(token)) + lending.getLiquidationFee(maxBorrowAmount);
        uint256 interest = lending.getDebtWithPenalty(
            maxBorrowAmount, lending.aprFromDuration(loanDuration), loanDuration, block.timestamp
        );

        if (maxBorrowAmount + feePlusInterest > INITIAL_TOKENS) {
            return;
        }
        lending.liquidateLoan(1);
        vm.stopPrank();

        assertApproxEqRel(
            (token.balanceOf(borrower) - borrowerStartBalance) / DECIMALS, maxBorrowAmount / DECIMALS, 25e15
        );
        assertApproxEqRel((token.balanceOf(lender) - lenderStartBalance) / DECIMALS, interest / DECIMALS, 25e15);
        assertApproxEqRel(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / DECIMALS,
            (feePlusInterest - interest) / DECIMALS,
            25e15
        );
        assertApproxEqRel(
            (liquidatorStartBalance - token.balanceOf(liquidator)) / DECIMALS,
            (feePlusInterest + maxBorrowAmount) / DECIMALS,
            25e15
        );

        assertEq(nft.ownerOf(1), address(liquidator));
    }
}
