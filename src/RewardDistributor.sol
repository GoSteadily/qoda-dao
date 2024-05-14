// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CustomErrors.sol";
import "./IRewardDistributor.sol";
import "./IVeQoda.sol";
import "./StakingStructs.sol";

// Current contract assumes days per epoch to be fixed
// If new number of days per epoch is expected, new contract should be deployed and added into veQoda
contract RewardDistributor is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    IRewardDistributor
{
    using SafeERC20 for IERC20;

    /// @notice Identifier of the admin role
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    /// @notice One day in seconds (24 hours * 60 minutes * 60 seconds)
    uint256 constant ONE_DAY_IN_SEC = 86400;

    /// @notice Reward has to be distributed for at least 1 epoch by default
    uint256 constant DEFAULT_MIN_EPOCH = 1;

    /// @notice Reward will be distributed for at most 3 years (in days) by default
    uint256 constant DEFAULT_MAX_EPOCH_DAYS = 1095;

    /// @notice address of token used for reward distribution
    address public token;

    /// @notice address of veToken where user shares of reward is located
    address public veToken;

    /// @notice Number of days for each epoch
    uint256 public daysPerEpoch;

    /// @notice Current epoch number, starts with 1
    uint256 public epochCurrent;

    /// @notice System start epoch in second
    uint256 public epochSystemStartSec;

    /// @notice Make sure reward to distribute is not too small, as it will increase gas cost for reward claiming for each account
    uint256 public minReward;

    /// @notice Minimum number of epoch a reward must be distributed across
    uint256 public minEpoch;

    /// @notice Maximum number of epoch a reward must be distributed across
    uint256 public maxEpoch;

    /// @notice Mapping of account address to reward detail
    mapping(address => StakingStructs.AccountReward) public accountRewards;

    /// @notice List of reward schedules
    StakingStructs.RewardSchedule[] public schedules;

    /// @notice Total ve during epoch transition, totalVe[2] means total ve at the end of epoch 1 / start of epoch 2
    uint256[] totalVe;

    /// @notice Reserve storage gap so introduction of new parent class later on can be done via upgrade
    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        address veToken_,
        uint256 daysPerEpoch_,
        uint256 epochSystemStartSec_,
        uint256 minReward_
    ) external initializer {
        // Initialize access control
        __AccessControlEnumerable_init();
        _grantRole(ROLE_ADMIN, msg.sender);
        _setRoleAdmin(ROLE_ADMIN, ROLE_ADMIN);

        // Initialize reentrancy guard
        __ReentrancyGuard_init();

        if (token_ == address(0)) {
            revert CustomErrors.InvalidTokenAddress();
        }
        token = token_;

        if (veToken_ == address(0)) {
            revert CustomErrors.InvalidVeTokenAddress();
        }
        veToken = veToken_;

        daysPerEpoch = daysPerEpoch_;
        epochSystemStartSec = epochSystemStartSec_;
        epochCurrent = 0;
        totalVe.push(0); // Push one element in as epoch number starts with 1

        // Configure constraints for a valid reward distribution
        _setMinReward(minReward_);
        _setMinEpoch(DEFAULT_MIN_EPOCH);
        _setMaxEpoch(DEFAULT_MAX_EPOCH_DAYS / daysPerEpoch_ + 1);
    }

    //* USER INTERFACE *//

    /// @notice Allow sender to distribute Qoda token as reward
    /// @param amount Account address for receiving staking reward
    /// @param epochStart Epoch number where reward distrbution will start
    /// @param epochNum Number of epoches where reward will get distributed evenly
    function distribute(uint256 amount, uint256 epochStart, uint256 epochNum) external nonReentrant {
        // Update current epoch number if needed
        updateEpoch(type(uint256).max);

        // Start epoch must happen in future
        if (epochStart <= epochCurrent) {
            revert CustomErrors.EpochHasPassed();
        }

        // Reward distribution must be within epoch range defined by admin
        if (epochNum < minEpoch) {
            revert CustomErrors.MinEpochNotMet();
        }

        if (maxEpoch > 0 && epochNum > maxEpoch) {
            revert CustomErrors.MaxEpochNotMet();
        }

        // Avoid people distribute tiny amount of reward and create huge number of schedules
        if (amount < minReward) {
            revert CustomErrors.MinRewardNotMet();
        }

        // Transfer token from msg.sender to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Add schedule to this contract and log event
        schedules.push(StakingStructs.RewardSchedule(amount, epochStart, epochNum));

        emit DistributeReward(msg.sender, amount, epochStart, epochNum);
    }

    /// @notice Claim reward up till min(epochTarget, epochCurrent). Claiming on behalf of another person is allowed.
    /// @param account Account address which reward will be claimed
    /// @param epochTarget Ending epoch that account can claim up till, parameter exposed so that claiming can be done in step-wise manner to avoid gas limit breach
    function claimReward(address account, uint256 epochTarget) external nonReentrant {
        // Update unclaimed reward for an account before triggering reward transfer
        updateAccountReward(account, epochTarget);

        StakingStructs.AccountReward storage accountReward = accountRewards[account];
        if (accountReward.unclaimedReward > 0) {
            // Reset unclaimed reward before transfer to avoid re-entrancy attack
            uint256 reward = accountReward.unclaimedReward;
            accountReward.unclaimedReward = 0;
            accountReward.claimedReward += reward;

            emit ClaimReward(account, epochTarget, reward);

            IERC20(token).safeTransfer(account, reward);
        }
    }

    /// @notice Check if it is first interaction after epoch starts, and fix amount of total ve token participated in previous epoch if so
    /// @param epochTarget Ending epoch that update will happen up till, parameter exposed so that update can be done in step-wise manner to avoid gas limit breach
    function updateEpoch(uint256 epochTarget) public {
        // Determine what epoch is current time in
        uint256 epochCurrentNew = getEpoch(block.timestamp);

        // If new epoch is on or before current epoch, either contract has not kick-started,
        // or this is not first interaction since epoch starts
        if (epochCurrentNew <= epochCurrent) {
            return;
        }

        // Epoch for current time now has surpassed target epoch, so limit epoch number
        if (epochCurrentNew > epochTarget) {
            epochCurrentNew = epochTarget;
        }

        // Take snapshot of total veToken since this is the first transaction in an epoch
        for (uint256 epoch = epochCurrent + 1; epoch <= epochCurrentNew;) {
            uint256 timeAtEpoch = getTimestamp(epoch);
            uint256 totalSupply = IVeQoda(veToken).totalVe(timeAtEpoch);
            totalVe.push(totalSupply);
            unchecked {
                epoch++;
            }
            // One emission for each epoch
            emit EpochUpdate(epoch, timeAtEpoch, totalSupply);
        }
        epochCurrent = epochCurrentNew;
    }

    /// @notice Function to be called BEFORE veToken balance change for an account. Reward for an account will go into pendingReward
    /// @param account Account address for reward update to happen
    /// @param epochTarget Ending epoch that account reward can be updated up till, parameter exposed so that claiming can be done in step-wise manner to avoid gas limit breach
    function updateAccountReward(address account, uint256 epochTarget) public {
        if (account == address(0)) {
            revert CustomErrors.InvalidAccount();
        }

        // Update current epoch number if needed
        updateEpoch(epochTarget);

        // Make sure user cannot claim reward in the future
        if (epochTarget > epochCurrent) {
            epochTarget = epochCurrent;
        }

        // Calculate unclaimed reward
        uint256 unclaimedReward = getUnclaimedReward(account, epochTarget);

        StakingStructs.AccountReward storage reward = accountRewards[account];
        reward.unclaimedReward = unclaimedReward;
        reward.lastUpdateEpoch = epochTarget;
    }

    /// @notice Given timestamp, return what epoch does specified timestamp correspond to
    /// @param timestamp Timestamp in second for fetching epoch number
    /// @return uint256 Epoch number that given timestamp is located in
    function getEpoch(uint256 timestamp) public view returns (uint256) {
        // Contract has not kick started yet, so no valid epoch
        if (timestamp < epochSystemStartSec) {
            return 0;
        }
        return (timestamp - epochSystemStartSec) / (daysPerEpoch * ONE_DAY_IN_SEC) + 1;
    }

    /// @notice Given epoch, return timestamp when specified epoch starts
    /// @param epoch Epoch number for fetching timestamp
    /// @return uint256 Timestamp in second when specified epoch starts
    function getTimestamp(uint256 epoch) public view returns (uint256) {
        // Epoch starts with 1
        if (epoch <= 0) {
            return 0;
        }
        return epochSystemStartSec + (epoch - 1) * daysPerEpoch * ONE_DAY_IN_SEC;
    }

    /// @notice Calculate unclaimed reward at specified epoch
    /// @param account Account address for unclaimed reward calculation
    /// @param epochTarget Epoch for calculating reward
    /// @return uint256 Total unclaimed reward at specified epoch
    function getUnclaimedReward(address account, uint256 epochTarget) public view returns (uint256) {
        StakingStructs.AccountReward memory reward = accountRewards[account];

        uint256 pendingReward = reward.unclaimedReward;
        if (reward.lastUpdateEpoch > epochTarget) {
            // Contract state does not allow backtracking unclaimed reward in the past
            revert CustomErrors.EpochHasPassed();
        }
        if (reward.lastUpdateEpoch == epochTarget) {
            return pendingReward;
        }

        for (uint256 i = 0; i < schedules.length;) {
            StakingStructs.RewardSchedule memory schedule = schedules[i];
            (uint256 epochStart, uint256 epochEnd) = _getOverlap(
                schedule.epochStart,
                schedule.epochStart + schedule.epochNum - 1,
                reward.lastUpdateEpoch + 1,
                epochTarget
            );
            for (uint256 epoch = epochStart; epoch <= epochEnd;) {
                // if schedule is within queried epoch and more than 1 has staked in the epoch, calculate user's pending reward
                uint256 timeAtEpoch = getTimestamp(epoch);
                uint256 accountVe = IVeQoda(veToken).accountVe(account, timeAtEpoch);
                uint256 totalVeAtEpoch;
                if (totalVe.length > epoch) {
                    totalVeAtEpoch = totalVe[epoch];
                } else {
                    totalVeAtEpoch = IVeQoda(veToken).totalVe(timeAtEpoch);
                }
                if (totalVeAtEpoch > 0) {
                    pendingReward += accountVe * schedule.amount / (totalVeAtEpoch * schedule.epochNum);
                }
                unchecked {
                    epoch++;
                }
            }
            unchecked {
                i++;
            }
        }
        return pendingReward;
    }

    //* ADMIN FUNCTIONS *//

    /// @notice Admin can set minimum reward any account needs for reward distribution. It is to make sure reward schedule list will not be long,
    /// as schedules will be looped through during reward claiming, and long schedule list will increase gas cost involved for each account
    /// @param minReward_ New minimum reward for distribution
    function _setMinReward(uint256 minReward_) public onlyRole(ROLE_ADMIN) {
        if (minReward_ <= 0) {
            revert CustomErrors.MinRewardMustExist();
        }
        emit SetMinReward(msg.sender, minReward_, minReward);
        minReward = minReward_;
    }

    /// @notice Admin can set minimum number of epoch that a reward distribution needs to be distributed across.
    /// @param minEpoch_ New minimum number of epoch for distribution
    function _setMinEpoch(uint256 minEpoch_) public onlyRole(ROLE_ADMIN) {
        emit SetMinEpoch(msg.sender, minEpoch_, minEpoch);
        minEpoch = minEpoch_;
    }

    /// @notice Admin can set maximum number of epoch that a reward distribution needs to be distributed across.
    /// @param maxEpoch_ New maximum number of epoch for distribution
    function _setMaxEpoch(uint256 maxEpoch_) public onlyRole(ROLE_ADMIN) {
        emit SetMinEpoch(msg.sender, maxEpoch_, maxEpoch);
        maxEpoch = maxEpoch_;
    }

    //* INTERNAL FUNCTIONS *//

    /// @notice Given two range [s1, e1] and [s2, e2] (end-point included), find out number of discrete points that are overlapped
    /// e.g. input [3, 7] and [5, 5000] would yield [5, 7] as those 3 points have overlapped
    /// Function assumes s1 < e1 && s2 < e2
    function _getOverlap(uint256 s1, uint256 e1, uint256 s2, uint256 e2) internal pure returns (uint256, uint256) {
        uint256 overlapStart = s1 > s2 ? s1 : s2;
        uint256 overlapEnd = e1 < e2 ? e1 : e2;
        return (overlapStart, overlapEnd);
    }
}
