// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// Powered by NeoBase: https://github.com/neobase-one

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {UD60x18, ud, convert, ceil} from "@prb/math/src/UD60x18.sol";
import {IPriceIndex} from "./IPriceIndex.sol";
import {IAllowList} from "./IAllowList.sol";

contract Lending is ReentrancyGuard, IERC721Receiver, AccessControl {
    using SafeERC20 for ERC20;
    using ERC165Checker for address;

    /**
     * @notice ContructorParmas struct to prevent stack too deep error
     */
    struct ConstructorParams {
        address priceIndex;
        address governanceTreasury;
        address allowList;
        uint256 protocolFee;
        uint256 gracePeriod;
        uint256 repayGraceFee;
        uint256[] originationFeeRanges;
        uint256 liquidationFee;
        uint256[] durations;
        uint256[] interestRates;
        uint256 baseOriginationFee;
        uint256 lenderExclusiveLiquidationPeriod;
        uint256 feeReductionFactor;
    }

    /**
     * @notice Loan struct to store loans details
     */
    struct Loan {
        address borrower;
        address token;
        uint256 amount;
        address nftCollection;
        uint256 nftId;
        uint256 duration;
        uint256 interestRate;
        uint256 collateralValue;
        address lender;
        uint256 startTime;
        uint256 deadline;
        bool paid;
        bool cancelled;
    }

    uint256 public constant SECONDS_IN_YEAR = 360 days;
    uint256 public constant MIN_GRACE_PERIOD = 2 days;
    uint256 public constant MAX_GRACE_PERIOD = 15 days;
    uint256 public constant MIN_LENDER_EXCLUSIVE_LIQUIDATION_PERIOD = 1 days;
    uint256 public constant MAX_LENDER_EXCLUSIVE_LIQUIDATION_PERIOD = 5 days;
    uint256 public constant VALUATION_EXPIRY = 150 days;
    uint256 public constant PRECISION = 10000;
    uint256 public constant MAX_PROTOCOL_FEE = 400; // 4%
    uint256 public constant MAX_REPAY_GRACE_FEE = 400; // 4%
    uint256 public constant MAX_BASE_ORIGINATION_FEE = 300; // 3%
    uint256 public constant MAX_LIQUIDATION_FEE = 1500; // 15%
    uint256 public constant MAX_INTEREST_RATE = 2000; // 20%
    uint256 public constant MAX_ORIGINATION_FEE_RANGES_LENGTH = 6;

    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    /**
     * @notice PriceIndex contract for NFT price valuations
     */
    IPriceIndex public priceIndex;

    /**
     * @notice Address of the GovernanceTreasury contract
     */
    address public governanceTreasury;

    /**
     * @notice AllowList contract to manage lending users
     */
    IAllowList public allowList;

    /**
     * @notice Protocol fee rate (in basis points)
     */
    uint256 public protocolFee;

    /**
     * @notice Repayment grace period in seconds
     */
    uint256 public repayGracePeriod;

    /**
     * @notice Fee paid if loan repayment occurs during the grace period
     */
    uint256 public repayGraceFee;

    /**
     * @notice Origination fee ranges array
     */
    uint256[] public originationFeeRanges;

    /**
     * @notice Factor for calculating origination fee for next range
     */
    uint256 public feeReductionFactor;

    /**
     * @notice Fee paid during the liquidation process
     */
    uint256 public liquidationFee;

    /**
     * @notice Base origination fee based on loan amount
     */
    uint256 public baseOriginationFee;

    /**
     * @notice Lender exclusive liquidation period in seconds
     */
    uint256 public lenderExclusiveLiquidationPeriod;

    /**
     * @notice ID for the last created loan
     */
    uint256 public lastLoanId;

    /**
     * @notice Mapping from loan IDs to Loan structures
     */
    mapping(uint256 => Loan) private loans;

    /**
     * @notice Mapping for allowed tokens to be borrowed
     */
    mapping(address => bool) public allowedTokens;

    /**
     * @notice Mapping from loan duration to APR in %
     */
    mapping(uint256 => uint256) public aprFromDuration; // apr in %

    /**
     * @notice Mapping to prevent some NFTs from being used as collateral
     */
    mapping(address => mapping(uint256 => bool)) public disallowedNFTs;

    /**
     * @notice Mapping to store stuck token amount for user for every token
     */
    mapping(address => mapping(address => uint256)) public stuckToken;

    /**
     * @notice Emitted when a loan is created
     * @param loanId The unique identifier of the created loan
     * @param borrower The address of the borrower
     * @param token The address of the token in which the loan is denominated
     * @param amount The amount of tokens borrowed
     * @param nftCollection The address of the NFT collection used as collateral
     * @param nftId The unique identifier of the NFT within the collection
     * @param duration The duration of the loan in seconds
     * @param interestRate The annual interest rate in basis points
     * @param collateralValue The value of the NFT collateral in the token’s smallest units
     * @param deadline The deadline for accepting the loan
     */
    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        address token,
        uint256 amount,
        address indexed nftCollection,
        uint256 nftId,
        uint256 duration,
        uint256 interestRate,
        uint256 collateralValue,
        uint256 deadline
    );

    /**
     * @notice Emitted when a loan is accepted by a lender
     * @param loanId The unique identifier of the accepted loan
     * @param lender The address of the lender
     * @param startTime The timestamp in seconds at which the loan becomes active
     */
    event LoanAccepted(uint256 indexed loanId, address indexed lender, uint256 startTime);

    /**
     * @notice Emitted when a loan is cancelled by the borrower
     * @param loanId The unique identifier of the cancelled loan
     */
    event LoanCancelled(uint256 indexed loanId);

    /**
     * @notice Emitted when a loan repayment is done by the borrower
     * @param loanId The unique identifier of the repaid loan
     * @param totalPaid The total amount paid by the borrower including fees
     * @param fees The fee amount charged on repayment in the token’s smallest units
     */
    event LoanRepayment(uint256 indexed loanId, uint256 totalPaid, uint256 fees);

    /**
     * @notice Emitted when a loan is liquidated
     * @param loanId The unique identifier of the liquidated loan
     * @param liquidator The address of the entity that triggered the liquidation
     * @param totalPaid The total amount that was due at the time of liquidation
     * @param fees The fee amount charged on liquidation in the token’s smallest units
     */
    event LoanLiquidated(uint256 indexed loanId, address indexed liquidator, uint256 totalPaid, uint256 fees);

    /**
     * @notice Emitted when NFT is claimed by lender from an overdue loan
     * @param loanId The unique identifier of the overdue loan
     */
    event NFTClaimed(uint256 indexed loanId);

    /**
     * @notice Emitted when the price index oracle is updated
     * @param newPriceIndex The address of the new price index oracle
     */
    event PriceIndexSet(address indexed newPriceIndex);

    /**
     * @notice Emitted when the allow list is updated
     * @param newAllowList The address of the new allow list
     */
    event AllowListSet(address indexed newAllowList);

    /**
     * @notice Emitted when the governance treasury is updated
     * @param newGovernanceTreasury The address of the new governance treasury contract
     */
    event GovernanceTreasurySet(address indexed newGovernanceTreasury);

    /**
     * @notice Emitted when the repayment grace period is updated
     * @param newRepayGracePeriod The new grace period for repayment, in seconds
     */
    event RepayGracePeriodSet(uint256 newRepayGracePeriod);

    /**
     * @notice Emitted when the repayment grace fee is updated
     * @param newRepayGraceFee The new grace fee for repayment
     */
    event RepayGraceFeeSet(uint256 newRepayGraceFee);

    /**
     * @notice Emitted when the protocol fee is updated
     * @param newProtocolFee The new protocol fee, in basis points
     */
    event ProtocolFeeSet(uint256 newProtocolFee);

    /**
     * @notice Emitted when the liquidation fee is updated
     * @param newLiquidationFee The new liquidation fee
     */
    event LiquidationFeeSet(uint256 newLiquidationFee);

    /**
     * @notice Emitted when the base origination fee is updated
     * @param newBaseOriginationFee The new base origination fee
     */
    event BaseOriginationFeeSet(uint256 newBaseOriginationFee);

    /**
     * @notice Emitted when new tokens are added to allowedTokens
     * @param tokens New allowed tokens
     */
    event TokensSet(address[] tokens);

    /**
     * @notice Emitted when tokens are removed from allowedTokens
     * @param tokens Tokens to be removed from allowedTokens
     */
    event TokensUnset(address[] tokens);

    /**
     * @notice Emitted when new duration-interestRates tuples are added
     * @param durations Array of loan durations
     * @param interestRates Array of loan interest rates for duration
     */
    event LoanTypesSet(uint256[] durations, uint256[] interestRates);

    /**
     * @notice Emitted when duration-interestRates tuples are removed
     * @param durations Array of loan durations
     */
    event LoanTypesUnset(uint256[] durations);

    /**
     * @notice Emitted when originationFeeRanges is updated
     * @param originationFeeRanges The new origination fee ranges
     */
    event OriginationFeeRangesSet(uint256[] originationFeeRanges);

    /**
     * @notice Emitted when feeReductionFactor is updated
     * @param feeReductionFactor The new fee reduction factor
     */
    event FeeReductionFactorSet(uint256 feeReductionFactor);

    /**
     * @notice Emitted when lenderExclusiveLiquidationPeriodSet is updated
     * @param lenderExclusiveLiquidationPeriod The new lender exclusive liquidation period
     */
    event LenderExclusiveLiquidationPeriodSet(uint256 lenderExclusiveLiquidationPeriod);

    /**
     * @notice Emitted when a new NFT is added to disallowedNFTs
     * @param collectionAddress The collection address of the NFT to disallow
     * @param tokenId The token id of the NFT to disallow
     */
    event NFTAllowed(address collectionAddress, uint256 tokenId);

    /**
     * @notice Emitted when a new NFT is removed from disallowNFTs
     * @param collectionAddress The collection address of the NFT to allow
     * @param tokenId The token id of the NFT to allow
     */
    event NFTDisallowed(address collectionAddress, uint256 tokenId);

    /**
     * @notice Modifier to check that a function caller is allowlisted
     */
    modifier onlyAllowListed() {
        require(allowList.isAddressAllowed(msg.sender), "Lending: address not allowed");
        _;
    }

    /**
     * @notice Contract constructor
     * @param _constructorParams The constructor parameters
     */
    constructor(ConstructorParams memory _constructorParams) {
        _setProtocolFee(_constructorParams.protocolFee);
        _setRepayGracePeriod(_constructorParams.gracePeriod);
        _setRepayGraceFee(_constructorParams.repayGraceFee);
        _setGovernanceTreasury(_constructorParams.governanceTreasury);
        _setPriceIndex(_constructorParams.priceIndex);
        _setAllowList(_constructorParams.allowList);
        _setLiquidationFee(_constructorParams.liquidationFee);
        _setLoanTypes(_constructorParams.durations, _constructorParams.interestRates);
        _setBaseOriginationFee(_constructorParams.baseOriginationFee);
        _setRanges(_constructorParams.originationFeeRanges);
        _setFeeReductionFactor(_constructorParams.feeReductionFactor);
        _setLenderExclusiveLiquidationPeriod(_constructorParams.lenderExclusiveLiquidationPeriod);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Allows a user to request a loan using their NFT as collateral
     * @custom:use-case If Alice wants to borrow 500.000 USDT for 7 days using her Altr NFT,
     * she would call this function
     * @dev Ensures token is allowed, duration is valid, and the NFT has a price valuation
     * @dev Only NFTs from approved collections with a price valuation can be used
     * @dev Only allowlisted address can call this function
     * @param _token The address of the token being borrowed
     * @param _amount The amount of tokens to be borrowed
     * @param _nftCollection The address of the NFT collection used as collateral
     * @param _nftId The ID of the NFT being used as collateral
     * @param _duration The duration of the loan
     * @param _deadline The deadline to accept the loan request
     */
    function requestLoan(
        address _token,
        uint256 _amount,
        address _nftCollection,
        uint256 _nftId,
        uint256 _duration,
        uint256 _deadline
    ) external nonReentrant onlyAllowListed {
        require(allowedTokens[_token], "Lending: borrow token not allowed");
        require(aprFromDuration[_duration] != 0, "Lending: invalid duration");
        require(_amount > 0, "Lending: borrow amount must be greater than zero");
        require(_deadline > block.timestamp, "Lending: deadline must be after current timestamp");
        require(
            _nftCollection.supportsInterface(type(IERC721).interfaceId),
            "Lending: collection does not support IERC721 interface"
        );
        require(!disallowedNFTs[_nftCollection][_nftId], "Lending: cannot use this NFT as collateral");

        IPriceIndex.Valuation memory valuation = priceIndex.getValuation(_nftCollection, _nftId);

        require(valuation.timestamp + VALUATION_EXPIRY > block.timestamp, "Lending: valuation expired");
        require(valuation.ltv <= 100, "Lending: ltv greater than max");
        require(
            _amount <= (valuation.price * (10 ** ERC20(_token).decimals()) * valuation.ltv) / 100,
            "Lending: amount greater than max borrow"
        );

        Loan storage loan = loans[++lastLoanId];
        loan.borrower = msg.sender;
        loan.token = _token;
        loan.amount = _amount;
        loan.nftCollection = _nftCollection;
        loan.nftId = _nftId;
        loan.duration = _duration;
        loan.collateralValue = valuation.price;
        loan.interestRate = aprFromDuration[_duration];
        loan.deadline = _deadline;

        emit LoanCreated(
            lastLoanId,
            loan.borrower,
            loan.token,
            loan.amount,
            loan.nftCollection,
            loan.nftId,
            loan.duration,
            loan.interestRate,
            loan.collateralValue,
            loan.deadline
        );
    }

    /**
     * @notice Allows the borrower to cancel their loan request if it hasn't been accepted yet
     * @custom:use-case If Alice changes her mind and doesn't want the loan anymore, she can cancel it
     * before a lender accepts it
     * @dev Borrower can cancel a requested load if not yet accepted by any lender
     * @param _loanId The ID of the loan to cancel
     */
    function cancelLoan(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];

        require(loan.borrower == msg.sender, "Lending: invalid loan id");
        require(loan.lender == address(0), "Lending: loan already accepted");
        require(!loan.cancelled, "Lending: loan already cancelled");

        loan.cancelled = true;

        emit LoanCancelled(_loanId);
    }

    /**
     * @notice Allows a lender to accept an existing loan request
     * @custom:use-case If Bob wants to lend 500.000 USDT to Alice for 7 days, he would accept her
     * loan request by calling this function
     * @dev Transfers the borrowed tokens from the lender to the borrower and sets the loan start time
     * @dev Only allowlisted address can call this function
     * @param _loanId The ID of the loan to accept
     */
    function acceptLoan(uint256 _loanId) external nonReentrant onlyAllowListed {
        Loan storage loan = loans[_loanId];

        require(loan.borrower != address(0) && loan.lender == address(0), "Lending: invalid loan id");
        require(!loan.cancelled, "Lending: loan cancelled");
        require(loan.deadline > block.timestamp, "Lending: loan acceptance deadline passed");
        require(allowedTokens[loan.token], "Lending: borrow token not allowed");
        require(!disallowedNFTs[loan.nftCollection][loan.nftId], "Lending: cannot use this NFT as collateral");

        IPriceIndex.Valuation memory valuation = priceIndex.getValuation(loan.nftCollection, loan.nftId);
        require(
            (valuation.price * (10 ** ERC20(loan.token).decimals()) * valuation.ltv) / 100 >= loan.amount,
            "Lending: loan undercollateralized"
        );

        loan.lender = msg.sender;
        loan.startTime = block.timestamp;

        ERC20(loan.token).safeTransferFrom(msg.sender, loan.borrower, loan.amount);
        IERC721(loan.nftCollection).safeTransferFrom(loan.borrower, address(this), loan.nftId);

        emit LoanAccepted(_loanId, loan.lender, loan.startTime);
    }

    /**
     * @notice Allows a borrower to repay the loan and reclaim their NFT
     * @custom:use-case After 7 days, Alice can repay her 500.000 USDT loan along with the accrued interest
     * and fees to get her NFT back
     * @dev Transfers the repayment amount and additional fees to the lender and contract respectively
     * @dev Only allowlisted address can call this function
     * @param _loanId The ID of the loan being repaid
     */
    function repayLoan(uint256 _loanId) external nonReentrant onlyAllowListed {
        Loan storage loan = loans[_loanId];

        require(loan.borrower != address(0) && loan.lender != address(0), "Lending: invalid loan id");
        require(!loan.paid, "Lending: loan already paid");
        require(block.timestamp < loan.startTime + loan.duration + repayGracePeriod, "Lending: too late");

        uint256 totalPayable = loan.amount
            + getDebtWithPenalty(
                loan.amount, loan.interestRate + protocolFee, loan.duration, block.timestamp - loan.startTime
            ) + getOriginationFee(loan.amount, loan.token);
        uint256 lenderPayable = loan.amount
            + getDebtWithPenalty(loan.amount, loan.interestRate, loan.duration, block.timestamp - loan.startTime);
        uint256 platformFee = totalPayable - lenderPayable;

        loan.paid = true;

        try this.attemptTransfer(loan.token, msg.sender, loan.lender, lenderPayable) {}
        catch {
            uint256 balanceBefore = ERC20(loan.token).balanceOf(address(this));
            ERC20(loan.token).safeTransferFrom(msg.sender, address(this), lenderPayable);
            uint256 balanceAfter = ERC20(loan.token).balanceOf(address(this));
            stuckToken[loan.token][loan.lender] += balanceAfter - balanceBefore;
        }

        if (block.timestamp > loan.startTime + loan.duration) {
            platformFee += (lenderPayable * repayGraceFee) / PRECISION;
        }

        if (platformFee > 0) {
            ERC20(loan.token).safeTransferFrom(msg.sender, governanceTreasury, platformFee);
        }

        IERC721(loan.nftCollection).safeTransferFrom(address(this), loan.borrower, loan.nftId);

        emit LoanRepayment(_loanId, lenderPayable + platformFee, platformFee);
    }

    /**
     * @notice Allows a lender to claim NFT from an overdue loan
     * @custom:use-case If Alice fails to repay her loan, Bob can claim her NFT as collateral
     * @dev Transfers the collateralized NFT to the lender
     * @param _loanId The ID of the loan being liquidated
     */
    function claimNFT(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];

        require(loan.borrower != address(0) && loan.lender != address(0), "Lending: invalid loan id");
        require(block.timestamp >= loan.startTime + loan.duration + repayGracePeriod, "Lending: too early");
        require(!loan.paid, "Lending: loan already paid");
        require(msg.sender == loan.lender, "Lending: only the lender can claim the nft");

        loan.paid = true;

        IERC721(loan.nftCollection).safeTransferFrom(address(this), msg.sender, loan.nftId);

        emit NFTClaimed(_loanId);
    }

    /**
     * @notice Allows anyone to liquidate an overdue loan, sending repayment and fees to the lender and claiming the NFT
     * @custom:use-case If Alice defaults and Bob doesn't claim the NFT, Charlie can liquidate the loan,
     * paying Bob and claiming the NFT
     * @dev Transfers the repayment amount and additional fees to the lender and contract respectively
     * @dev Only allowlisted address can call this function
     * @param _loanId The ID of the loan being liquidated
     */
    function liquidateLoan(uint256 _loanId) external nonReentrant onlyAllowListed {
        Loan storage loan = loans[_loanId];

        require(loan.borrower != address(0) && loan.lender != address(0), "Lending: invalid loan id");
        require(
            block.timestamp >= loan.startTime + loan.duration + repayGracePeriod + lenderExclusiveLiquidationPeriod,
            "Lending: too early"
        );
        require(!loan.paid, "Lending: loan already paid");

        uint256 totalPayable = loan.amount
            + getDebtWithPenalty(
                loan.amount, loan.interestRate + protocolFee, loan.duration, block.timestamp - loan.startTime
            ) + getOriginationFee(loan.amount, loan.token) + getLiquidationFee(loan.amount);
        uint256 lenderPayable = loan.amount
            + getDebtWithPenalty(loan.amount, loan.interestRate, loan.duration, block.timestamp - loan.startTime);
        uint256 platformFee = totalPayable - lenderPayable;

        loan.paid = true;
        ERC20(loan.token).safeTransferFrom(msg.sender, loan.lender, lenderPayable);

        if (platformFee > 0) {
            ERC20(loan.token).safeTransferFrom(msg.sender, governanceTreasury, platformFee);
        }

        IERC721(loan.nftCollection).safeTransferFrom(address(this), msg.sender, loan.nftId);

        emit LoanLiquidated(_loanId, msg.sender, totalPayable, totalPayable - lenderPayable);
    }

    /**
     * @notice Allows a lender to withdraw their stuck tokens if something fails during repayment
     * @custom:use-case If Alice repay her loan but for some reason the token transfer to Bob fails,
     * the contract transfer those tokens on the contract itself and than Bob can try to solve the
     * problem and withdraw the tokens when fixed using this function
     * @param token The address of the tokens that are stucked into the contract
     */
    function withdrawStuckToken(address token) external {
        uint256 stuckTokenAmount = stuckToken[token][msg.sender];
        require(stuckTokenAmount > 0, "Lending: you have no stuck tokens");

        delete stuckToken[token][msg.sender];

        ERC20(token).approve(msg.sender, stuckTokenAmount);
    }

    /**
     * @notice Wrapper function to enable the try/catch constructor for the safeTransferFrom function
     * @dev Only the contract itself can call this function
     * @param token The token to attempt transfer
     * @param origin The address to transfer the token from
     * @param beneficiary The address to transfer the token to
     * @param amount The amount of token to transfer
     */
    function attemptTransfer(address token, address origin, address beneficiary, uint256 amount) external {
        require(msg.sender == address(this), "Lending: only the contract itself can call this function");
        ERC20(token).safeTransferFrom(origin, beneficiary, amount);
    }

    /**
     * @notice Updates the address of the price index contract used for valuations
     * @dev Only the admin can call this function
     * @param _priceIndex The address of the new price index contract
     */
    function setPriceIndex(address _priceIndex) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPriceIndex(_priceIndex);

        emit PriceIndexSet(_priceIndex);
    }

    /**
     * @notice Updates the address of the allow list contract
     * @dev Only the admin can call this function
     * @param _allowList The address of the new allow list contract
     */
    function setAllowList(address _allowList) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAllowList(_allowList);

        emit AllowListSet(_allowList);
    }

    /**
     * @notice Updates the address of the governance treasury contract
     * @dev Only the treasury manager can call this function
     * @param _governanceTreasury The address of the new governance treasury contract
     */
    function setGovernanceTreasury(address _governanceTreasury) external onlyRole(TREASURY_MANAGER_ROLE) {
        _setGovernanceTreasury(_governanceTreasury);

        emit GovernanceTreasurySet(_governanceTreasury);
    }

    /**
     * @notice Sets the grace period for loan repayment
     * @dev Only the admin can call this function
     * @param _gracePeriod The new grace period for repayment
     */
    function setRepayGracePeriod(uint256 _gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRepayGracePeriod(_gracePeriod);

        emit RepayGracePeriodSet(_gracePeriod);
    }

    /**
     * @notice Sets the grace fee for loan repayment
     * @dev Only the admin can call this function
     * @param _repayGraceFee The new grace fee for repayment
     */
    function setRepayGraceFee(uint256 _repayGraceFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRepayGraceFee(_repayGraceFee);

        emit RepayGraceFeeSet(_repayGraceFee);
    }

    /**
     * @notice Sets the protocol fee
     * @dev Only the admin can call this function
     * @param _fee The new protocol fee
     */
    function setProtocolFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setProtocolFee(_fee);

        emit ProtocolFeeSet(_fee);
    }

    /**
     * @notice Sets the liquidation fee
     * @dev Only the admin can call this function
     * @param _fee The new liquidation fee
     */
    function setLiquidationFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLiquidationFee(_fee);

        emit LiquidationFeeSet(_fee);
    }

    /**
     * @notice Sets the base origination fee
     * @dev Only the admin can call this function
     * @param _fee The new base origination fee
     */
    function setBaseOriginationFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBaseOriginationFee(_fee);

        emit BaseOriginationFeeSet(_fee);
    }

    /**
     * @notice Sets the lender exclusive liquidation period
     * @dev Only the admin can call this function
     * @param _lenderExclusiveLiquidationPeriod The new lender exclusive liquidation period
     */
    function setLenderExclusiveLiquidationPeriod(uint256 _lenderExclusiveLiquidationPeriod)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setLenderExclusiveLiquidationPeriod(_lenderExclusiveLiquidationPeriod);

        emit LenderExclusiveLiquidationPeriodSet(_lenderExclusiveLiquidationPeriod);
    }

    /**
     * @notice Allows the contract admin to whitelist tokens that can be borrowed
     * @dev Only the admin can call this function
     * @param _tokens Array of token addresses to be whitelisted
     */
    function setTokens(address[] calldata _tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 tokenLength = _tokens.length;
        for (uint256 i = 0; i < tokenLength;) {
            allowedTokens[_tokens[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit TokensSet(_tokens);
    }

    /**
     * @notice Allows the contract admin to remove tokens from the whitelist
     * @dev Only the admin can call this function
     * @param _tokens Array of token addresses to be removed from the whitelist
     */
    function unsetTokens(address[] calldata _tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 tokenLength = _tokens.length;
        for (uint256 i = 0; i < tokenLength;) {
            allowedTokens[_tokens[i]] = false;
            unchecked {
                ++i;
            }
        }

        emit TokensUnset(_tokens);
    }

    /**
     * @notice Allows the contract admin to prevent an NFT from being used as collateral
     * @dev Only the admin can call this function
     * @param _collectionAddress The collection address of the NFT to disallow
     * @param _tokenId The token id of the NFT to disallow
     */
    function disallowNFT(address _collectionAddress, uint256 _tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        disallowedNFTs[_collectionAddress][_tokenId] = true;

        emit NFTDisallowed(_collectionAddress, _tokenId);
    }

    /**
     * @notice Allows the contract admin to allow again an NFT to be used as collateral
     * @dev Only the admin can call this function
     * @param _collectionAddress The collection address of the NFT to allow
     * @param _tokenId The token id of the NFT to allow
     */
    function allowNFT(address _collectionAddress, uint256 _tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        disallowedNFTs[_collectionAddress][_tokenId] = false;

        emit NFTAllowed(_collectionAddress, _tokenId);
    }

    /**
     * @notice Sets the available loan types by specifying the duration and interest rate
     * @dev Only the admin can call this function. The lengths of _durations and _interestRates arrays must be equal
     * @param _durations Array of loan durations
     * @param _interestRates Array of interest rates corresponding to each duration
     */
    function setLoanTypes(uint256[] calldata _durations, uint256[] calldata _interestRates)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setLoanTypes(_durations, _interestRates);

        emit LoanTypesSet(_durations, _interestRates);
    }

    /**
     * @notice Removes the specified loan types by duration
     * @dev Only the admin can call this function
     * @param _durations Array of loan durations to be removed
     */
    function unsetLoanTypes(uint256[] calldata _durations) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 durationsLength = _durations.length;
        for (uint256 i = 0; i < durationsLength;) {
            delete aprFromDuration[_durations[i]];
            unchecked {
                ++i;
            }
        }

        emit LoanTypesUnset(_durations);
    }

    /**
     * @notice Sets the fee reduction factor
     * @dev Only the admin can call this function
     * @param _factor The new fee reduction factor
     */
    function setFeeReductionFactor(uint256 _factor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeeReductionFactor(_factor);

        emit FeeReductionFactorSet(_factor);
    }

    /**
     * @notice Sets the originationFeeRanges array
     * @dev Only the admin can call this function
     * @param _originationFeeRanges The new originationFeeRanges array
     */
    function setRanges(uint256[] memory _originationFeeRanges) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRanges(_originationFeeRanges);

        emit OriginationFeeRangesSet(_originationFeeRanges);
    }

    /**
     * @notice Retrieves the loan details for a specific loan ID
     * @dev Anyone can call this function
     * @dev This function can return uninitialized loans if called with indices greater than lastLoanId
     * @param _loanId The ID of the loan
     * @return loan The loan structure containing the details of the loan
     */
    function getLoan(uint256 _loanId) external view returns (Loan memory loan) {
        return loans[_loanId];
    }

    /**
     * @notice ERC721 Token Received Hook
     * @dev Needed as a callback to receive ERC721 token through `safeTransferFrom` function
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Calculates the origination fee based on the loan amount
     * @dev This is a utility function for internal use
     * @param _amount The loan amount
     * @return uint256 The origination fee
     */
    function getOriginationFee(uint256 _amount, address _token) public view returns (uint256) {
        UD60x18 originationFee = convert(baseOriginationFee);
        UD60x18 factor = convert(feeReductionFactor);
        UD60x18 precision = convert(PRECISION);

        uint256 originationFeeRangesLength = originationFeeRanges.length;
        for (uint256 i = 0; i < originationFeeRangesLength;) {
            if (_amount < originationFeeRanges[i] * (10 ** ERC20(_token).decimals())) {
                break;
            } else {
                originationFee = originationFee.mul(precision).div(factor);
            }
            unchecked {
                ++i;
            }
        }
        return convert(convert(_amount).mul(originationFee).div(precision));
    }

    /**
     * @notice Calculates the liquidation fee based on the loan amount
     * @dev This is a utility function for internal use
     * @param _borrowedAmount The loan amount
     * @return uint256 The liquidation fee
     */
    function getLiquidationFee(uint256 _borrowedAmount) public view returns (uint256) {
        return (_borrowedAmount * liquidationFee) / PRECISION;
    }

    /**
     * @notice Calculates the debt amount with added penalty based on time and amount borrowed
     * @dev This is a utility function for internal use
     * @param _borrowedAmount The original amount borrowed
     * @param _apr The annual percentage rate
     * @param _loanDuration The duration of the loan
     * @param _repaymentDuration The time taken for repayment
     * @return uint256 The debt amount including penalties
     */
    function getDebtWithPenalty(
        uint256 _borrowedAmount,
        uint256 _apr,
        uint256 _loanDuration,
        uint256 _repaymentDuration
    ) public pure returns (uint256) {
        if (_repaymentDuration > _loanDuration) {
            _repaymentDuration = _loanDuration;
        }
        UD60x18 accruedDebt =
            convert(_borrowedAmount * _apr * _repaymentDuration).div(convert(SECONDS_IN_YEAR * PRECISION));
        UD60x18 penaltyFactor = convert(_loanDuration - _repaymentDuration).div(convert(_loanDuration));

        return convert(accruedDebt.add(accruedDebt.mul(penaltyFactor)));
    }

    /**
     * @notice Sets the price index oracle for the contract
     * @dev It checks that the new price index address is not zero and supports the IPriceIndex interface
     * @param _priceIndex The new price index oracle address
     */
    function _setPriceIndex(address _priceIndex) internal {
        require(_priceIndex != address(0), "Lending: cannot be null address");
        require(
            _priceIndex.supportsInterface(type(IPriceIndex).interfaceId),
            "Lending: does not support IPriceIndex interface"
        );

        priceIndex = IPriceIndex(_priceIndex);
    }

    /**
     * @notice Sets the allow list for the contract
     * @dev It checks that the new allow list address is not zero and supports the IAllowList interface
     * @param _allowList The new allow list address
     */
    function _setAllowList(address _allowList) internal {
        require(_allowList != address(0), "Lending: cannot be null address");
        require(
            _allowList.supportsInterface(type(IAllowList).interfaceId),
            "Lending: does not support IAllowList interface"
        );

        allowList = IAllowList(_allowList);
    }

    /**
     * @notice Sets the governance treasury address for the contract
     * @dev It checks that the new governance treasury address is not zero
     * @param _governanceTreasury The new governance treasury address
     */
    function _setGovernanceTreasury(address _governanceTreasury) internal {
        require(_governanceTreasury != address(0), "Lending: cannot be null address");

        governanceTreasury = _governanceTreasury;
    }

    /**
     * @notice Internal function to set the protocol fee
     * @param _fee The new protocol fee
     */
    function _setProtocolFee(uint256 _fee) internal {
        require(_fee <= MAX_PROTOCOL_FEE, "Lending: cannot be more than max");

        protocolFee = _fee;
    }

    /**
     * @notice Internal function to set the liquidation fee
     * @param _fee The new liquidation fee
     */
    function _setLiquidationFee(uint256 _fee) internal {
        require(_fee <= MAX_LIQUIDATION_FEE, "Lending: cannot be more than max");

        liquidationFee = _fee;
    }

    /**
     * @notice Internal function to set the repay grace period
     * @param _gracePeriod The new repay grace period
     */
    function _setRepayGracePeriod(uint256 _gracePeriod) internal {
        require(_gracePeriod >= MIN_GRACE_PERIOD, "Lending: cannot be less than min grace period");
        require(_gracePeriod < MAX_GRACE_PERIOD, "Lending: cannot be more than max grace period");

        repayGracePeriod = _gracePeriod;
    }

    /**
     * @notice Internal function to set the grace fee to be repaid
     * @param _repayGraceFee The new repay grace fee
     */
    function _setRepayGraceFee(uint256 _repayGraceFee) internal {
        require(_repayGraceFee <= MAX_REPAY_GRACE_FEE, "Lending: cannot be more than max");

        repayGraceFee = _repayGraceFee;
    }

    /**
     * @notice Internal function to set the available loan types by specifying the duration and interest rate
     * @param _durations Array of loan durations
     * @param _interestRates Array of interest rates corresponding to each duration
     */
    function _setLoanTypes(uint256[] memory _durations, uint256[] memory _interestRates) internal {
        uint256 durationsLength = _durations.length;
        require(durationsLength == _interestRates.length, "Lending: invalid input");
        for (uint256 i = 0; i < durationsLength;) {
            require(_interestRates[i] <= MAX_INTEREST_RATE, "Lending: cannot be more than max");
            require(_interestRates[i] > 0, "Lending: cannot be 0");
            aprFromDuration[_durations[i]] = _interestRates[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal function to set the new base origination fee
     * @param _fee The new base origination fee
     */
    function _setBaseOriginationFee(uint256 _fee) internal {
        require(_fee <= MAX_BASE_ORIGINATION_FEE, "Lending: cannot be more than max");

        baseOriginationFee = _fee;
    }

    /**
     * @notice Internal function to set new origination fee ranges array
     * @param _originationFeeRanges The new origination fee ranges array
     */
    function _setRanges(uint256[] memory _originationFeeRanges) internal {
        uint256 originationFeeRangesLength = _originationFeeRanges.length;
        require(originationFeeRangesLength > 0, "Lending: cannot be an empty array");
        require(
            originationFeeRangesLength <= MAX_ORIGINATION_FEE_RANGES_LENGTH, "Lending: cannot be more than max length"
        );
        require(_originationFeeRanges[0] > 0, "Lending: first entry must be greater than 0");
        for (uint256 i = 1; i < originationFeeRangesLength;) {
            require(
                _originationFeeRanges[i - 1] < _originationFeeRanges[i], "Lending: entries must be strictly increasing"
            );
            unchecked {
                ++i;
            }
        }

        originationFeeRanges = _originationFeeRanges;
    }

    /**
     * @notice Internal function to set new fee refuction factor
     * @param _factor The new fee reduction factor
     */
    function _setFeeReductionFactor(uint256 _factor) internal {
        require(_factor >= PRECISION, "Lending: fee reduction factor cannot be less than PRECISION");

        feeReductionFactor = _factor;
    }

    /**
     * @notice Internal function to set new lender exclusive liquidation period
     * @param _lenderExclusiveLiquidationPeriod The new lender exclusive liquidation period
     */
    function _setLenderExclusiveLiquidationPeriod(uint256 _lenderExclusiveLiquidationPeriod) internal {
        require(
            _lenderExclusiveLiquidationPeriod >= MIN_LENDER_EXCLUSIVE_LIQUIDATION_PERIOD,
            "Lending: cannot be less than min exclusive period"
        );
        require(
            _lenderExclusiveLiquidationPeriod < MAX_LENDER_EXCLUSIVE_LIQUIDATION_PERIOD,
            "Lending: cannot be more than max exclusive period"
        );

        lenderExclusiveLiquidationPeriod = _lenderExclusiveLiquidationPeriod;
    }
}
