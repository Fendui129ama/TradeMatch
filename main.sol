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
            expireAtBlock: 0,
            cancelled: false
        });
        orderIdIndexInMakerList[orderId] = makerOrders.length;
        makerOrders.push(orderId);
        emit OrderPlaced(orderId, msg.sender, buySide, priceTick, sizeWei, block.number);
        return orderId;
    }

    function placeOrderWithExpiry(bool buySide, uint256 priceTick, uint256 sizeWei, uint256 expireAtBlock) external payable whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (expireAtBlock <= block.number) revert TMM_ExpiryPast();
        orderId = placeOrder(buySide, priceTick, sizeWei);
        orders[orderId].expireAtBlock = expireAtBlock;
        emit OrderExpirySet(orderId, expireAtBlock, block.number);
        return orderId;
    }

    function cancelOrder(bytes32 orderId) external whenNotPaused nonReentrant {
        _cancelOrder(orderId, msg.sender, true);
    }

    function _cancelOrder(bytes32 orderId, address requester, bool requireMaker) internal {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) revert TMM_OrderNotFound();
        if (requireMaker && o.maker != requester) revert TMM_NotMaker();
        if (o.cancelled) revert TMM_OrderCancelled();
        if (o.filledWei >= o.sizeWei) revert TMM_OrderAlreadyFilled();
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) revert TMM_OrderExpired();

        o.cancelled = true;
        uint256 remaining = o.sizeWei - o.filledWei;
        if (remaining > 0) {
            uint256 refund = o.buySide ? (remaining * o.priceTick) / TMM_BPS_DENOM : remaining;
            (bool sent,) = o.maker.call{value: refund}("");
            if (!sent) revert TMM_TransferFailed();
        }
        emit OrderCancelled(orderId, o.maker, block.number);
    }

    function batchCancelOrders(bytes32[] calldata orderIds) external whenNotPaused nonReentrant {
        if (orderIds.length > TMM_MAX_BATCH_MATCH) revert TMM_BatchTooLarge();
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrder storage o = orders[orderIds[i]];
            if (o.maker == msg.sender && !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock))
                _cancelOrder(orderIds[i], msg.sender, false);
        }
        emit BatchOrderCancelled(orderIds, msg.sender, block.number);
    }

    function keeperExpireOrder(bytes32 orderId) external nonReentrant {
        if (msg.sender != orderBookKeeper) revert TMM_NotKeeper();
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) revert TMM_OrderNotFound();
        if (o.cancelled || o.filledWei >= o.sizeWei) return;
        if (o.expireAtBlock == 0 || block.number < o.expireAtBlock) revert TMM_OrderExpired();
        o.cancelled = true;
        uint256 remaining = o.sizeWei - o.filledWei;
        if (remaining > 0) {
            uint256 refund = o.buySide ? (remaining * o.priceTick) / TMM_BPS_DENOM : remaining;
            (bool sent,) = o.maker.call{value: refund}("");
            if (!sent) revert TMM_TransferFailed();
        }
        emit KeeperOrderExpired(orderId, o.maker, block.number);
    }

    function matchOrder(
        bytes32 orderId,
        address taker,
        uint256 fillWei
    ) external payable whenNotPaused nonReentrant {
        if (msg.sender != matcher) revert TMM_NotMatcher();
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) revert TMM_OrderNotFound();
        if (o.cancelled || o.filledWei >= o.sizeWei) revert TMM_OrderCancelled();
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) revert TMM_OrderExpired();
        if (fillWei == 0 || o.filledWei + fillWei > o.sizeWei) revert TMM_InvalidSize();

        uint256 notional = (fillWei * o.priceTick) / TMM_BPS_DENOM;
        uint256 feeAmount = (notional * feeBps) / TMM_BPS_DENOM;
        uint256 halfFee = feeAmount / 2;
        _feeAccumulatedTreasury += halfFee;
        _feeAccumulatedFeeVault += (feeAmount - halfFee);

        if (o.buySide) {
            if (msg.value < fillWei) revert TMM_InsufficientValue();
            uint256 makerReceiveBase = fillWei;
            uint256 takerReceiveQuote = notional - feeAmount;
            o.filledWei += fillWei;
            (bool toMaker,) = o.maker.call{value: makerReceiveBase}("");
            if (!toMaker) revert TMM_TransferFailed();
            (bool toTaker,) = taker.call{value: takerReceiveQuote}("");
            if (!toTaker) revert TMM_TransferFailed();
            if (msg.value > fillWei) {
                (bool refund,) = msg.sender.call{value: msg.value - fillWei}("");
                if (!refund) revert TMM_TransferFailed();
            }
        } else {
            if (msg.value < notional) revert TMM_InsufficientValue();
            uint256 makerReceiveQuote = notional - feeAmount;
            uint256 takerReceiveBase = fillWei;
            o.filledWei += fillWei;
            (bool toMaker,) = o.maker.call{value: makerReceiveQuote}("");
            if (!toMaker) revert TMM_TransferFailed();
            (bool toTaker,) = taker.call{value: takerReceiveBase}("");
            if (!toTaker) revert TMM_TransferFailed();
            if (msg.value > notional) {
                (bool refund,) = msg.sender.call{value: msg.value - notional}("");
                if (!refund) revert TMM_TransferFailed();
            }
        }

        emit OrderFilled(orderId, o.maker, taker, o.buySide, o.priceTick, fillWei, o.buySide ? fillWei : notional - feeAmount, o.buySide ? notional - feeAmount : fillWei, feeAmount, block.number);
        emit OrderPartiallyFilled(orderId, taker, fillWei, o.sizeWei - o.filledWei, block.number);
    }

    function matchOrderSimple(bytes32 orderId, address taker) external payable whenNotPaused nonReentrant {
        LimitOrder storage o = orders[orderId];
        uint256 remaining = o.sizeWei - o.filledWei;
        if (remaining == 0) revert TMM_ZeroRemaining();
        matchOrder(orderId, taker, remaining);
    }

    function sweepTreasuryFees() external nonReentrant {
        if (msg.sender != treasury) revert TMM_NotMaker();
        uint256 amount = _feeAccumulatedTreasury;
        if (amount == 0) revert TMM_ZeroAmount();
        _feeAccumulatedTreasury = 0;
        (bool sent,) = treasury.call{value: amount}("");
        if (!sent) revert TMM_TransferFailed();
        emit FeeSwept(treasury, amount, TMM_VAULT_TREASURY, block.number);
    }

    function sweepFeeVaultFees() external nonReentrant {
        if (msg.sender != feeVault) revert TMM_NotMaker();
        uint256 amount = _feeAccumulatedFeeVault;
        if (amount == 0) revert TMM_ZeroAmount();
