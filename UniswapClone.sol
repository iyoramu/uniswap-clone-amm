// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UniswapClone is ReentrancyGuard {
    // Token pair structure
    struct Pair {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalSupply;
        mapping(address => uint256) liquidity;
    }

    // Pair related data
    mapping(bytes32 => Pair) private pairs;
    mapping(address => bytes32[]) private userPairs;
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;

    // Events
    event PairCreated(address indexed tokenA, address indexed tokenB, bytes32 pairId);
    event LiquidityAdded(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(bytes32 indexed pairId, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event Swap(bytes32 indexed pairId, address indexed sender, uint256 amountIn, uint256 amountOut, address tokenIn, address tokenOut);

    // Fee structure (0.3% fee like Uniswap)
    uint256 public constant FEE_NUMERATOR = 3;
    uint256 public constant FEE_DENOMINATOR = 1000;

    // Creates a new pair for two ERC20 tokens
    function createPair(address tokenA, address tokenB) external returns (bytes32 pairId) {
        require(tokenA != tokenB, "UniswapClone: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pairId = keccak256(abi.encodePacked(token0, token1));
        
        require(pairs[pairId].tokenA == address(0), "UniswapClone: PAIR_EXISTS");
        
        pairs[pairId].tokenA = token0;
        pairs[pairId].tokenB = token1;
        
        emit PairCreated(token0, token1, pairId);
    }

    // Add liquidity to a pair
    function addLiquidity(
        bytes32 pairId,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "UniswapClone: EXPIRED");
        Pair storage pair = pairs[pairId];
        require(pair.tokenA != address(0), "UniswapClone: PAIR_NOT_FOUND");

        (uint256 reserveA, uint256 reserveB) = (pair.reserveA, pair.reserveB);
        
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "UniswapClone: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "UniswapClone: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        // Transfer tokens
        safeTransferFrom(pair.tokenA, msg.sender, address(this), amountA);
        safeTransferFrom(pair.tokenB, msg.sender, address(this), amountB);

        // Mint liquidity tokens
        if (pair.totalSupply == 0) {
            liquidity = sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = min(
                (amountA * pair.totalSupply) / reserveA,
                (amountB * pair.totalSupply) / reserveB
            );
        }
        
        require(liquidity > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        // Update reserves
        pair.reserveA = reserveA + amountA;
        pair.reserveB = reserveB + amountB;
        pair.liquidity[to] += liquidity;
        
        // Track user pairs if not already tracked
        if (!hasPair(to, pairId)) {
            userPairs[to].push(pairId);
        }

        emit LiquidityAdded(pairId, to, amountA, amountB, liquidity);
    }

    // Remove liquidity from a pair
    function removeLiquidity(
        bytes32 pairId,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "UniswapClone: EXPIRED");
        Pair storage pair = pairs[pairId];
        require(pair.tokenA != address(0), "UniswapClone: PAIR_NOT_FOUND");
        
        uint256 balance = pair.liquidity[msg.sender];
        require(liquidity <= balance, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        
        amountA = (liquidity * pair.reserveA) / pair.totalSupply;
        amountB = (liquidity * pair.reserveB) / pair.totalSupply;
        require(amountA >= amountAMin, "UniswapClone: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "UniswapClone: INSUFFICIENT_B_AMOUNT");
        
        // Burn liquidity tokens
        _burn(msg.sender, liquidity);
        pair.liquidity[msg.sender] -= liquidity;
        
        // Transfer tokens to user
        safeTransfer(pair.tokenA, to, amountA);
        safeTransfer(pair.tokenB, to, amountB);
        
        // Update reserves
        pair.reserveA = pair.reserveA - amountA;
        pair.reserveB = pair.reserveB - amountB;
        
        emit LiquidityRemoved(pairId, msg.sender, amountA, amountB, liquidity);
    }

    // Swap exact tokens for tokens
    function swapExactTokensForTokens(
        bytes32 pairId,
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "UniswapClone: EXPIRED");
        Pair storage pair = pairs[pairId];
        require(pair.tokenA != address(0), "UniswapClone: PAIR_NOT_FOUND");
        
        (address token0, ) = sortTokens(pair.tokenA, pair.tokenB);
        (address input, address output) = tokenIn == token0 ? (token0, pair.tokenB) : (pair.tokenB, token0);
        
        require(tokenIn == input, "UniswapClone: INVALID_INPUT_TOKEN");
        
        uint256 reserveIn = input == pair.tokenA ? pair.reserveA : pair.reserveB;
        uint256 reserveOut = output == pair.tokenA ? pair.reserveA : pair.reserveB;
        
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "UniswapClone: INSUFFICIENT_OUTPUT_AMOUNT");
        
        safeTransferFrom(input, msg.sender, address(this), amountIn);
        
        if (input == pair.tokenA) {
            pair.reserveA = reserveIn + amountIn;
            pair.reserveB = reserveOut - amountOut;
        } else {
            pair.reserveA = reserveOut - amountOut;
            pair.reserveB = reserveIn + amountIn;
        }
        
        safeTransfer(output, to, amountOut);
        
        emit Swap(pairId, msg.sender, amountIn, amountOut, input, output);
    }

    // Get amount out given amount in
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapClone: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_NUMERATOR);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Get amount in given amount out
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapClone: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - FEE_NUMERATOR);
        amountIn = (numerator / denominator) + 1;
    }

    // Get reserves for a pair
    function getReserves(bytes32 pairId) external view returns (uint256 reserveA, uint256 reserveB) {
        Pair storage pair = pairs[pairId];
        return (pair.reserveA, pair.reserveB);
    }

    // Get liquidity for a user in a pair
    function getLiquidity(bytes32 pairId, address user) external view returns (uint256) {
        return pairs[pairId].liquidity[user];
    }

    // Get user's pairs
    function getUserPairs(address user) external view returns (bytes32[] memory) {
        return userPairs[user];
    }

    // Helper functions
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapClone: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "UniswapClone: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function hasPair(address user, bytes32 pairId) internal view returns (bool) {
        bytes32[] storage userPairIds = userPairs[user];
        for (uint256 i = 0; i < userPairIds.length; i++) {
            if (userPairIds[i] == pairId) {
                return true;
            }
        }
        return false;
    }

    // ERC20-like functions for liquidity tokens
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    uint256 private _totalSupply;
    string public constant name = "UniswapClone Liquidity Token";
    string public constant symbol = "UCLT";
    uint8 public constant decimals = 18;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 currentAllowance = allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        uint256 senderBalance = balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        balances[sender] = senderBalance - amount;
        balances[recipient] += amount;
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply += amount;
        balances[account] += amount;
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");
        uint256 accountBalance = balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        balances[account] = accountBalance - amount;
        _totalSupply -= amount;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        allowances[owner][spender] = amount;
    }

    // Safe transfer functions
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapClone: TRANSFER_FAILED");
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapClone: TRANSFER_FROM_FAILED");
    }
}
