// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

interface IRewardDistributor {
    //* EVENTS *//

    /// @notice Emitted when sender puts in token for reward distribution
    event DistributeReward(
        address indexed distributor, uint256 indexed amount, uint256 indexed startEpoch, uint256 numEpoch
    );

    /// @notice Emitted when reward is claimed for an account
    event ClaimReward(address indexed account, uint256 indexed epochTarget, uint256 reward);

    /// @notice Emitted during epoch transition
    event EpochUpdate(uint256 indexed epochNumber, uint256 indexed epochStartTime, uint256 totalSupply);

    /// @notice Emitted when admin sets minimum amount required for reward distribution
    event SetMinReward(address indexed sender, uint256 indexed newValue, uint256 indexed oldValue);

    /// @notice Emitted when admin sets minimum number of epoch for reward distribution
    event SetMinEpoch(address indexed sender, uint256 indexed newValue, uint256 indexed oldValue);

    /// @notice Emitted when admin sets maximum number of epoch for reward distribution
    event SetMaxEpoch(address indexed sender, uint256 indexed newValue, uint256 indexed oldValue);

    //* USER INTERFACE *//

    /// @notice Allow sender to distribute Qoda token as reward
    /// @param amount Account address for receiving staking reward
    /// @param epochStart Epoch number where reward distrbution will start
    /// @param epochNum Number of epoches where reward will get distributed evenly
    function distribute(uint256 amount, uint256 epochStart, uint256 epochNum) external;

    /// @notice Claim reward up till min(epochTarget, epochCurrent). Claiming on behalf of another person is allowed.
    /// @param account Account address which reward will be claimed
    /// @param epochTarget Ending epoch that account can claim up till, parameter exposed so that claiming can be done in step-wise manner to avoid gas limit breach
    function claimReward(address account, uint256 epochTarget) external;

    /// @notice Check if it is first interaction after epoch starts, and fix amount of total ve token participated in previous epoch if so
    /// @param epochTarget Ending epoch that update will happen up till, parameter exposed so that update can be done in step-wise manner to avoid gas limit breach
    function updateEpoch(uint256 epochTarget) external;

    /// @notice Function to be called BEFORE veToken balance change for an account. Reward for an account will go into pendingReward
    /// @param account Account address for reward update to happen
    /// @param epochTarget Ending epoch that account reward can be updated up till, parameter exposed so that claiming can be done in step-wise manner to avoid gas limit breach
    function updateAccountReward(address account, uint256 epochTarget) external;

    /// @notice Given timestamp, return what epoch does specified timestamp correspond to
    /// @param timestamp Timestamp in second for fetching epoch number
    /// @return uint256 Epoch number that given timestamp is located in
    function getEpoch(uint256 timestamp) external view returns (uint256);

    /// @notice Given epoch, return timestamp when specified epoch starts
    /// @param epoch Epoch number for fetching timestamp
    /// @return uint256 Timestamp in second when specified epoch starts
    function getTimestamp(uint256 epoch) external view returns (uint256);

    /// @notice Calculate unclaimed reward at specified epoch
    /// @param account Account address for unclaimed reward calculation
    /// @param epochTarget Epoch for calculating reward
    /// @return uint256 Total unclaimed reward at specified epoch
    function getUnclaimedReward(address account, uint256 epochTarget) external view returns (uint256);

    //* ADMIN FUNCTIONS *//

    /// @notice Admin can set minimum reward any account needs for reward distribution. It is to make sure reward schedule list will not be long,
    /// as schedules will be looped through during reward claiming, and long schedule list will increase gas cost involved for each account
    /// @param minReward_ New minimum reward for distribution
    function _setMinReward(uint256 minReward_) external;

    /// @notice Admin can set minimum number of epoch that a reward distribution needs to be distributed across.
    /// @param minEpoch_ New minimum number of epoch for distribution
    function _setMinEpoch(uint256 minEpoch_) external;

    /// @notice Admin can set maximum number of epoch that a reward distribution needs to be distributed across.
    /// @param maxEpoch_ New maximum number of epoch for distribution
    function _setMaxEpoch(uint256 maxEpoch_) external;
}
