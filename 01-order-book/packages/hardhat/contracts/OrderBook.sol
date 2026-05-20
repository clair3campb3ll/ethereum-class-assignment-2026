// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    using SafeERC20 for IERC20;

    /// @notice Distinguishes buy orders (0) from sell orders (1)
    enum OrderType {
        Buy,
        Sell
    }

    /// @notice All data for a single limit order
    struct Order {
        address user; // owner of the order
        OrderType orderType;
        uint256 amount; // total tokenA amount requested
        uint256 price; // tokenB units per 1 tokenA (integer ratio)
        uint256 filled; // tokenA amount already matched
        bool open; // false once fully filled or cancelled
    }

    IERC20 public immutable tokenA; // base token  (PNPToken / PNPT)
    IERC20 public immutable tokenB; // quote token (FNBToken / FNBT)

    mapping(uint256 => Order) private _orders;
    uint256 public nextOrderId;

    /// @notice Emitted when a new order is placed
    /// @param orderId   Unique order identifier
    /// @param user      Address that placed the order
    /// @param orderType 0 = buy, 1 = sell
    /// @param tokenIn   Token the placer deposits into the contract
    /// @param tokenOut  Token the placer expects to receive on match
    /// @param amount    Total tokenA quantity of the order
    /// @param price     tokenB units per tokenA
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        uint8 orderType,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price
    );

    /// @notice Emitted when two orders are successfully matched
    /// @param buyOrderId  ID of the buy order
    /// @param sellOrderId ID of the sell order
    /// @param fillAmount  tokenA quantity exchanged in this match
    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 fillAmount);

    /// @notice Emitted after each match to record the updated fill state of an order
    /// @param orderId   The order that was (partially) filled
    /// @param filled    Cumulative tokenA amount filled so far
    /// @param remaining tokenA amount still open
    event OrderFillUpdated(uint256 indexed orderId, uint256 filled, uint256 remaining);

    /// @notice Emitted when an open order is cancelled by its owner
    /// @param orderId ID of the cancelled order
    /// @param user    Address that triggered the cancellation
    event OrderCanceled(uint256 indexed orderId, address indexed user);

    error InvalidAmount();
    error InvalidPrice();
    /// @notice Thrown when the buy order price is below the sell order price
    error PriceMismatch();
    /// @notice Thrown when a caller tries to cancel an order they do not own
    error UnauthorizedCancellation();

    /// @param _tokenA Address of the base token (PNPToken)
    /// @param _tokenB Address of the quote token (FNBToken)
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    /// @notice Place a buy order: offer to buy `amount` tokenA by paying `amount * price` tokenB
    /// @dev    The full quote (amount * price tokenB) is transferred to this contract immediately
    ///         so that funds are locked until the order is matched or cancelled
    /// @param amount tokenA quantity to buy
    /// @param price  tokenB units per tokenA the buyer is willing to pay
    /// @return orderId Newly assigned order identifier
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Prevent zero-amount orders
        if (amount == 0) revert InvalidAmount();

        // Prevent zero-price orders that would allow free purchase of tokenA
        if (price == 0) revert InvalidPrice();

        orderId = nextOrderId++;
        _orders[orderId] = Order({
            user: msg.sender,
            orderType: OrderType.Buy,
            amount: amount,
            price: price,
            filled: 0,
            open: true
        });

        // Lock the quote tokens from the buyer for the full order size.
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        // tokenIn = tokenB (what the buyer deposits), tokenOut = tokenA (what they receive).
        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Buy), address(tokenB), address(tokenA), amount, price);
    }

    /// @notice Place a sell order: offer to sell `amount` tokenA in exchange for tokenB at `price`
    /// @dev    The full tokenA amount is transferred to this contract immediately so that tokens
    ///         are locked until the order is matched or cancelled
    /// @param amount tokenA quantity to sell
    /// @param price  tokenB units per tokenA the seller expects to receive
    /// @return orderId Newly assigned order identifier
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        // Prevent zero-amount orders
        if (amount == 0) revert InvalidAmount();

        // Prevent zero-price orders that would allow free sale of tokenA
        if (price == 0) revert InvalidPrice();

        orderId = nextOrderId++;
        _orders[orderId] = Order({
            user: msg.sender,
            orderType: OrderType.Sell,
            amount: amount,
            price: price,
            filled: 0,
            open: true
        });

        // Lock the base tokens from the seller for the full order size
        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        // tokenIn = tokenA (what the seller deposits), tokenOut = tokenB (what they receive)
        emit OrderPlaced(orderId, msg.sender, uint8(OrderType.Sell), address(tokenA), address(tokenB), amount, price);
    }

    /// @notice Match a buy order against a sell order and settle the overlapping quantity
    /// @dev    Prices must be compatible: buyOrder.price >= sellOrder.price (buyer is willing
    ///         to pay at least as much as the seller demands). Settlement uses the buy-order
    ///         price so the seller always receives at least their asking rate, any excess quote
    ///         tokens remain in the contract as part of the (now-reduced) buy order.
    ///         Either order, or both, may be fully filled in a single call
    /// @param buyOrderId  ID of an open buy order
    /// @param sellOrderId ID of an open sell order
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = _orders[buyOrderId]; // Load the buy order from storage
        Order storage sellOrder = _orders[sellOrderId]; // Load the sell order from storage

        require(buyOrder.open, "Buy order not open");
        require(sellOrder.open, "Sell order not open");

        // Orders must be compatible in direction
        require(buyOrder.orderType == OrderType.Buy, "Not a buy order");
        require(sellOrder.orderType == OrderType.Sell, "Not a sell order");

        // The buyer's price must meet or exceed the seller's ask
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // Fill only as much as both sides have remaining
        uint256 buyRemaining = buyOrder.amount - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;
        uint256 fillAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        // Update fill totals before any external calls
        buyOrder.filled += fillAmount;
        sellOrder.filled += fillAmount;

        // Close orders that are now fully satisfied
        if (buyOrder.filled == buyOrder.amount) buyOrder.open = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.open = false;

        // Settle tokens: buyer receives tokenA, seller receives tokenB at the buy-order price
        uint256 quoteAmount = fillAmount * buyOrder.price;
        tokenA.safeTransfer(buyOrder.user, fillAmount);
        tokenB.safeTransfer(sellOrder.user, quoteAmount);

        // Emit events to record the match and updated order states
        emit OrderMatched(buyOrderId, sellOrderId, fillAmount);
        emit OrderFillUpdated(buyOrderId, buyOrder.filled, buyOrder.amount - buyOrder.filled);
        emit OrderFillUpdated(sellOrderId, sellOrder.filled, sellOrder.amount - sellOrder.filled);
    }

    /// @notice Cancel an open order and refund any unused locked tokens to the caller
    /// @dev    Only the order's original placer may cancel it. For a partially filled buy order
    ///         the refund covers only the unfilled portion of the locked quote tokens
    /// @param orderId ID of the order to cancel
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];

        // Only the order owner may cancel
        if (order.user != msg.sender) revert UnauthorizedCancellation();
        require(order.open, "Order not open");

        order.open = false;

        uint256 refundQty = order.amount - order.filled;

        if (order.orderType == OrderType.Buy) {
            // Refund the portion of locked tokenB that was never matched
            tokenB.safeTransfer(msg.sender, refundQty * order.price);
        } else {
            // Refund the portion of locked tokenA that was never matched
            tokenA.safeTransfer(msg.sender, refundQty);
        }

        emit OrderCanceled(orderId, msg.sender); // Emit event after state changes and refunds
    }

    /// @notice Returns the unfilled tokenA quantity remaining on an order
    /// @param orderId The order to inspect
    function remaining(uint256 orderId) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return order.amount - order.filled;
    }

    /// @notice Returns true if the order is still open (not fully filled and not cancelled)
    /// @param orderId The order to inspect
    function isOpen(uint256 orderId) external view returns (bool) {
        return _orders[orderId].open;
    }
}
