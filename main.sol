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
        _feeAccumulatedFeeVault = 0;
        (bool sent,) = feeVault.call{value: amount}("");
        if (!sent) revert TMM_TransferFailed();
        emit FeeSwept(feeVault, amount, TMM_VAULT_FEE, block.number);
    }

    function getOrder(bytes32 orderId) external view returns (
        address maker,
        bool buySide,
        uint256 priceTick,
        uint256 sizeWei,
        uint256 filledWei,
        uint256 placedAtBlock,
        uint256 expireAtBlock,
        bool cancelled
    ) {
        LimitOrder storage o = orders[orderId];
        return (o.maker, o.buySide, o.priceTick, o.sizeWei, o.filledWei, o.placedAtBlock, o.expireAtBlock, o.cancelled);
    }

    function getOrderRemaining(bytes32 orderId) external view returns (uint256) {
        LimitOrder storage o = orders[orderId];
        if (o.cancelled || o.filledWei >= o.sizeWei) return 0;
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) return 0;
        return o.sizeWei - o.filledWei;
    }

    function getMakerOrderIds(address maker) external view returns (bytes32[] memory) {
        return orderIdsByMaker[maker];
    }

    function getMakerOrderCount(address maker) external view returns (uint256) {
        return orderIdsByMaker[maker].length;
    }

    function getFeeAccumulatedTreasury() external view returns (uint256) {
        return _feeAccumulatedTreasury;
    }

    function getFeeAccumulatedFeeVault() external view returns (uint256) {
        return _feeAccumulatedFeeVault;
    }

    function getConfig() external view returns (
        address treasury_,
        address feeVault_,
        address orderBookKeeper_,
        address matcher_,
        uint256 feeBps_,
        uint256 minOrderSizeWei_,
        uint256 maxOrderSizeWei_,
        uint256 deployedBlock_,
        bool matchbookPaused_
    ) {
        return (treasury, feeVault, orderBookKeeper, matcher, feeBps, minOrderSizeWei, maxOrderSizeWei, deployedBlock, matchbookPaused);
    }

    function isOrderActive(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0) || o.cancelled || o.filledWei >= o.sizeWei) return false;
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) return false;
        return true;
    }

    function computeOrderId(address maker_, bool buySide_, uint256 priceTick_, uint256 sizeWei_, uint256 seq_) external pure returns (bytes32) {
        return _orderId(maker_, buySide_, priceTick_, sizeWei_, seq_);
    }

    function nextOrderSequence() external view returns (uint256) {
        return orderSequence + 1;
    }

    function getLedgerDomain() external view returns (bytes32) {
        return ledgerDomain;
    }

    struct OrderView {
        bytes32 orderId;
        address maker;
        bool buySide;
        uint256 priceTick;
        uint256 sizeWei;
        uint256 filledWei;
        uint256 remainingWei;
        uint256 placedAtBlock;
        uint256 expireAtBlock;
        bool cancelled;
        bool active;
    }

    function getOrderView(bytes32 orderId) external view returns (OrderView memory v) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) return v;
        v.orderId = orderId;
        v.maker = o.maker;
        v.buySide = o.buySide;
        v.priceTick = o.priceTick;
        v.sizeWei = o.sizeWei;
        v.filledWei = o.filledWei;
        v.remainingWei = o.sizeWei > o.filledWei ? o.sizeWei - o.filledWei : 0;
        v.placedAtBlock = o.placedAtBlock;
        v.expireAtBlock = o.expireAtBlock;
        v.cancelled = o.cancelled;
        v.active = !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock);
    }

    function getNotionalForFill(uint256 sizeWei, uint256 priceTick) external pure returns (uint256) {
        return (sizeWei * priceTick) / TMM_BPS_DENOM;
    }

    function getFeeForNotional(uint256 notionalWei) external view returns (uint256) {
        return (notionalWei * feeBps) / TMM_BPS_DENOM;
    }

    function getMakerOrderIdsPaginated(address maker, uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        bytes32[] storage all = orderIdsByMaker[maker];
        uint256 len = all.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 size = end - offset;
        ids = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = all[offset + i];
    }

    function getOrderIdsBatch(bytes32[] calldata orderIds) external view returns (OrderView[] memory out) {
        out = new OrderView[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrder storage o = orders[orderIds[i]];
            if (o.maker == address(0)) continue;
            out[i] = OrderView({
                orderId: orderIds[i],
                maker: o.maker,
                buySide: o.buySide,
                priceTick: o.priceTick,
                sizeWei: o.sizeWei,
                filledWei: o.filledWei,
                remainingWei: o.sizeWei > o.filledWei ? o.sizeWei - o.filledWei : 0,
                placedAtBlock: o.placedAtBlock,
                expireAtBlock: o.expireAtBlock,
                cancelled: o.cancelled,
                active: !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock)
            });
        }
    }

    function getTreasuryAddress() external view returns (address) { return treasury; }
    function getFeeVaultAddress() external view returns (address) { return feeVault; }
    function getOrderBookKeeperAddress() external view returns (address) { return orderBookKeeper; }
    function getMatcherAddress() external view returns (address) { return matcher; }
    function getDeployedBlock() external view returns (uint256) { return deployedBlock; }
    function getBpsDenom() external pure returns (uint256) { return TMM_BPS_DENOM; }
    function getMaxFeeBps() external pure returns (uint256) { return TMM_MAX_FEE_BPS; }
    function getMaxOrdersPerMaker() external pure returns (uint256) { return TMM_MAX_ORDERS_PER_MAKER; }
    function getLedgerSalt() external pure returns (uint256) { return TMM_LEDGER_SALT; }

    function isOrderFilled(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        return o.maker != address(0) && o.filledWei >= o.sizeWei;
    }

    function isOrderExpired(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        return o.expireAtBlock > 0 && block.number >= o.expireAtBlock;
    }

    function getOrderMaker(bytes32 orderId) external view returns (address) {
        return orders[orderId].maker;
    }

    function getOrderBuySide(bytes32 orderId) external view returns (bool) {
        return orders[orderId].buySide;
    }

    function getOrderPriceTick(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].priceTick;
    }

    function getOrderSizeWei(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].sizeWei;
    }

    function getOrderFilledWei(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].filledWei;
    }

    function getOrderPlacedAtBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].placedAtBlock;
    }

    function getOrderExpireAtBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].expireAtBlock;
    }

    function getOrderCancelled(bytes32 orderId) external view returns (bool) {
        return orders[orderId].cancelled;
    }

    function totalOrderSequence() external view returns (uint256) {
        return orderSequence;
    }

    function estimateFillCost(bytes32 orderId, uint256 fillWei) external view returns (uint256 weiRequired) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) return 0;
        if (o.buySide) return fillWei;
        return (fillWei * o.priceTick) / TMM_BPS_DENOM;
    }

    function getConstants() external pure returns (
        uint256 bpsDenom,
        uint256 maxFeeBps,
        uint256 minPriceTick,
        uint256 maxOrdersPerMaker,
        uint256 maxBatchMatch
    ) {
        return (TMM_BPS_DENOM, TMM_MAX_FEE_BPS, TMM_MIN_PRICE_TICK, TMM_MAX_ORDERS_PER_MAKER, TMM_MAX_BATCH_MATCH);
    }

    function getConfigSnapshot() external view returns (
        address treasury_,
        address feeVault_,
        address keeper_,
        address matcher_,
        uint256 feeBps_,
        uint256 minOrderSizeWei_,
        uint256 maxOrderSizeWei_,
        uint256 deployedBlock_,
        bool paused_
    ) {
        return (treasury, feeVault, orderBookKeeper, matcher, feeBps, minOrderSizeWei, maxOrderSizeWei, deployedBlock, matchbookPaused);
    }

    function getActiveOrderIdsForMaker(address maker) external view returns (bytes32[] memory activeIds) {
        bytes32[] storage all = orderIdsByMaker[maker];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            LimitOrder storage o = orders[all[i]];
            if (!o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock)) count++;
        }
        activeIds = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            LimitOrder storage o = orders[all[i]];
            if (!o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock)) activeIds[count++] = all[i];
        }
    }

    function getActiveOrderCountForMaker(address maker) external view returns (uint256) {
        bytes32[] storage all = orderIdsByMaker[maker];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            LimitOrder storage o = orders[all[i]];
            if (!o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock)) count++;
        }
        return count;
    }

    function getOrderRemainingNotional(bytes32 orderId) external view returns (uint256) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0) || o.cancelled || o.filledWei >= o.sizeWei) return 0;
        uint256 remaining = o.sizeWei - o.filledWei;
        return (remaining * o.priceTick) / TMM_BPS_DENOM;
    }

    function canCancelOrder(bytes32 orderId, address requester) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0) || o.cancelled || o.filledWei >= o.sizeWei) return false;
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) return false;
        return o.maker == requester;
    }

    function canKeeperExpire(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        return o.maker != address(0) && !o.cancelled && o.filledWei < o.sizeWei && o.expireAtBlock > 0 && block.number >= o.expireAtBlock;
    }

    function getFillDetails(bytes32 orderId, uint256 fillWei) external view returns (
        uint256 notionalWei,
        uint256 feeWei,
        uint256 makerReceiveWei,
        uint256 takerReceiveWei,
        uint256 takerMustSendWei
    ) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) return (0, 0, 0, 0, 0);
        notionalWei = (fillWei * o.priceTick) / TMM_BPS_DENOM;
        feeWei = (notionalWei * feeBps) / TMM_BPS_DENOM;
        if (o.buySide) {
            makerReceiveWei = fillWei;
            takerReceiveWei = notionalWei - feeWei;
            takerMustSendWei = fillWei;
        } else {
            makerReceiveWei = notionalWei - feeWei;
            takerReceiveWei = fillWei;
            takerMustSendWei = notionalWei;
        }
    }

    function getOrderSummary(bytes32 orderId) external view returns (
        address maker,
        bool buySide,
        uint256 sizeWei,
        uint256 filledWei,
        uint256 remainingWei,
        uint256 priceTick,
        bool active
    ) {
        LimitOrder storage o = orders[orderId];
        uint256 rem = o.sizeWei > o.filledWei ? o.sizeWei - o.filledWei : 0;
        bool act = !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock);
        return (o.maker, o.buySide, o.sizeWei, o.filledWei, rem, o.priceTick, act);
    }

    function getMakerOrdersSummary(address maker) external view returns (
        uint256 totalOrders,
        uint256 activeOrders,
        uint256 totalSizeWei,
        uint256 totalFilledWei
    ) {
        bytes32[] storage all = orderIdsByMaker[maker];
        totalOrders = all.length;
        for (uint256 i = 0; i < all.length; i++) {
            LimitOrder storage o = orders[all[i]];
            totalSizeWei += o.sizeWei;
            totalFilledWei += o.filledWei;
            if (!o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock)) activeOrders++;
        }
    }

    function getTotalFeesAccumulated() external view returns (uint256 total) {
        return _feeAccumulatedTreasury + _feeAccumulatedFeeVault;
    }

    function isMatchbookPaused() external view returns (bool) {
        return matchbookPaused;
    }

    function getMinOrderSize() external view returns (uint256) {
        return minOrderSizeWei;
    }

    function getMaxOrderSize() external view returns (uint256) {
        return maxOrderSizeWei;
    }

    function getFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function computeNotional(uint256 sizeWei, uint256 priceTick) external pure returns (uint256) {
        return (sizeWei * priceTick) / TMM_BPS_DENOM;
    }

    function computeFeeFromNotional(uint256 notionalWei) external view returns (uint256) {
        return (notionalWei * feeBps) / TMM_BPS_DENOM;
    }

    function validateOrderParams(bool buySide, uint256 priceTick, uint256 sizeWei) external view returns (bool valid, uint8 reason) {
        if (priceTick < TMM_MIN_PRICE_TICK) return (false, 1);
        if (sizeWei < minOrderSizeWei) return (false, 2);
        if (sizeWei > maxOrderSizeWei) return (false, 3);
        return (true, 0);
    }

    function getOrderIdAtIndex(address maker, uint256 index) external view returns (bytes32) {
        return orderIdsByMaker[maker][index];
    }

    function getOrderIndexInMakerList(bytes32 orderId) external view returns (uint256) {
        return orderIdIndexInMakerList[orderId];
    }

    function hasOrder(bytes32 orderId) external view returns (bool) {
        return orders[orderId].maker != address(0);
    }

    function getOrderPlacedBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].placedAtBlock;
    }

    function getOrderExpiryBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].expireAtBlock;
    }

    function getOrderIsCancelled(bytes32 orderId) external view returns (bool) {
        return orders[orderId].cancelled;
    }

    function getOrderFilledAmount(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].filledWei;
    }

    function getOrderSize(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].sizeWei;
    }

    function getOrderPrice(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].priceTick;
    }

    function getOrderIsBuy(bytes32 orderId) external view returns (bool) {
        return orders[orderId].buySide;
    }

    function treasuryPendingFees() external view returns (uint256) {
        return _feeAccumulatedTreasury;
    }

    function feeVaultPendingFees() external view returns (uint256) {
        return _feeAccumulatedFeeVault;
    }

    function ledgerSalt() external pure returns (uint256) {
        return TMM_LEDGER_SALT;
    }

    function minPriceTick() external pure returns (uint256) {
        return TMM_MIN_PRICE_TICK;
    }

    function maxBatchMatch() external pure returns (uint256) {
        return TMM_MAX_BATCH_MATCH;
    }

    function vaultKindTreasury() external pure returns (uint8) {
        return TMM_VAULT_TREASURY;
    }

    function vaultKindFee() external pure returns (uint8) {
        return TMM_VAULT_FEE;
    }

    function getOrderViewCompact(bytes32 orderId) external view returns (
        address maker,
        bool buySide,
        uint256 priceTick,
        uint256 sizeWei,
        uint256 filledWei,
        bool cancelled,
        bool expired,
        bool active
    ) {
        LimitOrder storage o = orders[orderId];
        bool exp = o.expireAtBlock > 0 && block.number >= o.expireAtBlock;
        bool act = !o.cancelled && o.filledWei < o.sizeWei && !exp;
        return (o.maker, o.buySide, o.priceTick, o.sizeWei, o.filledWei, o.cancelled, exp, act);
    }

    function getOrdersViewBatch(bytes32[] calldata orderIds) external view returns (
        address[] memory makers,
        bool[] memory buySides,
        uint256[] memory priceTicks,
        uint256[] memory sizeWeis,
        uint256[] memory filledWeis,
        bool[] memory actives
    ) {
        uint256 n = orderIds.length;
        makers = new address[](n);
        buySides = new bool[](n);
        priceTicks = new uint256[](n);
        sizeWeis = new uint256[](n);
        filledWeis = new uint256[](n);
        actives = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            LimitOrder storage o = orders[orderIds[i]];
            makers[i] = o.maker;
            buySides[i] = o.buySide;
            priceTicks[i] = o.priceTick;
            sizeWeis[i] = o.sizeWei;
            filledWeis[i] = o.filledWei;
            actives[i] = !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock);
        }
    }

    function getRemainingSize(bytes32 orderId) external view returns (uint256) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0) || o.cancelled || o.filledWei >= o.sizeWei) return 0;
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) return 0;
        return o.sizeWei - o.filledWei;
    }

    function getRemainingNotional(bytes32 orderId) external view returns (uint256) {
        uint256 rem = this.getRemainingSize(orderId);
        if (rem == 0) return 0;
        LimitOrder storage o = orders[orderId];
        return (rem * o.priceTick) / TMM_BPS_DENOM;
    }

    function estimateFeeForOrder(bytes32 orderId, uint256 fillWei) external view returns (uint256 feeWei) {
        LimitOrder storage o = orders[orderId];
        uint256 notional = (fillWei * o.priceTick) / TMM_BPS_DENOM;
        return (notional * feeBps) / TMM_BPS_DENOM;
    }

    function getMakerOrderIdsRange(address maker, uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids) {
        bytes32[] storage all = orderIdsByMaker[maker];
        if (fromIndex > toIndex || toIndex >= all.length) return new bytes32[](0);
        uint256 size = toIndex - fromIndex + 1;
        ids = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) ids[i] = all[fromIndex + i];
    }

    function getOrderStatus(bytes32 orderId) external view returns (uint8 status) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0)) return 0;
        if (o.cancelled) return 1;
        if (o.filledWei >= o.sizeWei) return 2;
        if (o.expireAtBlock > 0 && block.number >= o.expireAtBlock) return 3;
        return 4;
    }

    function getOrderInfo(bytes32 orderId) external view returns (
        bytes32 id,
        address makerAddr,
        bool isBuy,
        uint256 price,
        uint256 size,
        uint256 filled,
        uint256 placedBlock,
        uint256 expireBlock,
        bool cancelledFlag
    ) {
        LimitOrder storage o = orders[orderId];
        return (orderId, o.maker, o.buySide, o.priceTick, o.sizeWei, o.filledWei, o.placedAtBlock, o.expireAtBlock, o.cancelled);
    }

    function totalFeesTreasury() external view returns (uint256) {
        return _feeAccumulatedTreasury;
    }

    function totalFeesFeeVault() external view returns (uint256) {
        return _feeAccumulatedFeeVault;
    }

    function configTreasury() external view returns (address) { return treasury; }
    function configFeeVault() external view returns (address) { return feeVault; }
    function configKeeper() external view returns (address) { return orderBookKeeper; }
    function configMatcher() external view returns (address) { return matcher; }
    function configDeployedBlock() external view returns (uint256) { return deployedBlock; }
    function configPaused() external view returns (bool) { return matchbookPaused; }
    function configFeeBps() external view returns (uint256) { return feeBps; }
    function configMinOrderSizeWei() external view returns (uint256) { return minOrderSizeWei; }
    function configMaxOrderSizeWei() external view returns (uint256) { return maxOrderSizeWei; }

    function orderExists(bytes32 orderId) external view returns (bool) {
        return orders[orderId].maker != address(0);
    }

    function orderIsFullyFilled(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        return o.maker != address(0) && o.filledWei >= o.sizeWei;
    }

    function orderIsExpired(bytes32 orderId) external view returns (bool) {
        LimitOrder storage o = orders[orderId];
        return o.expireAtBlock > 0 && block.number >= o.expireAtBlock;
    }

    function orderIsCancelled(bytes32 orderId) external view returns (bool) {
        return orders[orderId].cancelled;
    }

    function orderMaker(bytes32 orderId) external view returns (address) {
        return orders[orderId].maker;
    }

    function orderBuySide(bytes32 orderId) external view returns (bool) {
        return orders[orderId].buySide;
    }

    function orderPriceTick(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].priceTick;
    }

    function orderSizeWei(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].sizeWei;
    }

    function orderFilledWei(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].filledWei;
    }

    function orderPlacedAtBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].placedAtBlock;
    }

    function orderExpireAtBlock(bytes32 orderId) external view returns (uint256) {
        return orders[orderId].expireAtBlock;
    }

    function currentSequence() external view returns (uint256) {
        return orderSequence;
    }

    function bpsDenominator() external pure returns (uint256) {
        return TMM_BPS_DENOM;
    }

    function maxFeeBpsConstant() external pure returns (uint256) {
        return TMM_MAX_FEE_BPS;
    }

    function maxOrdersPerMakerConstant() external pure returns (uint256) {
        return TMM_MAX_ORDERS_PER_MAKER;
    }

    function ledgerSaltConstant() external pure returns (uint256) {
        return TMM_LEDGER_SALT;
    }

    function domainBytes32() external view returns (bytes32) {
        return ledgerDomain;
    }

    function computeOrderIdFromParams(
        address makerAddr,
        bool buySideParam,
        uint256 priceTickParam,
        uint256 sizeWeiParam,
        uint256 seqParam
    ) external pure returns (bytes32) {
        return _orderId(makerAddr, buySideParam, priceTickParam, sizeWeiParam, seqParam);
    }

    function requiredValueToPlaceOrder(bool buySideParam, uint256 priceTickParam, uint256 sizeWeiParam) external pure returns (uint256) {
        if (buySideParam) return (sizeWeiParam * priceTickParam) / TMM_BPS_DENOM;
        return sizeWeiParam;
    }

    function requiredValueToMatchOrder(bytes32 orderIdParam, uint256 fillWeiParam) external view returns (uint256) {
        LimitOrder storage o = orders[orderIdParam];
        if (o.maker == address(0)) return 0;
        if (o.buySide) return fillWeiParam;
        return (fillWeiParam * o.priceTick) / TMM_BPS_DENOM;
    }

    function getFeeSplit(uint256 notionalWeiParam) external view returns (uint256 toTreasury, uint256 toFeeVault) {
        uint256 fee = (notionalWeiParam * feeBps) / TMM_BPS_DENOM;
        toTreasury = fee / 2;
        toFeeVault = fee - toTreasury;
    }

    function getOrderRemainingWei(bytes32 orderId) external view returns (uint256) {
        return this.getOrderRemaining(orderId);
    }

    function getFullOrderState(bytes32 orderId) external view returns (
        bytes32 id,
        address makerAddress,
        bool isBuyOrder,
        uint256 priceTickValue,
        uint256 sizeWeiValue,
        uint256 filledWeiValue,
        uint256 remainingWeiValue,
        uint256 placedAtBlockValue,
        uint256 expireAtBlockValue,
        bool isCancelled,
        bool isExpired,
        bool isActive
    ) {
        LimitOrder storage o = orders[orderId];
        uint256 rem = o.sizeWei > o.filledWei ? o.sizeWei - o.filledWei : 0;
        bool exp = o.expireAtBlock > 0 && block.number >= o.expireAtBlock;
        bool act = !o.cancelled && o.filledWei < o.sizeWei && !exp;
        return (
            orderId,
            o.maker,
            o.buySide,
            o.priceTick,
            o.sizeWei,
            o.filledWei,
            rem,
            o.placedAtBlock,
            o.expireAtBlock,
            o.cancelled,
            exp,
            act
        );
    }

    function getMultipleOrdersRemaining(bytes32[] calldata orderIds) external view returns (uint256[] memory remainings) {
        remainings = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrder storage o = orders[orderIds[i]];
            if (o.maker != address(0) && !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock))
                remainings[i] = o.sizeWei - o.filledWei;
        }
    }

    function getMultipleOrdersActive(bytes32[] calldata orderIds) external view returns (bool[] memory actives) {
        actives = new bool[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrder storage o = orders[orderIds[i]];
            actives[i] = !o.cancelled && o.filledWei < o.sizeWei && (o.expireAtBlock == 0 || block.number < o.expireAtBlock);
        }
    }

    function getMultipleOrdersMaker(bytes32[] calldata orderIds) external view returns (address[] memory makers) {
        makers = new address[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) makers[i] = orders[orderIds[i]].maker;
    }

    function getMultipleOrdersPriceTick(bytes32[] calldata orderIds) external view returns (uint256[] memory ticks) {
        ticks = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) ticks[i] = orders[orderIds[i]].priceTick;
    }

    function getMultipleOrdersSizeWei(bytes32[] calldata orderIds) external view returns (uint256[] memory sizes) {
        sizes = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) sizes[i] = orders[orderIds[i]].sizeWei;
    }

    function getMultipleOrdersFilledWei(bytes32[] calldata orderIds) external view returns (uint256[] memory filled) {
        filled = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) filled[i] = orders[orderIds[i]].filledWei;
    }

    function getMultipleOrdersBuySide(bytes32[] calldata orderIds) external view returns (bool[] memory buySides) {
        buySides = new bool[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) buySides[i] = orders[orderIds[i]].buySide;
    }

    function getMultipleOrdersCancelled(bytes32[] calldata orderIds) external view returns (bool[] memory cancelled) {
        cancelled = new bool[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) cancelled[i] = orders[orderIds[i]].cancelled;
    }

    function getMultipleOrdersExpireAtBlock(bytes32[] calldata orderIds) external view returns (uint256[] memory expireBlocks) {
        expireBlocks = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) expireBlocks[i] = orders[orderIds[i]].expireAtBlock;
    }

    function getMultipleOrdersPlacedAtBlock(bytes32[] calldata orderIds) external view returns (uint256[] memory placedBlocks) {
        placedBlocks = new uint256[](orderIds.length);
        for (uint256 i = 0; i < orderIds.length; i++) placedBlocks[i] = orders[orderIds[i]].placedAtBlock;
    }

    function computeRequiredWeiForPlace(bool buySideFlag, uint256 priceTickFlag, uint256 sizeWeiFlag) external pure returns (uint256) {
        if (buySideFlag) return (sizeWeiFlag * priceTickFlag) / TMM_BPS_DENOM;
        return sizeWeiFlag;
    }

    function computeRefundOnCancel(bytes32 orderId) external view returns (uint256 refundWei) {
        LimitOrder storage o = orders[orderId];
        if (o.maker == address(0) || o.cancelled || o.filledWei >= o.sizeWei) return 0;
        uint256 remaining = o.sizeWei - o.filledWei;
        return o.buySide ? (remaining * o.priceTick) / TMM_BPS_DENOM : remaining;
