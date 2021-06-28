// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../libraries/MathExt.sol";
import "../libraries/DMMLibrary.sol";
import "../interfaces/IDMMPool.sol";
import "../interfaces/IDMMFactory.sol";

import "hardhat/console.sol";

/// @dev detail here: https://hackmd.io/vdqxJx8STNqPm0LG8vGWaw
contract ExampleZapIn {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 private constant PRECISION = 1e18;

    IDMMFactory public immutable factory;

    constructor(IDMMFactory _factory) public {
        factory = _factory;
    }

    function zapIn(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 userIn,
        address pool
    ) external returns (uint256) {
        require(factory.isPool(tokenIn, tokenOut, pool), "DMMRouter: INVALID_POOL");
        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut, uint256 feeInPrecision) = DMMLibrary
            .getTradeInfo(pool, tokenIn, tokenOut);
        uint256 amountSwap = calculateSwapInAmount(rIn, rOut, vIn, vOut, feeInPrecision, userIn);
        uint256 amountOutput = DMMLibrary.getAmountOut(
            amountSwap,
            rIn,
            rOut,
            vIn,
            vOut,
            feeInPrecision
        );

        {
            _swap(amountSwap, amountOutput, tokenIn, tokenOut, pool, address(this));
            tokenIn.safeTransferFrom(msg.sender, pool, userIn.sub(amountSwap));
            tokenOut.safeTransfer(pool, amountOutput);

            // print out to show that the ratio of token 0 and token 1 added is equal to the ratio of real reserves
            (uint256 reserveIn, uint256 reserveOut) = DMMLibrary.getReserves(
                pool,
                tokenIn,
                tokenOut
            );
            console.log(
                userIn.sub(amountSwap),
                DMMLibrary.quote(amountOutput, reserveOut, reserveIn)
            );
        }

        return IDMMPool(pool).mint(msg.sender);
    }

    function _swap(
        uint256 amountIn,
        uint256 amountOut,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address pool,
        address to
    ) internal {
        tokenIn.safeTransferFrom(msg.sender, pool, amountIn);
        (IERC20 token0, ) = DMMLibrary.sortTokens(tokenIn, tokenOut);
        (uint256 amount0Out, uint256 amount1Out) = tokenIn == token0
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        IDMMPool(pool).swap(amount0Out, amount1Out, to, new bytes(0));
    }

    function calculateSwapInAmount(
        uint256 rIn,
        uint256 rOut,
        uint256 vIn,
        uint256 vOut,
        uint256 feeInPrecision,
        uint256 userIn
    ) internal pure returns (uint256) {
        require(feeInPrecision < PRECISION, "invalid feeInPrecision");
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
        uint256 numerator = MathExt.sqrt(b.mul(b).add(inverseC.mul(4).mul(r) / PRECISION)).sub(b);
        return numerator.mul(PRECISION) / (2 * r);
    }
}
