// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {Lending} from "../src/Lending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC721} from "../src/test/TestERC721.sol";
import {IPriceIndex} from "../src/IPriceIndex.sol";
import {TestPriceIndex} from "../src/test/TestPriceIndex.sol";
import {TestAllowList} from "../src/test/TestAllowList.sol";

contract TestLending is Test {
    uint256 immutable WEEK_1 = 7 * 60 * 60 * 24;
    uint256 immutable MONTHS_1 = 60 * 60 * 24 * 30;
    uint256 immutable MONTHS_12 = 60 * 60 * 24 * 360;

    uint256 immutable DECIMALS;
    uint256 immutable INITIAL_TOKENS;

    Lending public lending;
    TestERC721 public nft;
    TestPriceIndex public priceIndex;
    TestAllowList public allowList;

    address admin = address(0x1);
    address borrower = address(0x2);
    address lender = address(0x3);
    address governanceTreasury = address(0x4);
    address liquidator = address(0x5);
    address nonAllowed = address(0x6);
    address treasuryManager = address(0xDA0);

    constructor(
        Lending _lending,
        TestERC721 _nft,
        TestPriceIndex _priceIndex,
        TestAllowList _allowList,
        uint256 _decimals
    ) {
        lending = _lending;
        nft = _nft;
        priceIndex = _priceIndex;
        allowList = _allowList;
        DECIMALS = 10 ** _decimals;
        INITIAL_TOKENS = 1_000_000 * DECIMALS;
    }

    function lendingTest(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;
        vm.startPrank(admin);
        lending.disallowNFT(address(nft), 2);
        vm.stopPrank();

        vm.startPrank(nonAllowed);
        vm.expectRevert("Lending: address not allowed");
        lending.requestLoan(address(token), 0, address(nft), 0, MONTHS_12, MONTHS_12);
        vm.expectRevert("Lending: address not allowed");
        lending.acceptLoan(0);
        vm.expectRevert("Lending: address not allowed");
        lending.repayLoan(0);
        vm.expectRevert("Lending: address not allowed");
        lending.liquidateLoan(0);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: only the contract itself can call this function");
        lending.attemptTransfer(address(token), borrower, lender, 100);
        vm.expectRevert("Lending: you have no stuck tokens");
        lending.withdrawStuckToken(address(token));
        vm.expectRevert("Lending: cannot use this NFT as collateral");
        lending.requestLoan(address(token), 100, address(nft), 2, MONTHS_12, MONTHS_12);
        vm.expectRevert("Lending: borrow token not allowed");
        lending.requestLoan(address(0), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.expectRevert("Lending: invalid duration");
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, 0, MONTHS_12);
        vm.expectRevert("Lending: borrow amount must be greater than zero");
        lending.requestLoan(address(token), 0, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.expectRevert("Lending: deadline must be after current timestamp");
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, block.timestamp - 1);
        vm.expectRevert("Lending: amount greater than max borrow");
        lending.requestLoan(address(token), borrowAmount + 1, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.expectRevert("Lending: collection does not support IERC721 interface");
        lending.requestLoan(address(token), 50, address(0xC0113C710), 0, MONTHS_12, MONTHS_12);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        assertEq(lending.lastLoanId(), 1);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, borrowAmount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, MONTHS_12);

        vm.startPrank(admin);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        lending.unsetTokens(tokens);
        lending.disallowNFT(address(nft), 1);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert("Lending: borrow token not allowed");
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(admin);
        lending.setTokens(tokens);
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert("Lending: cannot use this NFT as collateral");
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(admin);
        lending.allowNFT(address(nft), 1);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(MONTHS_1);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        // interests + protocol fee = borrowAmount * (interestRate + protocol fee) * repaymentDuration / (360 days * 100)
        // interests + protocol fee = 100_000 * 11.2 * 2_592_000 / (31_104_000 * 100) = 933.33
        // penalty + fee = [(loanDuration - repaymentDuration) / loanDuration] * (interests + protocol fee)
        // penalty + fee = (31_104_000 - 2_592_000) / 31_104_000 * 933.33 = 855.55
        // origination fee = borrowAmount * origination fee = 100_000 * ((0 * (5/7)) * 5/7) = 0
        // interests = borrowAmount * interestRate * repaymentDuration / (360 days * 100)
        // interests = 100_000 * 9.7 * 2_592_000 / (31_104_000 * 100) = 808.33
        // penalty = [(loanDuration - repaymentDuration) / loanDuration] * interests
        // penalty = (31_104_000 - 2_592_000) / 31_104_000 * 808.33 = 740.96
        assertEq(token.balanceOf(borrower) / DECIMALS, 998_211); // initialBalance - (interest + protocol fee + origination fee + penalty) = 1_000_000 - [933.33 + 0 + 855.55] = 998_211.12
        assertEq(token.balanceOf(lender) / DECIMALS, 1_001_549); // intialBalance + interests + penalty = 1_000_000 + 808.33 + 740.96 ~ 1_001_549
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 239); // protocol fee + origination fee = [(933.33-808.33) + (855.55-740.96) + 0] = 239.59

        assertEq(nft.ownerOf(1), address(borrower));

        vm.startPrank(admin);
        lending.allowNFT(address(nft), 2);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.warp(6 * MONTHS_1);
        vm.expectRevert("Lending: valuation expired");
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 100, 101);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: ltv greater than max");
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 200_000, 50);
        vm.stopPrank();

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 100_000, 50);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: loan undercollateralized");
        lending.acceptLoan(2);

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 100_000, 101);
        vm.stopPrank();

        vm.startPrank(borrower);
        vm.expectRevert("Lending: ltv greater than max");
        lending.acceptLoan(2);

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 2, 200_000, 50);
        vm.stopPrank();

        vm.warp(priceIndex.getValuation(address(nft), 2).timestamp + lending.VALUATION_EXPIRY() + 1);

        vm.startPrank(borrower);
        vm.expectRevert("Lending: valuation expired");
        lending.acceptLoan(2);
        vm.stopPrank();
    }

    function gracePeriod(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        Lending.Loan memory loan = lending.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.amount, borrowAmount);
        assertEq(loan.token, address(token));
        assertEq(loan.nftCollection, address(nft));
        assertEq(loan.nftId, 1);
        assertEq(loan.duration, MONTHS_12);

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(MONTHS_12 + 1_000);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        // interests + protocol fee = borrowAmount * (interestRate + protocol fee) * repaymentDuration / (360 days * 100)
        // interests + protocol fee = 100_000 * 11.2 * 31_104_000 / (31_104_000 * 100) = 11_200
        // penalty + fee = [(loanDuration - repaymentDuration) / loanDuration] * (interests + protocol fee)
        // penalty + fee = 0 / 31_104_000 * 11_200 = 0
        // origination fee = borrowAmount * origination fee = 100_000 * ((0 * (5/7)) * 5/7) = 0
        // interests = borrowAmount * interestRate * repaymentDuration / (360 days * 100)
        // interests = 100_000 * 9.7 * 31_104_000 / (31_104_000 * 100) = 9_700
        // penalty = [(loanDuration - repaymentDuration) / loanDuration] * interests
        // penalty = 0 / 31_104_000 * 891.67 = 0
        // grace period fee = (borrowAmount + interests) * grace period fee / 100 = (100_000 + 9_700) * 2.5 / 100 = 2_742.5
        assertEq(token.balanceOf(borrower) / DECIMALS, 986_057); // initialBalance - (interests + protocol fee + origination fee + repay grace fee) = 1_000_000 - (11_200 + 0 + 2_742.5) = 986_057.5
        assertEq(token.balanceOf(lender) / DECIMALS, 1_009_700); // intialBalance + interests + penalty = 1_000_000 + 9_700 + 0 = 1_009_700
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 4_242); // protocol fee + origination fee + repay grace period fee = (11_200 - 9_700) + 0 + 2_742.5 = 4_242.5

        assertEq(nft.ownerOf(1), address(borrower));
    }

    function setters(IERC20 token) public {
        vm.startPrank(admin);

        assertEq(lending.getOriginationFee(500_000 * DECIMALS, address(token)), 0);

        vm.expectRevert("Lending: cannot be less than min grace period");
        lending.setRepayGracePeriod(172_799);
        vm.expectRevert("Lending: cannot be more than max grace period");
        lending.setRepayGracePeriod(1_296_000);
        lending.setRepayGracePeriod(172_800);
        assertEq(lending.repayGracePeriod(), 172_800);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setRepayGraceFee(401);
        lending.setRepayGraceFee(400);
        assertEq(lending.repayGraceFee(), 400);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setLiquidationFee(1_501);
        lending.setLiquidationFee(1500);
        assertEq(lending.liquidationFee(), 1_500);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setProtocolFee(401);
        lending.setProtocolFee(400);
        assertEq(lending.protocolFee(), 400);

        vm.expectRevert("Lending: fee reduction factor cannot be less than PRECISION");
        lending.setFeeReductionFactor(9_999);
        lending.setFeeReductionFactor(10_000);
        assertEq(lending.feeReductionFactor(), 10_000);

        vm.expectRevert("Lending: cannot be null address");
        lending.setPriceIndex(address(0));
        vm.expectRevert("Lending: does not support IPriceIndex interface");
        lending.setPriceIndex(borrower);
        lending.setPriceIndex(address(priceIndex));
        assertEq(address(lending.priceIndex()), address(priceIndex));

        vm.expectRevert("Lending: cannot be null address");
        lending.setAllowList(address(0));
        vm.expectRevert("Lending: does not support IAllowList interface");
        lending.setAllowList(borrower);
        lending.setAllowList(address(allowList));
        assertEq(address(lending.allowList()), address(allowList));

        vm.expectRevert("Lending: cannot be less than min exclusive period");
        lending.setLenderExclusiveLiquidationPeriod(1 days - 1);
        vm.expectRevert("Lending: cannot be more than max exclusive period");
        lending.setLenderExclusiveLiquidationPeriod(5 days + 1);
        lending.setLenderExclusiveLiquidationPeriod(4 days);
        assertEq(lending.lenderExclusiveLiquidationPeriod(), 4 days);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(
            "AccessControl: account 0x0000000000000000000000000000000000000001 is missing role 0xede9dcdb0ce99dc7cec9c7be9246ad08b37853683ad91569c187b647ddf5e21c"
        );
        lending.setGovernanceTreasury(governanceTreasury);
        vm.stopPrank();

        vm.startPrank(treasuryManager);
        vm.expectRevert("Lending: cannot be null address");
        lending.setGovernanceTreasury(address(0));
        lending.setGovernanceTreasury(governanceTreasury);
        assertEq(lending.governanceTreasury(), governanceTreasury);
        lending.grantRole(lending.TREASURY_MANAGER_ROLE(), admin);
        lending.revokeRole(lending.TREASURY_MANAGER_ROLE(), admin);
        vm.stopPrank();

        vm.startPrank(admin);
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
        durations[0] = MONTHS_12;
        aprs[0] = 1_070;
        vm.expectRevert("Lending: invalid input");
        lending.setLoanTypes(durations, aprs);
        vm.expectRevert("Lending: cannot be more than max");
        durations = new uint256[](1);
        durations[0] = MONTHS_12;
        aprs[0] = 2_001;
        lending.setLoanTypes(durations, aprs);

        vm.expectRevert("Lending: cannot be 0");
        aprs[0] = 0;
        lending.setLoanTypes(durations, aprs);

        aprs[0] = 2_000;
        lending.setLoanTypes(durations, aprs);
        assertEq(lending.aprFromDuration(durations[0]), 2_000);
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
        newRanges[0] = 1_000;
        newRanges[1] = 1_000;
        newRanges[2] = 3_000;
        lending.setRanges(newRanges);
        newRanges[1] = 2_000;
        lending.setRanges(newRanges);
        assertEq(lending.originationFeeRanges(0), 1_000);
        assertEq(lending.originationFeeRanges(1), 2_000);
        assertEq(lending.originationFeeRanges(2), 3_000);

        vm.expectRevert("Lending: cannot be more than max length");
        uint256[] memory wrongRanges = new uint256[](7);
        wrongRanges[0] = 1_000;
        wrongRanges[1] = 2_000;
        wrongRanges[2] = 3_000;
        wrongRanges[3] = 4_000;
        wrongRanges[4] = 5_000;
        wrongRanges[5] = 6_000;
        wrongRanges[6] = 7_000;
        lending.setRanges(wrongRanges);

        vm.expectRevert("Lending: cannot be more than max");
        lending.setBaseOriginationFee(301);
        lending.setBaseOriginationFee(300);
        assertEq(lending.baseOriginationFee(), 300);

        nft.mint(borrower, 3, "");
        assertEq(nft.ownerOf(3), address(borrower));

        priceIndex.setValuation(address(nft), 1, 2_000_000, 100);
        (, uint256 price, uint256 ltv) = priceIndex.valuations(address(nft), 1);
        assertEq(price, 2_000_000);
        assertEq(ltv, 100);

        vm.stopPrank();
    }

    function liquidate(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert("Lending: invalid loan id");
        lending.liquidateLoan(0);
        vm.expectRevert("Lending: too early");
        lending.liquidateLoan(1);
        vm.warp(MONTHS_12 + lending.repayGracePeriod() + 1);
        vm.expectRevert("Lending: too early");
        lending.liquidateLoan(1);
        vm.warp(MONTHS_12 + lending.repayGracePeriod() + lending.lenderExclusiveLiquidationPeriod() + 1);
        lending.liquidateLoan(1);
        vm.expectRevert("Lending: loan already paid");
        lending.liquidateLoan(1);
        vm.stopPrank();

        // interests + protocol fee = borrowAmount * (interestRate + protocol fee) * repaymentDuration / (360 days * 100)
        // interests + protocol fee = 100_000 * 11.2 * 31_104_000 / (31_104_000 * 100) = 11_200
        // penalty + fee = [(loanDuration - repaymentDuration) / loanDuration] * (interests + protocol fee)
        // penalty + fee = 0 / 31_104_000 * 11_200 = 0
        // origination fee = borrowAmount * origination fee = 100_000 * ((0 * (5/7)) * 5/7) = 0
        // interests = borrowAmount * interestRate * repaymentDuration / (360 days * 100)
        // interests = 100_000 * 9.7 * 31_104_000 / (31_104_000 * 100) = 9_700
        // penalty = [(loanDuration - repaymentDuration) / loanDuration] * interests
        // penalty = 0 / 31_104_000 * 9_700 = 0
        // liquidation fee = borrowAmount * liquidation fee % / 100  = 100_000 * 5 / 100 = 5_000
        assertEq(token.balanceOf(borrower) / DECIMALS, 1_100_000); // initalBalance + borrowAmount = 1_000_000 + 100_000
        assertEq(token.balanceOf(lender) / DECIMALS, 1_009_700); // initalBalance + interests + penalty = 1_000_000 + 9_700 + 0
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 6_500); // protocol fee + origination fee + liquidation fee = 11_200 - 9_700 + 5000 = 6_500
        assertEq(token.balanceOf(liquidator) / DECIMALS, 883_800); // initialBalance - (borrowAmount + interests + protocol fee + origination fee + liquidation fee) = 1_000_000 - (100_000 + 11_200 + 0 + 5000) = 883_800
        assertEq(nft.ownerOf(1), address(liquidator));
    }

    function claimNFT(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
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
        vm.warp(MONTHS_12 + lending.repayGracePeriod() + 1);

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

    function cancelLoan(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
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

    function loanDeadline(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.warp(MONTHS_12 + 1);

        vm.startPrank(lender);
        vm.expectRevert("Lending: loan acceptance deadline passed");
        lending.acceptLoan(1);
        vm.stopPrank();
    }

    function repayLoan(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
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

        vm.warp(MONTHS_12 + lending.repayGracePeriod() + 1);
        vm.expectRevert("Lending: too late");
        lending.repayLoan(2);
        vm.stopPrank();
    }

    function lendingTestWithParamUpdate(IERC20 token) public {
        uint256 borrowAmount = 100_000 * DECIMALS;

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 1, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(lender);
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(MONTHS_1);

        vm.startPrank(admin);
        lending.setBaseOriginationFee(100);
        vm.stopPrank();

        vm.startPrank(borrower);
        lending.requestLoan(address(token), borrowAmount, address(nft), 2, MONTHS_12, MONTHS_12);
        vm.stopPrank();

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        // interests + protocol fee = borrowAmount * (interestRate + protocol fee) * repaymentDuration / (360 days * 100)
        // interests + protocol fee = 100_000 * 11.2 * 2_592_000 / (31_104_000 * 100) = 933.33
        // penalty + fee = [(loanDuration - repaymentDuration) / loanDuration] * (interests + protocol fee)
        // penalty + fee = (31_104_000 - 2_592_000) / 31_104_000 * 933.33 = 855.55
        // origination fee = borrowAmount * origination fee = 100_000 * ((1 * (5/7)) * 5/7) = 510.20
        // interests = borrowAmount * interestRate * repaymentDuration / (360 days * 100)
        // interests = 100_000 * 9.7 * 2_592_000 / (31_104_000 * 100) = 808.33
        // penalty = [(loanDuration - repaymentDuration) / loanDuration] * interests
        // penalty = (31_104_000 - 2_592_000) / 31_104_000 * 808.33 = 740.96
        assertEq(token.balanceOf(borrower) / DECIMALS, 997_700); // initialBalance - (interest + protocol fee + origination fee + penalty) = 1_000_000 - [933.33 + 510.20 + 855.55] = 997_700.92
        assertEq(token.balanceOf(lender) / DECIMALS, 1_001_549); // intialBalance + interests + penalty = 1_000_000 + 808.33 + 740.96 ~ 1_001_549
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 749); // protocol fee + origination fee = [(933.33-808.33) + (855.55-740.96) + 510.20] = 749.79
        assertEq(nft.ownerOf(1), address(borrower));

        // Reset balance
        vm.startPrank(lender);
        token.transfer(borrower, token.balanceOf(lender) - 1_000_000 * DECIMALS);
        vm.stopPrank();

        vm.startPrank(governanceTreasury);
        token.transfer(borrower, token.balanceOf(governanceTreasury));
        vm.stopPrank();

        assertEq(token.balanceOf(borrower) / DECIMALS, 1_000_000);
        assertEq(token.balanceOf(lender) / DECIMALS, 1_000_000);
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 0);
        

        vm.startPrank(lender);
        lending.acceptLoan(2);
        vm.stopPrank();

        vm.warp(2 * MONTHS_1);

        vm.startPrank(borrower);
        lending.repayLoan(2);
        vm.stopPrank();

        // interests + protocol fee = borrowAmount * (interestRate + protocol fee) * repaymentDuration / (360 days * 100)
        // interests + protocol fee = 100_000 * 11.2 * 2_592_000 / (31_104_000 * 100) = 933.33
        // penalty + fee = [(loanDuration - repaymentDuration) / loanDuration] * (interests + protocol fee)
        // penalty + fee = (31_104_000 - 2_592_000) / 31_104_000 * 933.33 = 855.55
        // origination fee = borrowAmount * origination fee = 100_000 * ((1 * (5/7)) * 5/7) = 510.20
        // interests = borrowAmount * interestRate * repaymentDuration / (360 days * 100)
        // interests = 100_000 * 9.7 * 2_592_000 / (31_104_000 * 100) = 808.33
        // penalty = [(loanDuration - repaymentDuration) / loanDuration] * interests
        // penalty = (31_104_000 - 2_592_000) / 31_104_000 * 808.33 = 740.96
        assertEq(token.balanceOf(borrower) / DECIMALS, 997_700); // initialBalance - (interest + protocol fee + origination fee + penalty) = 1_000_000 - [933.33 + 510.20 + 855.55] = 997_700.92
        assertEq(token.balanceOf(lender) / DECIMALS, 1_001_549); // intialBalance + interests + penalty = 1_000_000 + 808.33 + 740.96 ~ 1_001_549
        assertEq(token.balanceOf(governanceTreasury) / DECIMALS, 749); // protocol fee + origination fee = [(933.33-808.33) + (855.55-740.96) + 510.20] = 749.79
        assertEq(nft.ownerOf(1), address(borrower));
    }

    function zFuzz_Lending(IERC20 token, uint256 collateralValue, uint256 repaymentDuration) public {
        vm.assume(collateralValue > 1 && collateralValue < INITIAL_TOKENS / DECIMALS);
        vm.assume(repaymentDuration > 0);
        uint256 loanDuration = MONTHS_12;
        vm.assume(repaymentDuration < loanDuration);

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 1, collateralValue, 50);
        vm.stopPrank();

        uint256 maxBorrowAmount = (collateralValue * DECIMALS) / 2;
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);

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
        lending.acceptLoan(1);
        vm.stopPrank();

        vm.warp(repaymentDuration);

        vm.startPrank(borrower);
        lending.repayLoan(1);
        vm.stopPrank();

        uint256 feePlusInterest = lending.getDebtWithPenalty(
            maxBorrowAmount,
            lending.aprFromDuration(loanDuration) + lending.protocolFee(),
            loanDuration,
            block.timestamp
        ) + lending.getOriginationFee(maxBorrowAmount, address(token));
        uint256 interest = lending.getDebtWithPenalty(
            maxBorrowAmount, lending.aprFromDuration(loanDuration), loanDuration, repaymentDuration
        );

        assertEq((borrowerStartBalance - token.balanceOf(borrower)) / DECIMALS, (feePlusInterest) / DECIMALS);
        assertEq((token.balanceOf(lender) - lenderStartBalance) / DECIMALS, interest / DECIMALS);
        assertEq(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / DECIMALS,
            (feePlusInterest - interest) / DECIMALS
        );
    }

    function zFuzz_Liquidate(IERC20 token, uint256 collateralValue) public {
        vm.assume(collateralValue > DECIMALS && collateralValue < type(uint256).max / (DECIMALS * 50));
        uint256 borrowerStartBalance = token.balanceOf(borrower);
        uint256 lenderStartBalance = token.balanceOf(lender);
        uint256 contractStartBalance = token.balanceOf(governanceTreasury);
        uint256 liquidatorStartBalance = token.balanceOf(liquidator);
        uint256 loanDuration = MONTHS_12;

        vm.startPrank(admin);
        priceIndex.setValuation(address(nft), 1, collateralValue, 50);
        vm.stopPrank();
        uint256 maxBorrowAmount = (collateralValue * DECIMALS) / 2;

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

        assertEq((token.balanceOf(borrower) - borrowerStartBalance) / DECIMALS, maxBorrowAmount / DECIMALS);
        assertEq((token.balanceOf(lender) - lenderStartBalance) / DECIMALS, interest / DECIMALS);
        assertEq(
            (token.balanceOf(governanceTreasury) - contractStartBalance) / DECIMALS,
            (feePlusInterest - interest) / DECIMALS
        );
        assertEq(
            (liquidatorStartBalance - token.balanceOf(liquidator)) / DECIMALS,
            (feePlusInterest + maxBorrowAmount) / DECIMALS
        );

        assertEq(nft.ownerOf(1), address(liquidator));
    }
}
