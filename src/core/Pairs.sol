// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.17;

import {mulDiv, mulDivRoundingUp} from "./math/FullMath.sol";
import {addDelta, calcAmountsForLiquidity, toInt256} from "./math/LiquidityMath.sol";
import {computeSwapStep} from "./math/SwapMath.sol";
import {getRatioAtStrike, MAX_STRIKE, MIN_STRIKE, Q128} from "./math/StrikeMath.sol";
import {BitMaps} from "./BitMaps.sol";

uint8 constant NUM_SPREADS = 5;
int8 constant MAX_CONSECUTIVE = int8(NUM_SPREADS);

/// @author Robert Leifke and Kyle Scott
library Pairs {
    using BitMaps for BitMaps.BitMap;

    /*<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3
                                 ERRORS
    <3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3*/

    error Initialized();
    error InvalidStrike();
    error InvalidSpread();
    error OutOfBounds();

    /*<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3
                               DATA TYPES
    <3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3*/

    struct Spread {
        uint128 composition;
        int24 strikeCurrent;
        uint8 initialized; // 0 = unitialized, 1 = initialized
    }

    struct Strike {
        uint256[NUM_SPREADS] liquidity;
        int24 next0To1;
        int24 next1To0;
        uint8 reference0To1;
        uint8 reference1To0;
    }

    struct Pair {
        Spread[NUM_SPREADS] spreads;
        mapping(int24 => Strike) strikes;
        BitMaps.BitMap bitMap0To1;
        BitMaps.BitMap bitMap1To0;
    }

    /*<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3
                                GET LOGIC
    <3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3<3*/

    function getPairID(address token0, address token1) internal pure returns (bytes32 pairID) {
        return keccak256(abi.encodePacked(token0, token1));
    }

    function getPairAndID(
        mapping(bytes32 => Pair) storage pairs,
        address token0,
        address token1
    )
        internal
        view
        returns (bytes32 pairID, Pair storage pair)
    {
        pairID = getPairID(token0, token1);
        pair = pairs[pairID];
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(Pair storage pair, int24 strikeInitial, uint8 spread) internal {
        if (pair.spreads[spread - 1].initialized != 0) revert Initialized();
        _checkStrike(strikeInitial);

        pair.spreads[spread - 1].strikeCurrent = strikeInitial;
        pair.spreads[spread - 1].initialized = 1;

        pair.bitMap0To1.set(MIN_STRIKE);
        pair.bitMap1To0.set(MIN_STRIKE);
        pair.bitMap0To1.set(-strikeInitial);
        pair.bitMap1To0.set(strikeInitial);
        pair.strikes[MAX_STRIKE].next0To1 = strikeInitial;
        pair.strikes[MIN_STRIKE].next1To0 = strikeInitial;
        pair.strikes[strikeInitial].next0To1 = MIN_STRIKE;
        pair.strikes[strikeInitial].next1To0 = MAX_STRIKE;
        pair.strikes[strikeInitial].reference0To1 = 1;
        pair.strikes[strikeInitial].reference1To0 = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                   SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct to hold temporary data while completing a swap
    struct SwapState {
        uint256 liquidity;
        uint128 composition;
        int24 strikeCurrent;
        int256 amountDesired;
        // pool's balance change of the token which "amountDesired" refers to
        int256 amountA;
        // pool's balance change of the opposite token
        int256 amountB;
    }

    /// @notice Swap between the two tokens in the pair
    /// @param isToken0 True if amountDesired refers to token0
    /// @param amountDesired The desired amount change on the pair
    /// @return amount0 The delta of the balance of token0 of the pair
    /// @return amount1 The delta of the balance of token1 of the pair
    function swap(
        Pair storage pair,
        bool isToken0,
        int256 amountDesired
    )
        internal
        returns (int256 amount0, int256 amount1)
    {
        // if (pair.initialized != 1) revert Initialized();
        bool isExactIn = amountDesired > 0;
        bool isSwap0To1 = isToken0 == isExactIn;

        SwapState memory state;
        {
            int24 strikeCurrent = isSwap0To1 ? MIN_STRIKE : MAX_STRIKE;
            uint256 liquidity;
            uint128 composition;

            // Find the cheapest liquidity available
            // KYLE: This can be improved by caching and exiting early because we know that lower spreads will always
            // have better pricing
            for (uint256 i = 1; i <= NUM_SPREADS;) {
                int24 spreadStrike = pair.spreads[i].strikeCurrent;
                if (isSwap0To1 ? spreadStrike < strikeCurrent : spreadStrike > strikeCurrent) {
                    liquidity = pair.strikes[spreadStrike].liquidity[i];
                    strikeCurrent = spreadStrike;
                    composition = pair.spreads[i].composition;
                } else if (spreadStrike == strikeCurrent && pair.strikes[spreadStrike].liquidity[i] > 0) {
                    liquidity += pair.strikes[spreadStrike].liquidity[i];
                    // KYLE: is this rounding correctly
                    composition +=
                        uint128(mulDiv(pair.spreads[i].composition, pair.strikes[spreadStrike].liquidity[i], liquidity));
                }

                unchecked {
                    i++;
                }
            }

            state = SwapState({
                liquidity: liquidity,
                composition: composition,
                strikeCurrent: strikeCurrent,
                amountDesired: amountDesired,
                amountA: 0,
                amountB: 0
            });
        }

        while (true) {
            uint256 ratioX128 = getRatioAtStrike(state.strikeCurrent);

            (uint256 amountIn, uint256 amountOut, uint256 amountRemaining) =
                computeSwapStep(ratioX128, state.composition, state.liquidity, isToken0, state.amountDesired);

            if (isExactIn) {
                state.amountDesired = state.amountDesired - toInt256(amountIn);
                state.amountA = state.amountA + toInt256(amountIn);
                state.amountB = state.amountB - toInt256(amountOut);
            } else {
                state.amountDesired = state.amountDesired + toInt256(amountOut);
                state.amountA = state.amountA - toInt256(amountOut);
                state.amountB = state.amountB + toInt256(amountIn);
            }

            if (state.amountDesired == 0) {
                if (isSwap0To1) {
                    // KYLE: is this rounding correctly
                    state.composition = uint128(mulDiv(amountRemaining, Q128, state.liquidity));
                } else {
                    // KYLE: is this rounding correctly
                    // solhint-disable-next-line max-line-length
                    state.composition = type(uint128).max - uint128(mulDiv(amountRemaining, ratioX128, state.liquidity));
                }
                break;
            }

            if (isSwap0To1) {
                int24 strikePrev = state.strikeCurrent;
                if (strikePrev == MIN_STRIKE) revert OutOfBounds();
                state.strikeCurrent = pair.strikes[strikePrev].next0To1;

                // Remove strike from linked list and bit map if it has no liquidity
                // Only happens when initialized or all liquidity is removed from current strike
                if (state.liquidity == 0) {
                    assert(pair.strikes[strikePrev].reference0To1 == 1);

                    int24 below = -pair.bitMap0To1.nextBelow(-strikePrev);
                    int24 above = pair.strikes[strikePrev].next0To1;

                    pair.strikes[below].next0To1 = above;
                    pair.bitMap0To1.unset(-strikePrev);

                    pair.strikes[strikePrev].next0To1 = 0;
                    pair.strikes[strikePrev].reference0To1 = 0;
                }

                uint256 liquidity;
                uint128 composition;

                // find all liquidity that has the same strike
                // KYLE: This can be done much more efficiently with caching and exiting early from the loop
                for (uint256 i = 1; i <= NUM_SPREADS;) {
                    int24 spreadStrike = pair.spreads[i].strikeCurrent;
                    if (spreadStrike == state.strikeCurrent && pair.strikes[spreadStrike].liquidity[i] > 0) {
                        liquidity += pair.strikes[spreadStrike].liquidity[i];
                        // KYLE: this isn't doing the correct thing in this case,
                        composition += uint128(
                            mulDiv(pair.spreads[i].composition, pair.strikes[spreadStrike].liquidity[i], liquidity)
                        );
                    }

                    unchecked {
                        i++;
                    }
                }

                state.liquidity = liquidity;
                state.composition = composition;
            } else {
                int24 strikePrev = state.strikeCurrent;
                if (strikePrev == MAX_STRIKE) revert OutOfBounds();
                state.strikeCurrent = pair.strikes[strikePrev].next1To0;

                // Remove strike from linked list and bit map if it has no liquidity
                // Only happens when initialized or all liquidity is removed from current strike
                if (state.liquidity == 0) {
                    assert(pair.strikes[strikePrev].reference1To0 == 1);

                    int24 below = pair.bitMap1To0.nextBelow(strikePrev);
                    int24 above = pair.strikes[strikePrev].next1To0;

                    pair.strikes[below].next1To0 = above;
                    pair.bitMap1To0.unset(strikePrev);

                    pair.strikes[strikePrev].next1To0 = 0;
                    pair.strikes[strikePrev].reference1To0 = 0;
                }

                state.liquidity = 0;
                if (state.consecutiveStrikes > -MAX_CONSECUTIVE) {
                    int24 jump = state.strikeCurrent - strikePrev;
                    state.consecutiveStrikes = int24(state.consecutiveStrikes) - jump <= -MAX_CONSECUTIVE
                        ? -MAX_CONSECUTIVE
                        : int8(state.consecutiveStrikes - jump);
                }

                for (int8 i = 0; i < -state.consecutiveStrikes; i++) {
                    state.liquidity += pair.strikes[state.strikeCurrent - i].getLiquidity(uint8(i));
                }

                uint256 newLiquidity = pair.strikes[state.strikeCurrent + state.consecutiveStrikes].getLiquidity(
                    uint8(-state.consecutiveStrikes)
                );
                uint256 newComposition = pair.compositions[uint8(-state.consecutiveStrikes)];

                state.liquidity += newLiquidity;
                state.composition =
                    state.liquidity == 0 ? 0 : uint128(mulDiv(newComposition, newLiquidity, state.liquidity));
            }
        }

        if (isToken0) {
            amount0 = state.amountA;
            amount1 = state.amountB;
        } else {
            amount0 = state.amountB;
            amount1 = state.amountA;
        }

        for (
            uint8 i = 0;
            i <= uint8(state.consecutiveStrikes >= 0 ? state.consecutiveStrikes : -state.consecutiveStrikes);
            i++
        ) {
            pair.compositions[i] = state.composition;
        }

        pair.strikeCurrent = state.strikeCurrent;
        pair.consecutiveStrikes = state.consecutiveStrikes;
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Update a positions liquidity
    /// @param liquidity The amount of liquidity being added or removed
    function updateLiquidity(
        Pair storage pair,
        int24 strike,
        uint8 spread,
        int256 liquidity
    )
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (pair.spreads[spread - 1].initialized != 1) revert Initialized();
        _checkStrike(strike);
        _checkSpread(spread);

        _updateStrike(pair, strike, spread, liquidity);

        (amount0, amount1) = calcAmountsForLiquidity(
            pair.spreads[spread - 1].strikeCurrent,
            pair.spreads[spread - 1].composition,
            strike,
            liquidity > 0 ? uint256(liquidity) : uint256(-liquidity),
            liquidity > 0
        );
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Check the validiity of strikes
    function _checkStrike(int24 strike) private pure {
        if (MIN_STRIKE > strike || strike > MAX_STRIKE) {
            revert InvalidStrike();
        }
    }

    /// @notice Check the validity of the spread
    function _checkSpread(uint8 spread) private pure {
        if (spread == 0 || spread > NUM_SPREADS + 1) revert InvalidSpread();
    }

    /// @notice Update a strike
    /// @param liquidity The amount of liquidity being added or removed
    /// @custom:team check strike + spread is not greater than max
    function _updateStrike(Pair storage pair, int24 strike, uint8 spread, int256 liquidity) private {
        uint256 existingLiquidity = pair.strikes[strike].liquidity[spread - 1];
        pair.strikes[strike].liquidity[spread - 1] = addDelta(existingLiquidity, liquidity);

        unchecked {
            if (existingLiquidity == 0 && liquidity > 0) {
                int24 strike0To1 = strike - int8(spread);
                int24 strike1To0 = strike + int8(spread);
                uint8 reference0To1 = pair.strikes[strike0To1].reference0To1;
                uint8 reference1To0 = pair.strikes[strike1To0].reference1To0;

                bool add0To1 = reference0To1 == 0;
                bool add1To0 = reference1To0 == 0;
                pair.strikes[strike0To1].reference0To1 = reference0To1 + 1;
                pair.strikes[strike1To0].reference1To0 = reference1To0 + 1;

                if (add0To1) {
                    int24 below = -pair.bitMap0To1.nextBelow(-strike0To1);
                    int24 above = pair.strikes[below].next0To1;

                    pair.strikes[strike0To1].next0To1 = above;
                    pair.strikes[below].next0To1 = strike0To1;
                    pair.bitMap0To1.set(-strike0To1);
                }

                if (add1To0) {
                    int24 below = pair.bitMap1To0.nextBelow(strike1To0);
                    int24 above = pair.strikes[below].next1To0;

                    pair.strikes[strike1To0].next1To0 = above;
                    pair.strikes[below].next1To0 = strike1To0;
                    pair.bitMap1To0.set(strike1To0);
                }
            } else if (liquidity < 0 && existingLiquidity == uint256(-liquidity)) {
                int24 strike0To1 = strike - int8(spread);
                int24 strike1To0 = strike + int8(spread);
                uint8 reference0To1 = pair.strikes[strike0To1].reference0To1;
                uint8 reference1To0 = pair.strikes[strike1To0].reference1To0;

                bool remove0To1 = reference0To1 == 1 && pair.strikeCurrent != strike0To1;
                bool remove1To0 = reference1To0 == 1 && pair.strikeCurrent != strike1To0;
                if (pair.strikeCurrent != strike0To1) pair.strikes[strike0To1].reference0To1 = reference0To1 - 1;
                if (pair.strikeCurrent != strike1To0) pair.strikes[strike1To0].reference1To0 = reference1To0 - 1;

                if (remove0To1) {
                    int24 below = -pair.bitMap0To1.nextBelow(-strike0To1);
                    int24 above = pair.strikes[strike0To1].next0To1;

                    pair.strikes[below].next0To1 = above;
                    pair.bitMap0To1.unset(-strike0To1);

                    pair.strikes[strike0To1].next0To1 = 0;
                }

                if (remove1To0) {
                    int24 below = pair.bitMap1To0.nextBelow(strike1To0);
                    int24 above = pair.strikes[strike1To0].next1To0;

                    pair.strikes[below].next1To0 = above;
                    pair.bitMap1To0.unset(strike1To0);

                    pair.strikes[strike1To0].next1To0 = 0;
                }
            }
        }
    }
}
