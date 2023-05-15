// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract CoinFlipSwap is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address payable;
    using SafeERC20 for IERC20;

    // events
    event CreatedOrder(
        bytes32 id,
        address indexed token0,
        uint256 token0Amount,
        address indexed token1,
        uint256 token1Amount,
        address maker
    );

    event ExecutedOrder(
        bytes32 id,
        address indexed _token0,
        uint256 _token0Amount,
        address indexed _token1,
        uint256 _token1Amount,
        address maker,
        address taker
    );

    event CanceledOrder(
        bytes32 id,
        address indexed _token0,
        uint256 _token0Amount,
        address indexed _token1,
        uint256 _token1Amount,
        address maker
    );

    // errors
    error InvalidInput();
    error InvalidFeeAddress();
    error InsufficientFunds();
    error PermissionDenied();
    error OrderNotFound();
    error IndexOutOfBounds();

    // fees
    address feeTo;
    uint16 public constant makerFeeNumerator = 150;      // maker 1.5%
    uint16 public constant takerFeeNumerator = 80;       // taker 0.8%
    uint16 public constant tokenFeeDenominator = 10000;

    address public constant USDCTokenAddress = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address public constant lionDEXTokenAddress = 0x8eBb85D53e6955e557b7c53acDE1D42fD68561Ec;
    address public constant eslionDEXTokenAddress = 0xFeb9Cc52aB4cb153FF1558F587e444Ac3DC2Ea82;

    // incrementor
    uint256 incrementor = 1;

    // orderbook
    struct Order {
        bytes32 id;
        address token0;
        uint256 token0Amount;
        address token1;
        uint256 token1Amount;
        address maker;
    }
    Order[] orderbook;

    mapping(bytes32 => uint256) id2index;

    constructor(address _feeTo) {
        feeTo = _feeTo;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        if (_feeTo == address(0) || _feeTo == address(this)) {
            revert InvalidFeeAddress();
        }

        feeTo = _feeTo;
    }

    function checkOrderAmount(address _token, uint256 _amount) internal pure {
        if (_token == USDCTokenAddress) {
            // minimum 10 USDT
            if (_amount < 10000000) {
                revert InvalidInput();
            }
        } else if (_token == lionDEXTokenAddress) {
            // minimum 500 lionDEX
            if (_amount < 5 * 1e20) {
                revert InvalidInput();
            }
        } else if (_token == eslionDEXTokenAddress) {
            // minimum 500 esLionDEX
            if (_amount < 5 * 1e20) {
                revert InvalidInput();
            }
        } else {
            revert InvalidInput();
        }
    }

    function createOrder(
        address _token0,
        uint256 _token0Amount,
        address _token1,
        uint256 _token1Amount
    ) external nonReentrant {
        if (_token0 == _token1) {
            revert InvalidInput();
        }

        checkOrderAmount(_token0, _token0Amount);
        if (_token1Amount <= 0) {
            revert InvalidInput();
        }

        IERC20(_token0).safeTransferFrom(
            msg.sender,
            address(this),
            _token0Amount
        );

        bytes32 identifier = keccak256(
            abi.encodePacked(
                incrementor++,
                msg.sender,
                block.timestamp,
                _token0,
                _token1
            )
        );

        Order memory order = Order(
            identifier,
            _token0,
            _token0Amount,
            _token1,
            _token1Amount,
            msg.sender
        );

        orderbook.push(order);
        id2index[identifier] = orderbook.length - 1;

        emit CreatedOrder(
            identifier,
            _token0,
            _token0Amount,
            _token1,
            _token1Amount,
            msg.sender
        );
    }

    function cancelOrder(bytes32 id) external nonReentrant {
        int256 index = findIndex(id);

        if (index < 0) {
            revert OrderNotFound();
        }

        Order memory order = orderbook[uint256(index)];

        if (order.maker != msg.sender) {
            revert PermissionDenied();
        }

        if (IERC20(order.token0).balanceOf(address(this)) < order.token0Amount) {
            revert InsufficientFunds();
        }

        deleteOrder(uint256(index));

        IERC20(order.token0).transfer(order.maker, order.token0Amount);

        emit CanceledOrder(
            order.id,
            order.token0,
            order.token0Amount,
            order.token1,
            order.token1Amount,
            order.maker
        );
    }

    function executeOrder(bytes32 id) external nonReentrant {
        int256 index = findIndex(id);

        require(index >= 0, "Swap V1: Order not found");

        Order memory order = orderbook[uint256(index)];

        if (order.maker == address(0)) {
            revert PermissionDenied();
        }

        if (IERC20(order.token0).balanceOf(address(this)) < order.token0Amount) {
            revert InsufficientFunds();
        }

        deleteOrder(uint256(index));

        uint256 token1Fee = order.token1Amount.mul(makerFeeNumerator).div(tokenFeeDenominator);
        uint256 token1Payout = order.token1Amount.sub(token1Fee);

        IERC20(order.token1).safeTransferFrom(msg.sender, feeTo, token1Fee);
        IERC20(order.token1).safeTransferFrom(
            msg.sender,
            order.maker,
            token1Payout
        );

        uint256 token0Fee = order.token0Amount.mul(takerFeeNumerator).div(tokenFeeDenominator);
        uint256 token0Payout = order.token0Amount.sub(token0Fee);

        IERC20(order.token0).transfer(feeTo, token0Fee);
        IERC20(order.token0).transfer(msg.sender, token0Payout);

        emit ExecutedOrder(
            order.id,
            order.token0,
            order.token0Amount,
            order.token1,
            order.token1Amount,
            order.maker,
            msg.sender
        );
    }

    function getNumberOrders() external view returns (uint256) {
        return orderbook.length;
    }

    function findIndex(bytes32 id) internal view returns (int256) {
        uint256 index = id2index[id];

        if (index == 0) {
            if (keccak256(abi.encodePacked(id)) == keccak256(abi.encodePacked(orderbook[index].id))) {
                return 0;
            }

            return -1;
        }

        return int256(index);
    }

    function deleteOrder(uint256 index) internal {
        if (index >= orderbook.length) {
            revert IndexOutOfBounds();
        }

        bytes32 orderId = orderbook[index].id;
        delete id2index[orderId];
        delete orderbook[index];

        if (orderbook.length == 1) {
            orderbook.pop();
            return;
        }

        orderId = orderbook[orderbook.length - 1].id;
        orderbook[index] = orderbook[orderbook.length - 1];
        id2index[orderId] = index;

        orderbook.pop();
    }

    function getOrder(bytes32 _id) external view returns (Order memory) {
        int256 index = findIndex(_id);

        if (index < 0) {
            revert OrderNotFound();
        }

        Order memory order = orderbook[uint256(index)];

        return order;
    }

    function getOrders(
        uint256 _limit,
        uint256 _offset
    ) external view returns (Order[] memory) {
        uint256 end = _limit + _offset;
        require(
            _limit <= orderbook.length,
            "Limit should be less than or equal to the orderbook current length"
        );
        require(
            _offset < orderbook.length,
            "Offset should be less than the orderbook current length"
        );

        uint256 n = 0;
        Order[] memory listings = new Order[](_limit);
        if (end > orderbook.length) {
            end = orderbook.length;
        }
        for (uint256 i = _offset; i < end; i++) {
            Order memory order = orderbook[i];
            listings[n] = order;
            n++;
        }
        return listings;
    }
}
