pragma solidity ^0.8.24;

uint256 constant UNDERLYING_TOKEN_MASK = 1;

library BitMask {
    function calcIndex(uint256 mask) internal pure returns (uint8 index) {
        require(mask != 0, "Invalid mask"); 
        uint16 lb = 0;
        uint16 ub = 256;
        uint16 mid = 128;

        unchecked {
            while (true) {
                uint256 newMask = 1 << mid;
                if (newMask & mask != 0) return uint8(mid);

                if (newMask > mask) ub = mid;

                else lb = mid;
                mid = (lb + ub) >> 1;
            }
        }
    }

    function calcEnabledTokens(uint256 enabledTokensMask) internal pure returns (uint256 totalTokensEnabled) {
        unchecked {
            while (enabledTokensMask > 0) {
                enabledTokensMask &= enabledTokensMask - 1;
                ++totalTokensEnabled;
            }
        }
    }

    function enable(uint256 enabledTokenMask, uint256 bitsToEnable) internal pure returns (uint256) {
        return enabledTokenMask | bitsToEnable;
    }

    function disable(uint256 enabledTokenMask, uint256 bitsToDisable) internal pure returns (uint256) {
        return enabledTokenMask & ~bitsToDisable;
    }

    function enableDisable(uint256 enabledTokensMask, uint256 bitsToEnable, uint256 bitsToDisable)
        internal
        pure
        returns (uint256)
    {
        return (enabledTokensMask | bitsToEnable) & (~bitsToDisable);
    }

    function enable(uint256 enabledTokenMask, uint256 bitsToEnable, uint256 invertedSkipMask)
        internal
        pure
        returns (uint256)
    {
        return enabledTokenMask | (bitsToEnable & invertedSkipMask);
    }

    function disable(uint256 enabledTokenMask, uint256 bitsToDisable, uint256 invertedSkipMask)
        internal
        pure
        returns (uint256)
    {
        return enabledTokenMask & (~(bitsToDisable & invertedSkipMask));
    }

    function enableDisable(
        uint256 enabledTokensMask,
        uint256 bitsToEnable,
        uint256 bitsToDisable,
        uint256 invertedSkipMask
    ) internal pure returns (uint256) {
        return (enabledTokensMask | (bitsToEnable & invertedSkipMask)) & (~(bitsToDisable & invertedSkipMask));
    }
}
