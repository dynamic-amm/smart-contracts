// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "../libraries/MathExt.sol";
import "../libraries/KSLibrary.sol";
import "../interfaces/IKSPool.sol";
import "../interfaces/IKSFactory.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IERC20Permit.sol";

/// @dev detail here: https://hackmd.io/vdqxJx8STNqPm0LG8vGWaw
contract KSZap {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct ReserveData {
        uint256 rIn;
        uint256 rOut;
        uint256 vIn;
        uint256 vOut;
        uint256 feeInPrecision;
    }

    uint256 private constant PRECISION = 1e18;
    uint256 internal constant Q112 = 2**112;

    address public configMaster;
    mapping(IKSFactory => bool) public whitelistedFactories;
    address public immutable weth;

    event ConfigMasterUpdated(address oldConfigMaster, address newConfigMaster);
    event FactoryAdded(IKSFactory factory);
    event FactoryRemoved(IKSFactory factory);

    modifier onlyConfigMaster() {
        require(msg.sender == configMaster, "KSZap: Forbidden");
        _;
    }

    modifier whitelistedFactory(IKSFactory _factory) {
        require(whitelistedFactories[_factory], "KSZap: Forbidden");
        _;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "KSZap: Expired");
        _;
    }

    constructor(IKSFactory _factory, address _weth) public {
        configMaster = msg.sender;
        emit ConfigMasterUpdated(address(0), msg.sender);

        whitelistedFactories[_factory] = true;
        emit FactoryAdded(_factory);

        weth = _weth;
    }

    receive() external payable {
        assert(msg.sender == weth); // only accept ETH via fallback from the WETH contract
    }

    function updateConfigMaster(address _configMaster) external onlyConfigMaster {
        emit ConfigMasterUpdated(configMaster, _configMaster);
        configMaster = _configMaster;
    }

    function addFactory(IKSFactory _factory) external onlyConfigMaster {
        whitelistedFactories[_factory] = true;
        emit FactoryAdded(_factory);
    }

    function removeFactory(IKSFactory _factory) external onlyConfigMaster {
        whitelistedFactories[_factory] = false;
        emit FactoryRemoved(_factory);
    }

    /// @dev swap eth to token and then add liquidity to a pool with token-weth
    /// @param factory address of the Factory contract
    /// @param tokenOut another token of the pool - not weth
    /// @param pool address of the pool
    /// @param minLpQty min of lp token after swap
    /// @param deadline the last time the transaction can be executed
    function zapInEth(
        IKSFactory factory,
        IERC20 tokenOut,
        address pool,
        address to,
        uint256 minLpQty,
        uint256 deadline
    ) external payable ensure(deadline) whitelistedFactory(factory) returns (uint256 lpQty) {
        IWETH(weth).deposit{value: msg.value}();
        (uint256 amountSwap, uint256 amountOutput) = calculateSwapAmounts(
            factory,
            IERC20(weth),
            tokenOut,
            pool,
            msg.value
        );
        IERC20(weth).safeTransfer(pool, amountSwap);
        _swap(amountOutput, IERC20(weth), tokenOut, pool, address(this));

        IERC20(weth).safeTransfer(pool, msg.value.sub(amountSwap));
        tokenOut.safeTransfer(pool, amountOutput);

        lpQty = IKSPool(pool).mint(to);
        require(lpQty >= minLpQty, "IKSRouter: INSUFFICIENT_MINT_QTY");
    }

    /// @dev swap and add liquidity to a pool with token-weth
    /// @param tokenIn the input token
    /// @param tokenOut another token of the pool
    /// @param pool address of the pool
    /// @param userIn amount of input token
    /// @param minLpQty min of lp token after swap
    /// @param deadline the last time the transaction can be executed
    function zapIn(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 userIn,
        address pool,
        address to,
        uint256 minLpQty,
        uint256 deadline
    ) external ensure(deadline) whitelistedFactory(factory) returns (uint256 lpQty) {
        (uint256 amountSwap, uint256 amountOutput) = calculateSwapAmounts(
            factory,
            tokenIn,
            tokenOut,
            pool,
            userIn
        );

        tokenIn.safeTransferFrom(msg.sender, pool, amountSwap);
        _swap(amountOutput, tokenIn, tokenOut, pool, address(this));
        tokenIn.safeTransferFrom(msg.sender, pool, userIn.sub(amountSwap));
        tokenOut.safeTransfer(pool, amountOutput);

        lpQty = IKSPool(pool).mint(to);
        require(lpQty >= minLpQty, "INSUFFICIENT_MINT_QTY");
    }

    function zapOut(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 liquidity,
        address pool,
        address to,
        uint256 minTokenOut,
        uint256 deadline
    ) external ensure(deadline) whitelistedFactory(factory) returns (uint256 amountOut) {
        amountOut = _zapOut(factory, tokenIn, tokenOut, liquidity, pool, minTokenOut);
        tokenOut.safeTransfer(to, amountOut);
    }

    function zapOutPermit(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 liquidity,
        address pool,
        address to,
        uint256 minTokenOut,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external ensure(deadline) whitelistedFactory(factory) returns (uint256 amountOut) {
        IERC20Permit(pool).permit(
            msg.sender,
            address(this),
            approveMax ? uint256(-1) : liquidity,
            deadline,
            v,
            r,
            s
        );
        amountOut = _zapOut(factory, tokenIn, tokenOut, liquidity, pool, minTokenOut);
        tokenOut.safeTransfer(to, amountOut);
    }

    function zapOutEth(
        IKSFactory factory,
        IERC20 tokenIn,
        uint256 liquidity,
        address pool,
        address to,
        uint256 minTokenOut,
        uint256 deadline
    ) external ensure(deadline) whitelistedFactory(factory) returns (uint256 amountOut) {
        amountOut = _zapOut(factory, tokenIn, IERC20(weth), liquidity, pool, minTokenOut);
        IWETH(weth).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    function zapOutEthPermit(
        IKSFactory factory,
        IERC20 tokenIn,
        uint256 liquidity,
        address pool,
        address to,
        uint256 minTokenOut,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whitelistedFactory(factory) returns (uint256 amountOut) {
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IERC20Permit(pool).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountOut = _zapOut(factory, tokenIn, IERC20(weth), liquidity, pool, minTokenOut);
        IWETH(weth).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    function calculateZapInAmounts(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address pool,
        uint256 userIn
    )
        external
        view
        whitelistedFactory(factory)
        returns (uint256 tokenInAmount, uint256 tokenOutAmount)
    {
        uint256 amountSwap;
        (amountSwap, tokenOutAmount) = calculateSwapAmounts(
            factory,
            tokenIn,
            tokenOut,
            pool,
            userIn
        );
        tokenInAmount = userIn.sub(amountSwap);
    }

    function calculateZapOutAmount(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address pool,
        uint256 lpQty
    ) external view whitelistedFactory(factory) returns (uint256) {
        require(factory.isPool(tokenIn, tokenOut, pool), "INVALID_POOL");
        (uint256 amountIn, uint256 amountOut, ReserveData memory data) = _calculateBurnAmount(
            factory,
            pool,
            tokenIn,
            tokenOut,
            lpQty
        );
        amountOut += KSLibrary.getAmountOut(
            amountIn,
            data.rIn,
            data.rOut,
            data.vIn,
            data.vOut,
            data.feeInPrecision
        );
        return amountOut;
    }

    function calculateSwapAmounts(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address pool,
        uint256 userIn
    ) public view whitelistedFactory(factory) returns (uint256 amountSwap, uint256 amountOutput) {
        require(factory.isPool(tokenIn, tokenOut, pool), "INVALID_POOL");
        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut, uint256 feeInPrecision) = KSLibrary
            .getTradeInfo(pool, tokenIn, tokenOut);
        amountSwap = _calculateSwapInAmount(rIn, rOut, vIn, vOut, feeInPrecision, userIn);
        amountOutput = KSLibrary.getAmountOut(amountSwap, rIn, rOut, vIn, vOut, feeInPrecision);
    }

    function _swap(
        uint256 amountOut,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address pool,
        address to
    ) internal {
        (IERC20 token0, ) = KSLibrary.sortTokens(tokenIn, tokenOut);
        (uint256 amount0Out, uint256 amount1Out) = tokenIn == token0
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        IKSPool(pool).swap(amount0Out, amount1Out, to, new bytes(0));
    }

    function _zapOut(
        IKSFactory factory,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 liquidity,
        address pool,
        uint256 minTokenOut
    ) internal returns (uint256 amountOut) {
        uint256 amountIn;
        {
            require(factory.isPool(tokenIn, tokenOut, pool), "INVALID_POOL");
            IERC20(pool).safeTransferFrom(msg.sender, pool, liquidity); // send liquidity to pool
            (uint256 amount0, uint256 amount1) = IKSPool(pool).burn(address(this));
            (IERC20 token0, ) = KSLibrary.sortTokens(tokenIn, tokenOut);
            (amountIn, amountOut) = tokenIn == token0 ? (amount0, amount1) : (amount1, amount0);
        }
        uint256 swapAmount;
        {
            (
                uint256 rIn,
                uint256 rOut,
                uint256 vIn,
                uint256 vOut,
                uint256 feeInPrecision
            ) = KSLibrary.getTradeInfo(pool, tokenIn, tokenOut);
            swapAmount = KSLibrary.getAmountOut(amountIn, rIn, rOut, vIn, vOut, feeInPrecision);
        }
        tokenIn.safeTransfer(pool, amountIn);
        _swap(swapAmount, tokenIn, tokenOut, pool, address(this));
        amountOut += swapAmount;
        require(amountOut >= minTokenOut, "INSUFFICIENT_OUTPUT_AMOUNT");
    }

    function _calculateBurnAmount(
        IKSFactory factory,
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 lpQty
    )
        internal
        view
        returns (
            uint256 amountIn,
            uint256 amountOut,
            ReserveData memory newData
        )
    {
        ReserveData memory data;
        (data.rIn, data.rOut, data.vIn, data.vOut, data.feeInPrecision) = KSLibrary.getTradeInfo(
            pool,
            tokenIn,
            tokenOut
        );
        uint256 totalSupply = _calculateSyncTotalSupply(factory, IKSPool(pool), data);
        bool isAmpPool = (IKSPool(pool).ampBps() != 10000);
        // calculate amountOut
        amountIn = lpQty.mul(data.rIn) / totalSupply;
        amountOut = lpQty.mul(data.rOut) / totalSupply;
        // calculate ReserveData
        newData.rIn = data.rIn - amountIn;
        newData.rOut = data.rOut - amountOut;
        if (isAmpPool) {
            uint256 b = Math.min(
                newData.rIn.mul(totalSupply) / data.rIn,
                newData.rOut.mul(totalSupply) / data.rOut
            );
            newData.vIn = Math.max(data.vIn.mul(b) / totalSupply, newData.rIn);
            newData.vOut = Math.max(data.vOut.mul(b) / totalSupply, newData.rOut);
        } else {
            newData.vIn = newData.rIn;
            newData.vOut = newData.rOut;
        }
        newData.feeInPrecision = data.feeInPrecision;
    }

    function _calculateSyncTotalSupply(
        IKSFactory factory,
        IKSPool pool,
        ReserveData memory data
    ) internal view returns (uint256 totalSupply) {
        totalSupply = IERC20(address(pool)).totalSupply();

        (address feeTo, uint24 governmentFeeUnits) = factory.getFeeConfiguration();
        if (feeTo == address(0)) return totalSupply;

        uint256 _kLast = pool.kLast();
        if (_kLast == 0) return totalSupply;

        uint256 collectedFee0;
        uint256 _tmp = _kLast * data.vIn;
        if (_tmp / data.vIn == _kLast) {
            collectedFee0 = data.vIn.sub(MathExt.sqrt(_tmp.div(data.vOut)));
        } else {
            collectedFee0 = data.vIn.sub(MathExt.sqrt(_kLast.div(data.vOut).mul(data.vIn)));
        }
        uint256 poolValueInToken0 = data.rIn.add(data.rOut.mul(data.vIn).div(data.vOut));
        uint256 numerator = totalSupply.mul(collectedFee0).mul(governmentFeeUnits);
        uint256 denominator = (poolValueInToken0.sub(collectedFee0)).mul(50000);
        uint256 liquidity = numerator / denominator;

        totalSupply += liquidity;
    }

    function _calculateSwapInAmount(
        uint256 rIn,
        uint256 rOut,
        uint256 vIn,
        uint256 vOut,
        uint256 feeInPrecision,
        uint256 userIn
    ) internal pure returns (uint256) {
        uint256 r = PRECISION - feeInPrecision;
        // b = (vOut * rIn + userIn * (vOut - rOut)) * r / PRECISION / rOut+ vIN
        uint256 b;
        {
            uint256 tmp = userIn.mul(vOut.sub(rOut));
            tmp = tmp.add(vOut.mul(rIn));
            b = tmp.div(rOut).mul(r) / PRECISION;
            b = b.add(vIn);
        }
        uint256 inverseC = vIn.mul(userIn);
        // numerator = sqrt(b^2 -4ac) - b
        uint256 numerator = MathExt.sqrt(b.mul(b).add(inverseC.mul(4 * r) / PRECISION)).sub(b);
        return numerator.mul(PRECISION) / (2 * r);
    }
}