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
