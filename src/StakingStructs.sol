// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

library StakingStructs {
    using EnumerableMap for EnumerableMap.UintToUintMap;

    struct StakingInfo {
        /// @notice Token staked by account
        uint256 amount;
        /// @notice veToken accumulated by account
        uint256 amountVe;
        /// @notice Last veToken update in second, or deposit time in second if account has not claimed before
        uint256 lastUpdateSec;
    }

    struct MethodInfo {
        /// @notice Token to stake to earn reward
        address token;
        /// @notice Storing token decimal to avoid loading token contract, which incurs gas cost
        uint8 tokenDecimal;
        /// @notice Total ve claimed with this method so far. Note that this value is for internal accounting and does not represent totalVe for the method
        uint256 totalVe;
        /// @notice Ve emission detail associated with given method. Note that it is assumed vePerDay effective time in array is in ascending order
        VeEmissionInfo[] veEmissions;
    }

    struct VeEmissionInfo {
        /// @notice vePerDay effective time in second
        uint256 vePerDayEffective;
        /// @notice ve token to be emitted per staked Qoda per day, scaled by SCALE_FACTOR_VE_PER_DAY
        uint256 vePerDay;
        /// @notice Token staked with this method, sum up across all methods should equal token.balanceOf(address(veToken))
        uint256 tokenAmount;
        /// @notice Total staked * last stake time with this method so far, to be used in projecting totalSupply at given block without iteration
        uint256 tokenAmountTime;
    }

    /// @notice Account-related detail for RewardDistributor
    struct AccountReward {
        /// @notice Reward claimed by given account so far
        uint256 claimedReward;
        /// @notice Unclaimed reward that has been calculated but not yet claimed. Note that this value is for internal accounting and
        /// does not represent all unclaimed reward for an account. User should use getUnclaimedReward(msg.sender, getEpoch(block.timestamp)) for that.
        uint256 unclaimedReward;
        /// @notice Epoch number where above fields are updated
        uint256 lastUpdateEpoch;
    }

    /// @notice Reward distribution schedule for RewardDistributor
    struct RewardSchedule {
        /// @notice Amount of reward to be distributed
        uint256 amount;
        /// @notice Starting epoch (inclusive) for when reward distribution will happen
        uint256 epochStart;
        /// @notice Number of epoches mentioned reward will be distributed across
        uint256 epochNum;
    }
}
