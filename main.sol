// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title TradeMatch
 * @notice Limit order matching service: place and cancel limit buy/sell orders; matcher fills orders against the book. Settlement in native ETH with configurable fee; treasury and fee vault receive splits. Suited for spot-style limit order books on EVM chains.
 * @dev All role addresses and ledger salt are set at deploy and are immutable. ReentrancyGuard and pause for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract TradeMatch is ReentrancyGuard, Ownable {

    event OrderPlaced(
        bytes32 indexed orderId,
        address indexed maker,
        bool buySide,
        uint256 priceTick,
        uint256 sizeWei,
        uint256 placedAtBlock
    );
    event OrderCancelled(bytes32 indexed orderId, address indexed maker, uint256 atBlock);
    event OrderFilled(
        bytes32 indexed orderId,
        address indexed maker,
        address indexed taker,
        bool buySide,
        uint256 priceTick,
        uint256 sizeWei,
        uint256 makerReceiveWei,
        uint256 takerReceiveWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event OrderPartiallyFilled(
        bytes32 indexed orderId,
        address indexed taker,
        uint256 filledSizeWei,
        uint256 remainingSizeWei,
        uint256 atBlock
    );
    event FeeSwept(address indexed to, uint256 amountWei, uint8 vaultKind, uint256 atBlock);
    event MatchbookPauseToggled(bool paused);
    event MatcherUpdated(address indexed previousMatcher, address indexed newMatcher);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event MinOrderSizeUpdated(uint256 previousWei, uint256 newWei, uint256 atBlock);
    event MaxOrderSizeUpdated(uint256 previousWei, uint256 newWei, uint256 atBlock);
    event OrderExpirySet(bytes32 indexed orderId, uint256 expireAtBlock, uint256 atBlock);
    event KeeperOrderExpired(bytes32 indexed orderId, address indexed maker, uint256 atBlock);
    event BatchOrderCancelled(bytes32[] orderIds, address indexed maker, uint256 atBlock);

    error TMM_ZeroAddress();
    error TMM_ZeroAmount();
    error TMM_MatchbookPaused();
    error TMM_OrderNotFound();
    error TMM_OrderAlreadyFilled();
    error TMM_OrderCancelled();
    error TMM_OrderExpired();
    error TMM_NotMaker();
    error TMM_NotMatcher();
    error TMM_InvalidPriceTick();
    error TMM_InvalidSize();
    error TMM_SizeBelowMin();
    error TMM_SizeAboveMax();
    error TMM_InvalidFeeBps();
    error TMM_TransferFailed();
    error TMM_Reentrancy();
    error TMM_NoMatch();
    error TMM_InsufficientValue();
    error TMM_PriceMismatch();
    error TMM_SideMismatch();
    error TMM_ZeroRemaining();
    error TMM_ExpiryPast();
    error TMM_ArrayLengthMismatch();
    error TMM_BatchTooLarge();
    error TMM_NotKeeper();

    uint256 public constant TMM_BPS_DENOM = 10000;
    uint256 public constant TMM_MAX_FEE_BPS = 500;
    uint256 public constant TMM_MIN_PRICE_TICK = 1;
    uint256 public constant TMM_MAX_ORDERS_PER_MAKER = 256;
    uint256 public constant TMM_LEDGER_SALT = 0x6D3fA8c1E5b0D4e7F2a9C6d1B8e4A0c7D3f6B9e2;
    uint256 public constant TMM_MAX_BATCH_MATCH = 32;
    uint8 public constant TMM_VAULT_TREASURY = 1;
    uint8 public constant TMM_VAULT_FEE = 2;

    address public immutable treasury;
    address public immutable feeVault;
    address public immutable orderBookKeeper;
    uint256 public immutable deployedBlock;
    bytes32 public immutable ledgerDomain;

    address public matcher;
    uint256 public feeBps;
    uint256 public minOrderSizeWei;
    uint256 public maxOrderSizeWei;
    bool public matchbookPaused;
    uint256 public orderSequence;

    struct LimitOrder {
        address maker;
        bool buySide;
        uint256 priceTick;
        uint256 sizeWei;
        uint256 filledWei;
        uint256 placedAtBlock;
        uint256 expireAtBlock;
        bool cancelled;
    }

    mapping(bytes32 => LimitOrder) public orders;
    mapping(address => bytes32[]) public orderIdsByMaker;
    mapping(bytes32 => uint256) public orderIdIndexInMakerList;

    uint256 private _feeAccumulatedTreasury;
    uint256 private _feeAccumulatedFeeVault;

    modifier whenNotPaused() {
        if (matchbookPaused) revert TMM_MatchbookPaused();
        _;
    }

    constructor() {
        treasury = address(0x5B2d8F1a4E9c7A0b3D6f8C1e5A9d2F4b7E0c3a6);
        feeVault = address(0xE1a7C4d0F3b6E9c2A5d8F1b4E7a0C3d6F9e2B5);
        orderBookKeeper = address(0x9C0e3F6a2D5b8E1c4A7d0F3b6E9a2C5d8F1b4e7);
        deployedBlock = block.number;
        ledgerDomain = keccak256(abi.encodePacked("TradeMatch_", block.chainid, block.prevrandao, TMM_LEDGER_SALT));
        matcher = msg.sender;
        feeBps = 25;
        minOrderSizeWei = 0.001 ether;
        maxOrderSizeWei = 1000 ether;
    }

    function setMatchbookPaused(bool paused) external onlyOwner {
        matchbookPaused = paused;
        emit MatchbookPauseToggled(paused);
    }

    function setMatcher(address newMatcher) external onlyOwner {
        if (newMatcher == address(0)) revert TMM_ZeroAddress();
        address prev = matcher;
        matcher = newMatcher;
        emit MatcherUpdated(prev, newMatcher);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > TMM_MAX_FEE_BPS) revert TMM_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    function setMinOrderSizeWei(uint256 newMin) external onlyOwner {
        uint256 prev = minOrderSizeWei;
        minOrderSizeWei = newMin;
        emit MinOrderSizeUpdated(prev, newMin, block.number);
    }

    function setMaxOrderSizeWei(uint256 newMax) external onlyOwner {
        uint256 prev = maxOrderSizeWei;
        maxOrderSizeWei = newMax;
        emit MaxOrderSizeUpdated(prev, newMax, block.number);
    }

    function _orderId(address maker_, bool buySide_, uint256 priceTick_, uint256 sizeWei_, uint256 seq_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(maker_, buySide_, priceTick_, sizeWei_, seq_));
    }

    function placeOrder(bool buySide, uint256 priceTick, uint256 sizeWei) external payable whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (msg.sender == address(0)) revert TMM_ZeroAddress();
        if (priceTick < TMM_MIN_PRICE_TICK) revert TMM_InvalidPriceTick();
        if (sizeWei < minOrderSizeWei) revert TMM_SizeBelowMin();
        if (sizeWei > maxOrderSizeWei) revert TMM_SizeAboveMax();
        bytes32[] storage makerOrders = orderIdsByMaker[msg.sender];
        if (makerOrders.length >= TMM_MAX_ORDERS_PER_MAKER) revert TMM_InvalidSize();

        if (buySide) {
            uint256 cost = (sizeWei * priceTick) / TMM_BPS_DENOM;
            if (msg.value < cost) revert TMM_InsufficientValue();
            if (msg.value > cost) {
                (bool sent,) = msg.sender.call{value: msg.value - cost}("");
                if (!sent) revert TMM_TransferFailed();
            }
        } else {
            if (msg.value < sizeWei) revert TMM_InsufficientValue();
            if (msg.value > sizeWei) {
                (bool sent,) = msg.sender.call{value: msg.value - sizeWei}("");
                if (!sent) revert TMM_TransferFailed();
            }
        }

        orderSequence++;
        orderId = _orderId(msg.sender, buySide, priceTick, sizeWei, orderSequence);
        if (orders[orderId].maker != address(0)) revert TMM_OrderNotFound();

        orders[orderId] = LimitOrder({
            maker: msg.sender,
            buySide: buySide,
            priceTick: priceTick,
            sizeWei: sizeWei,
            filledWei: 0,
            placedAtBlock: block.number,
