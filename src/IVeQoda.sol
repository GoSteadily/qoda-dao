// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./StakingStructs.sol";

interface IVeQoda is IERC20 {
    //* EVENTS *//

    /// @notice Emitted when user stakes
    event Stake(address indexed account, bytes32 indexed method, address indexed token, uint256 amount);

    /// @notice Emitted when user unstakes
    event Unstake(address indexed account, bytes32 indexed method, address indexed token, uint256 amount);

    /// @notice Emitted when admin sets staking detail for given staking method
    event SetStakingMethod(
        bytes32 indexed stakingMethod, address indexed token, uint256 vePerDay, uint256 vePerDayEffective
    );

    /// @notice Emitted when a reward distributor is added to veToken
    event AddRewardDistributor(address indexed rewardDistributor);

    /// @notice Emitted when a reward distributor is added to veToken
    event RemoveRewardDistributor(address indexed rewardDistributor);

    //* USER INTERFACE *//

    /// @notice Stake token into contract
    /// @param account Account address for receiving staking reward
    /// @param method Staking method account used for staking
    /// @param amount Amount of token to stake
    function stake(address account, bytes32 method, uint256 amount) external;

    /// @notice Unstake tokens, note that you will lose ALL your veToken if you unstake ANY amount with either method
    /// So to protect account interest, only sender can unstake, neither admin nor support can act on behalf in this process
    /// @param method Staking method user wish to unstake from
    /// @param amount Amount of tokens to unstake
    function unstake(bytes32 method, uint256 amount) external;

    /// @notice Project / Back-calculate total ve at given timestamp. Note that for simplicity, this function has no knowledge of token amount versus time
    /// in the past, so backward calculation should only be used if it is certain no ve token change has happened in between
    /// @param account Address to check
    /// @param timestamp Timestamp in second when account ve will be calculated
    /// @return uint256 Amount of account veToken at given timestamp
    function accountVe(address account, uint256 timestamp) external view returns (uint256);

    /// @notice Project / Back-calculate total ve at given timestamp. Note that for simplicity, this function has no knowledge of token amount versus time
    /// in the past, so backward calculation should only be used if it is certain no ve token change has happened in between
    /// Explanation for calculation can be found in https://github.com/QodaFi/qoda-dao?tab=readme-ov-file#total-ve-calculation
    /// @param timestamp Timestamp in second when total ve will be calculated
    /// @return uint256 Amount of total veToken at given timestamp
    function totalVe(uint256 timestamp) external view returns (uint256);

    /// @notice Get staking info of user in specified staking method
    /// @param account Address to check
    /// @param method Staking method to check (Vanilla or LP)
    /// @return StakingInfo Staking info for given user and method
    function userStakingInfo(address account, bytes32 method)
        external
        view
        returns (StakingStructs.StakingInfo memory);

    /// @notice Get info of staking method currently supported
    /// @param method Staking method to check (Vanilla or LP)
    /// @return (Token address, Token decimal, Total staked amount, ve emitted per day, ve per day effective time) for given staking method
    function methodInfo(bytes32 method)
        external
        view
        returns (address, uint8, uint256, uint256[] memory, uint256[] memory);

    /// @notice List all staking methods currently supported
    /// @return bytes32[] All staking methods in keccak256
    function methods() external view returns (bytes32[] memory);

    //* ADMIN FUNCTIONS *//

    /// @notice Only admin can see list of users in case of maintenance activity like contract migration
    /// @return address[] List of users currently participated in the contract
    function users() external view returns (address[] memory);

    /// @notice Admin can set staking method detail
    /// Note that it is assumed insertion sequence in array is sequential to reduce looping inside contract
    /// @param method Staking method in keccak256
    /// @param token Token address account needs to stake for specified staking method
    /// @param vePerDay Amount of ve token that will be distributed each day, scaled with SCALE_FACTOR_VE_PER_DAY
    /// @param vePerDayEffective Timestamp in second for specified vePerDay to become active, 0 means current time
    function _setStakingMethod(bytes32 method, address token, uint256 vePerDay, uint256 vePerDayEffective) external;

    /// @notice Only admin can add IRewardDistributor address into the contract for emission during ve balance change
    /// @param rewardDistributor address of contract for IRewardDistributor
    function _addRewardDistributor(address rewardDistributor) external;

    /// @notice Only admin can remove IRewardDistributor address
    /// @param rewardDistributor address of contract for IRewardDistributor
    function _removeRewardDistributor(address rewardDistributor) external;
}
