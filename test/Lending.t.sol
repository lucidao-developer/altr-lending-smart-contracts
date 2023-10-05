// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Lending} from "../src/Lending.sol";
import {TestERC20} from "../src/test/TestERC20.sol";
import {TestERC721} from "../src/test/TestERC721.sol";
import {IPriceIndex} from "../src/IPriceIndex.sol";
import {TestPriceIndex} from "../src/test/TestPriceIndex.sol";
import "forge-std/console.sol";

contract TestLending is Test {
    uint256 immutable WEEK_1 = 7 * 60 * 60 * 24;
    uint256 immutable MONTHS_1 = 60 * 60 * 24 * 30;
    uint256 immutable MONTHS_18 = 60 * 60 * 24 * 540;

    uint256 immutable INITIAL_TOKENS = 1_000_000e18;

    Lending public lending;
    TestERC20 public token;
    TestERC721 public nft;
    TestPriceIndex public priceIndex;

    address admin = address(0x1);
    address borrower = address(0x2);
    address lender = address(0x3);
    address governanceTreasury = address(0x4);
    address liquidator = address(0x5);

    function setUp() public {
        vm.startPrank(admin);
        uint256 protocolFee = 150; // 1.5%
        uint256 repayGracePeriod = 60 * 60 * 24 * 5; // 5 days
        uint256 repayGraceFee = 250; // 2.5
        uint256 feeReductionFactor = 14000; // 140%
        uint256[] memory originationFeeRanges = new uint256[](3);
        originationFeeRanges[0] = 50000e18;
        originationFeeRanges[1] = 100000e18;
        originationFeeRanges[2] = 500000e18;
        uint256 liquidationFee = 500; // 5%
        uint256[] memory durations = new uint256[](6);
        durations[0] = WEEK_1;
        durations[1] = MONTHS_1;
        durations[2] = 3 * MONTHS_1;
        durations[3] = 6 * MONTHS_1;
        durations[4] = 12 * MONTHS_1;
        durations[5] = MONTHS_18;
        uint256[] memory interestRates = new uint256[](6);
        interestRates[0] = 660;
        interestRates[1] = 730;
        interestRates[2] = 800;
        interestRates[3] = 880;
        interestRates[4] = 970;
        interestRates[5] = 1070;
        uint256 baseOriginationFee = 100; // 1%

        priceIndex = new TestPriceIndex();
        lending = new Lending(
            address(priceIndex),
            governanceTreasury,
            protocolFee,
            repayGracePeriod,
            repayGraceFee,
            originationFeeRanges,
            feeReductionFactor,
            liquidationFee,
            durations,
            interestRates,
            baseOriginationFee
        );
        token = new TestERC20();
        nft = new TestERC721();

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        lending.setTokens(tokens);

        address[] memory nfts = new address[](1);
        nfts[0] = address(nft);
        priceIndex.setValuation(address(nft), 1, 200_000, 50);
        priceIndex.setValuation(address(nft), 2, 200_000, 50);

        token.mint(borrower, INITIAL_TOKENS);
        token.mint(lender, INITIAL_TOKENS);
        token.mint(liquidator, INITIAL_TOKENS);

        nft.mint(borrower, 1, "");
        nft.mint(borrower, 2, "");

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
    }

    function testLending() public {
        uint256 borrowAmount = 100_000e18;

        vm.startPrank(borrower);
        vm.expectRevert("Lending: borrow token not allowed");
        lending.requestLoan(address(0), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.expectRevert("Lending: invalid duration");
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, 0, MONTHS_18);
        vm.expectRevert("Lending: borrow amount must be greater than zero");
        lending.requestLoan(address(token), 0, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.expectRevert("Lending: deadline must be after current timestamp");
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, block.timestamp - 1);
        vm.expectRevert("Lending: amount greater than max borrow");
        lending.requestLoan(address(token), borrowAmount + 1, address(nft), 1, MONTHS_18, MONTHS_18);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        assertEq(lending.lastLoanId(), 1);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, borrowAmount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, MONTHS_18);

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(MONTHS_1);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        assertEq(token.balanceOf(borrower) / 1e18, 997_512);
        assertEq(token.balanceOf(lender) / 1e18, 1_001_733);
        assertEq(token.balanceOf(governanceTreasury) / 1e18, 753);

        assertEq(nft.ownerOf(1), address(borrower));

        vm.startPrank(borrower);
        vm.warp(6 * MONTHS_1);
        vm.expectRevert("Lending: valuation expired");
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 100, 101);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: ltv greater than max");
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_18, MONTHS_18);
        vm.stopPrank();
    }

    function testGracePeriod() public {
        uint256 borrowAmount = 100_000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, borrowAmount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, MONTHS_18);

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(MONTHS_18 + 1000);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        assertEq(token.balanceOf(borrower) / 1e18, 978_288);
        assertEq(token.balanceOf(lender) / 1e18, 1_016_050);
        assertEq(token.balanceOf(governanceTreasury) / 1e18, 5_661);

        assertEq(nft.ownerOf(1), address(borrower));
    }

    function testSetters() public {
        vm.startPrank(admin);

        assertEq(lending.getOriginationFee(500_000e18), 1822157434402332361500);

        vm.expectRevert("Lending: cannot be less than min grace period");
        lending.setRepayGracePeriod(172799);
        vm.expectRevert("Lending: cannot be more than max grace period");
        lending.setRepayGracePeriod(1296000);
        lending.setRepayGracePeriod(172800);
        assertEq(lending.repayGracePeriod(), 172800);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setRepayGraceFee(401);
        lending.setRepayGraceFee(400);
        assertEq(lending.repayGraceFee(), 400);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setLiquidationFee(1501);
        lending.setLiquidationFee(1500);
        assertEq(lending.liquidationFee(), 1500);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setProtocolFee(401);
        lending.setProtocolFee(400);
        assertEq(lending.protocolFee(), 400);

        vm.expectRevert("Lending: fee reduction factor cannot be less than PRECISION");
        lending.setFeeReductionFactor(9999);
        lending.setFeeReductionFactor(10000);
        assertEq(lending.feeReductionFactor(), 10000);

        vm.expectRevert("Lending: cannot be null address");
        lending.setPriceIndex(address(0));
        vm.expectRevert("Lending: does not support IPriceIndex interface");
        lending.setPriceIndex(borrower);
        lending.setPriceIndex(address(priceIndex));
        assertEq(address(lending.priceIndex()), address(priceIndex));

        vm.expectRevert("Lending: cannot be null address");
        lending.setGovernanceTreasury(address(0));
        lending.setGovernanceTreasury(governanceTreasury);
        assertEq(lending.governanceTreasury(), governanceTreasury);

        address[] memory nfts = new address[](1);
        nfts[0] = address(nft);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        lending.setTokens(tokens);
        assertEq(lending.allowedTokens(tokens[0]), true);
        lending.unsetTokens(tokens);
        assertEq(lending.allowedTokens(tokens[0]), false);

        uint256[] memory durations = new uint256[](2);
        uint256[] memory aprs = new uint256[](1);
        durations[0] = MONTHS_18;
        aprs[0] = 1070;
        vm.expectRevert("Lending: invalid input");
        lending.setLoanTypes(durations, aprs);
        vm.expectRevert("Lending: cannot be more than max");
        durations = new uint256[](1);
        durations[0] = MONTHS_18;
        aprs[0] = 2001;
        lending.setLoanTypes(durations, aprs);

        vm.expectRevert("Lending: cannot be 0");
        aprs[0] = 0;
        lending.setLoanTypes(durations, aprs);

        aprs[0] = 2000;
        lending.setLoanTypes(durations, aprs);
        assertEq(lending.aprFromDuration(durations[0]), 2000);
        lending.unsetLoanTypes(durations);
        assertEq(lending.aprFromDuration(durations[0]), 0);

        vm.expectRevert("Lending: cannot be an empty array");
        uint256[] memory emptyRanges = new uint256[](0);
        lending.setRanges(emptyRanges);
        vm.expectRevert("Lending: first entry must be greater than 0");
        uint256[] memory newRanges = new uint256[](3);
        newRanges[0] = 0;
        lending.setRanges(newRanges);
        vm.expectRevert("Lending: entries must be strictly increasing");
        newRanges[0] = 1000;
        newRanges[1] = 1000;
        newRanges[2] = 3000;
        lending.setRanges(newRanges);
        newRanges[1] = 2000;
        lending.setRanges(newRanges);
        assertEq(lending.originationFeeRanges(0), 1000);
        assertEq(lending.originationFeeRanges(1), 2000);
        assertEq(lending.originationFeeRanges(2), 3000);

        vm.expectRevert("Lending: cannot be more than max length");
        uint256[] memory wrongRanges = new uint256[](7);
        wrongRanges[0] = 1000;
        wrongRanges[1] = 2000;
        wrongRanges[2] = 3000;
        wrongRanges[3] = 4000;
        wrongRanges[4] = 5000;
        wrongRanges[5] = 6000;
        wrongRanges[6] = 7000;
        lending.setRanges(wrongRanges);


        vm.expectRevert("Lending: cannot be more than max");
        lending.setBaseOriginationFee(301);
        lending.setBaseOriginationFee(300);
        assertEq(lending.baseOriginationFee(), 300);

        token.mint(borrower, INITIAL_TOKENS);
        assertEq(token.balanceOf(borrower) / 1e18, 2_000_000);
        nft.mint(borrower, 3, "");
        assertEq(nft.ownerOf(3), address(borrower));

        priceIndex.setValuation(address(nft), 1, 2_000_000, 100);
        (, uint256 price, uint256 ltv) = priceIndex.valuations(address(nft), 1);
        assertEq(price, 2_000_000);
        assertEq(ltv, 100);

        vm.stopPrank();
    }

    function testLiquidate() public {
        uint256 borrowAmount = 100_000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert("Lending: invalid loan id");
        lending.liquidateLoan(0);
        vm.expectRevert("Lending: too early");
        lending.liquidateLoan(1);
        vm.warp(MONTHS_18 + lending.repayGracePeriod() + 1);
        lending.liquidateLoan(1);
        vm.expectRevert("Lending: loan already paid");
        lending.liquidateLoan(1);
        vm.stopPrank();

        assertEq(token.balanceOf(borrower) / 1e18, 1_100_000);
        assertEq(token.balanceOf(lender) / 1e18, 1_016_050);
        assertEq(token.balanceOf(governanceTreasury) / 1e18, 7_760);
        assertEq(token.balanceOf(liquidator) / 1e18, 876_189);

        assertEq(nft.ownerOf(1), address(liquidator));
    }

    function testClaimNFT() public {
        uint256 borrowAmount = 100_000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        lending.acceptLoan(2);
        vm.stopPrank();

        vm.startPrank(borrower);
        lending.repayLoan(2);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert("Lending: invalid loan id");
        lending.claimNFT(0);
        vm.expectRevert("Lending: too early");
        lending.claimNFT(1);
        vm.stopPrank();
        vm.warp(MONTHS_18 + lending.repayGracePeriod() + 1);

        vm.startPrank(admin);
        vm.expectRevert("Lending: only the lender can claim the nft");
        lending.claimNFT(1);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert("Lending: loan already paid");
        lending.claimNFT(2);
        lending.claimNFT(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), address(lender));
    }

    function testCancelLoan() public {
        uint256 borrowAmount = 100000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(2);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: invalid loan id");
        lending.cancelLoan(0);
        vm.expectRevert("Lending: loan already accepted");
        lending.cancelLoan(2);

        lending.cancelLoan(1);
        vm.expectRevert("Lending: loan already cancelled");
        lending.cancelLoan(1);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert("Lending: invalid loan id");
        lending.acceptLoan(0);
        vm.expectRevert("Lending: loan cancelled");
        lending.acceptLoan(1);
        vm.stopPrank();
    }

    function testLoanDeadline() public {
        uint256 borrowAmount = 100000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.warp(MONTHS_18 + 1);

        vm.startPrank(lender);
        vm.expectRevert("Lending: loan acceptance deadline passed");
        lending.acceptLoan(1);
        vm.stopPrank();
    }

    function testRepayLoan() public {
        uint256 borrowAmount = 100000e18;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_18, MONTHS_18);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_18, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        lending.acceptLoan(2);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: invalid loan id");
        lending.repayLoan(0);
        lending.repayLoan(1);
        vm.expectRevert("Lending: loan already paid");
        lending.repayLoan(1);

        vm.warp(MONTHS_18 + lending.repayGracePeriod() + 1);
        vm.expectRevert("Lending: too late");
        lending.repayLoan(2);
        vm.stopPrank();
    }

    function testZFuzz_Lending(uint256 amount, uint256 repaymentDuration) public {
        vm.assume(amount > 0);
        vm.assume(repaymentDuration > 0);
        uint256 loanDuration = MONTHS_18;
        vm.assume(repaymentDuration < loanDuration);
        uint256 maxBorrowAmount = 100000e18;
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);

        vm.startPrank(borrower);
        if (amount > maxBorrowAmount) {
            vm.expectRevert("Lending: amount greater than max borrow");
            lending.requestLoan(address(token), amount, address(nft), 1, MONTHS_18, MONTHS_18);
            return;
        }
        lending.requestLoan(address(token), amount, address(nft), 1, loanDuration, MONTHS_18);
        assertEq(lending.lastLoanId(), 1);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, amount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, loanDuration);

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(repaymentDuration);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        uint256 feePlusInterest = lending.getDebtWithPenalty(
            amount, lending.aprFromDuration(loanDuration) + lending.protocolFee(), loanDuration, block.timestamp
        ) + lending.getOriginationFee(amount);
        uint256 interest =
            lending.getDebtWithPenalty(amount, lending.aprFromDuration(loanDuration), loanDuration, repaymentDuration);

        assertEq((borrowerStartBalance - token.balanceOf(borrower)) / 1e18, (feePlusInterest) / 1e18);
        assertEq((token.balanceOf(lender) - lenderStartBalance) / 1e18, interest / 1e18);
        assertEq(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / 1e18, (feePlusInterest - interest) / 1e18
        );
    }

    function testZFuzz_Liquidate(uint256 amount) public {
        vm.assume(amount > 0);
        uint256 maxBorrowAmount = 100000e18;
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);
        uint256 liquidatorStartBalance = token.balanceOf(liquidator);
        uint256 loanDuration = MONTHS_18;

        vm.startPrank(borrower);
        if (amount > maxBorrowAmount) {
            vm.expectRevert("Lending: amount greater than max borrow");
            lending.requestLoan(address(token), amount, address(nft), 1, loanDuration, MONTHS_18);
            return;
        }
        lending.requestLoan(address(token), amount, address(nft), 1, loanDuration, MONTHS_18);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.warp(MONTHS_18 + lending.repayGracePeriod() + 1);
        lending.liquidateLoan(1);
        vm.stopPrank();

        uint256 feePlusInterest = lending.getDebtWithPenalty(
            amount, lending.aprFromDuration(loanDuration) + lending.protocolFee(), loanDuration, block.timestamp
        ) + lending.getOriginationFee(amount) + lending.getLiquidationFee(amount);
        uint256 interest =
            lending.getDebtWithPenalty(amount, lending.aprFromDuration(loanDuration), loanDuration, block.timestamp);

        assertEq((token.balanceOf(borrower) - borrowerStartBalance) / 1e18, amount / 1e18);
        assertEq((token.balanceOf(lender) - lenderStartBalance) / 1e18, interest / 1e18);
        assertEq(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / 1e18, (feePlusInterest - interest) / 1e18
        );
        assertEq((liquidatorStartBalance - token.balanceOf(liquidator)) / 1e18, (feePlusInterest + amount) / 1e18);

        assertEq(nft.ownerOf(1), address(liquidator));
    }
}
