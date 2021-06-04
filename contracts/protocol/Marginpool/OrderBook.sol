// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from "./SafeMath.sol";
import {VersionedInitializable} from "./VersionedInitializable.sol";
import {IMarginPoolAddressesProvider} from "./IMarginPoolAddressesProvider.sol";
import {IUniswapV2Router02} from "./IUniswapV2Router02.sol";
import {IERC20Detailed} from "./IERC20Detailed.sol";

interface IMarginPool {
    struct OrderExecute {
        address maker;
        address reserve;
        address reserveTo;
        uint256 amountIn;
        uint256 amountOut;
        bytes codes;
        uint256 gas;
        uint8 swapType;
        bool isOpenPosition;
    }

    function swapOrderWithAggregation(OrderExecute memory order)
        external
        returns (bool);

    function swapOrderWithUni(
        address user,
        uint256 amountIn,
        uint256 amountOut,
        address[] calldata path,
        bool isOpenPosition
    ) external returns (bool);
}

contract OrderBook is VersionedInitializable {
    using SafeMath for uint256;

    uint256 public constant MARGINPOOL_REVISION = 0x1;
    IMarginPool internal pool;
    IUniswapV2Router02 public uniswaper;
    address public wethAddress;

    // order hash => status
    mapping(bytes32 => OrderStatus) public g_status;

    enum OrderType {
        Limit2open,
        stopProfit2open,
        stopLoss2open,
        Limit2close,
        stopProfit2close,
        stopLoss2close
    }
    enum OrderStatus {Null, Approved, Canceled}

    struct Order {
        OrderType orderType;
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 targetPrice;
        uint256 amountInOffered;
        uint256 amountOutExpected;
        uint256 executorFee; // from extra ETH
        uint256 makeTime;
    }

    event OrderPlaced(
        bytes32 indexed orderHash,
        OrderType orderType,
        address indexed maker,
        address tokenIn,
        address tokenOut,
        uint256 targetPrice,
        uint256 amountInOffered,
        uint256 amountOutExpected,
        uint256 executorFee,
        uint256 makeTime
    );

    event OrderCancelled(bytes32 indexed orderHash);
    event OrderExecuted(bytes32 indexed orderHash, address indexed executor);

    function getRevision() internal pure override returns (uint256) {
        return MARGINPOOL_REVISION;
    }

    function getMarginPool() external view returns (IMarginPool) {
        return pool;
    }

    function initialize(
        IMarginPoolAddressesProvider provider,
        IUniswapV2Router02 _uniswaper,
        address _weth
    ) public initializer {
        pool = IMarginPool(provider.getMarginPool());
        uniswaper = _uniswaper;
        wethAddress = _weth;
    }

    function placeOrder(Order memory order)
        external
        payable
        returns (bytes32 orderId)
    {
        require(order.maker == msg.sender, "maker must be sender");
        require(order.amountInOffered > 0, "Invalid offered amount");
        require(order.amountOutExpected > 0, "Invalid expected amount");
        require(msg.value > 0, "Invalid value");
        require(order.executorFee == msg.value, "Invalid executor fee");
        orderId = registerOrder(order);
    }

    function getOrderStates(bytes32[] memory orderHashes)
        external
        view
        returns (uint8[] memory)
    {
        uint256 numOrders = orderHashes.length;
        uint8[] memory output = new uint8[](numOrders);

        // for each order
        for (uint256 i = 0; i < numOrders; i++) {
            bytes32 orderHash = orderHashes[i];
            output[i] = uint8(g_status[orderHash]);
        }
        return output;
    }

    function cancelOrder(Order memory order) external returns (bool) {
        require(msg.sender == order.maker, "Permission denied");
        bytes32 orderHash = getOrderHash(order);
        require(
            g_status[orderHash] == OrderStatus.Approved,
            "Cannot cancel order"
        );

        g_status[orderHash] = OrderStatus.Canceled;
        msg.sender.transfer(order.executorFee);
        emit OrderCancelled(orderHash);
        return true;
    }

    function executeOrderWithAggregation(
        Order memory order,
        bytes memory codes,
        uint256 gas,
        uint8 swapType
    ) external {
        bytes32 orderHash = getOrderHash(order);

        IMarginPool.OrderExecute memory orderExecute;

        orderExecute.isOpenPosition = _checkStatus(order, orderHash);

        orderExecute.maker = order.maker;
        orderExecute.reserve = order.tokenIn;
        orderExecute.reserveTo = order.tokenOut;
        orderExecute.amountIn = order.amountInOffered;
        orderExecute.amountOut = order.amountOutExpected;
        orderExecute.codes = codes;
        orderExecute.gas = gas;
        orderExecute.swapType = swapType;

        bool result = pool.swapOrderWithAggregation(orderExecute);

        require(result, "Aggregation swap failed");

        g_status[orderHash] = OrderStatus.Canceled;
        msg.sender.transfer(order.executorFee);

        emit OrderExecuted(orderHash, msg.sender);
    }

    function executeOrderWithUni(Order memory order) external {
        bytes32 orderHash = getOrderHash(order);

        bool isOpenPosition = _checkStatus(order, orderHash);
        bool result =
            pool.swapOrderWithUni(
                order.maker,
                order.amountInOffered,
                order.amountOutExpected,
                createPair(order.tokenIn, order.tokenOut),
                isOpenPosition
            );

        require(result, "Uniswap failed");

        g_status[orderHash] = OrderStatus.Canceled;
        msg.sender.transfer(order.executorFee);

        emit OrderExecuted(orderHash, msg.sender);
    }

    function _checkStatus(Order memory order, bytes32 orderHash)
        private
        view
        returns (bool isOpenPosition)
    {
        require(
            g_status[orderHash] == OrderStatus.Approved,
            "Cannot execute order"
        );

        isOpenPosition = false;

        if (order.orderType == OrderType.stopProfit2open) {
            _checkTarget(
                order.tokenIn,
                order.tokenOut,
                order.targetPrice,
                true
            );
            isOpenPosition = true;
        } else if (order.orderType == OrderType.stopProfit2close) {
            _checkTarget(
                order.tokenIn,
                order.tokenOut,
                order.targetPrice,
                true
            );
        } else if (order.orderType == OrderType.stopLoss2open) {
            _checkTarget(
                order.tokenIn,
                order.tokenOut,
                order.targetPrice,
                false
            );
            isOpenPosition = true;
        } else if (order.orderType == OrderType.stopLoss2close) {
            _checkTarget(
                order.tokenIn,
                order.tokenOut,
                order.targetPrice,
                false
            );
        } else if (order.orderType == OrderType.Limit2open) {
            isOpenPosition = true;
        }
    }

    function _checkTarget(
        address _tokenIn,
        address _tokenOut,
        uint256 _targetPrice,
        bool stopProfit
    ) private view {
        address[] memory _addressPair = createPair(_tokenIn, _tokenOut);
        uint256 amountOut =
            uniswaper.getAmountsOut(
                10**uint256(IERC20Detailed(_tokenIn).decimals()),
                _addressPair
            )[_addressPair.length - 1];
        if (stopProfit) {
            require(amountOut >= _targetPrice, "Price less than expectations");
        } else {
            require(amountOut <= _targetPrice, "Price exceed expectations");
        }
    }

    function getOrderHash(Order memory order) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    order.orderType,
                    order.maker,
                    order.tokenIn,
                    order.tokenOut,
                    order.targetPrice,
                    order.amountInOffered,
                    order.amountOutExpected,
                    order.executorFee,
                    order.makeTime
                )
            );
    }

    function registerOrder(Order memory order)
        private
        returns (bytes32 orderHash)
    {
        orderHash = keccak256(
            abi.encode(
                order.orderType,
                order.maker,
                order.tokenIn,
                order.tokenOut,
                order.targetPrice,
                order.amountInOffered,
                order.amountOutExpected,
                order.executorFee,
                block.timestamp
            )
        );

        require(
            g_status[orderHash] == OrderStatus.Null,
            "order has been exist"
        );

        g_status[orderHash] = OrderStatus.Approved;

        emit OrderPlaced(
            orderHash,
            order.orderType,
            order.maker,
            order.tokenIn,
            order.tokenOut,
            order.targetPrice,
            order.amountInOffered,
            order.amountOutExpected,
            order.executorFee,
            block.timestamp
        );
    }

    function createPair(address tokenA, address tokenB)
        internal
        view
        returns (address[] memory)
    {
        if (tokenA != wethAddress && tokenB != wethAddress) {
            address[] memory _addressPair = new address[](3);
            _addressPair[0] = tokenA;
            _addressPair[1] = wethAddress;
            _addressPair[2] = tokenB;
            return _addressPair;
        } else {
            address[] memory _addressPair = new address[](2);
            _addressPair[0] = tokenA;
            _addressPair[1] = tokenB;
            return _addressPair;
        }
    }

    function isTradeable(Order memory order) external view returns (bool) {
        bytes32 orderHash = getOrderHash(order);
        if (g_status[orderHash] != OrderStatus.Approved) {
            return false;
        }

        address[] memory _addressPair =
            createPair(order.tokenIn, order.tokenOut);
        uint256 amountOut =
            uniswaper.getAmountsOut(
                10**uint256(IERC20Detailed(order.tokenIn).decimals()),
                _addressPair
            )[_addressPair.length - 1];
        if (
            (amountOut * order.amountInOffered) /
                10**uint256(IERC20Detailed(order.tokenIn).decimals()) <
            order.amountOutExpected
        ) {
            return false;
        }
        if (
            (order.orderType == OrderType.stopProfit2open ||
                order.orderType == OrderType.stopProfit2close) &&
            amountOut < order.targetPrice
        ) {
            return false;
        }
        if (
            (order.orderType == OrderType.stopLoss2open ||
                order.orderType == OrderType.stopLoss2close) &&
            amountOut > order.targetPrice
        ) {
            return false;
        }
        return true;
    }

    receive() external payable {}
}
