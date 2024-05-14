// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./CustomErrors.sol";
import "./IRewardDistributor.sol";
import "./IVeQoda.sol";
import "./StakingStructs.sol";

/// @notice Functions involving balance update will need to calculate latest reward beforehand, which might consume large amount of gas
/// So if transaction fails due to gas limit, user should go to individual distributor and update their reward balance before retry
contract VeQoda is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC20Upgradeable,
    IVeQoda
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableMap for EnumerableMap.UintToUintMap;

    /// @notice Identifier of the admin role
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    /// @notice Indicator that token is staked with vanilla method
    bytes32 public constant STAKE_VANILLA = keccak256("VANILLA");

    /// @notice Indicator that token is staked with LP method
    bytes32 public constant STAKE_LIQUIDITY_POOL = keccak256("LIQUIDITY_POOL");

    /// @notice Scale factor for vePerDay
    uint256 public constant SCALE_FACTOR_VE_PER_DAY = 1e6;

    /// @notice One day in seconds (24 hours * 60 minutes * 60 seconds)
    uint256 constant ONE_DAY_IN_SEC = 86400;

    /// @notice Max end time an interval is allowed to go up till
    uint256 constant MAX_END_TIME = type(uint256).max;

    /// @notice user info mapping
    /// As struct contains mappings, variable will be private and separate accessor will be provided
    /// account => method => user info
    mapping(address => mapping(bytes32 => StakingStructs.StakingInfo)) private _userInfo;

    EnumerableSet.AddressSet private _users;

    /// @notice Staking method detail mapping
    mapping(bytes32 => StakingStructs.MethodInfo) private _methodInfo;

    EnumerableSet.Bytes32Set private _methods;

    /// @notice Reward distributor that veToken will notify
    EnumerableSet.AddressSet private _rewardDistributors;

    /// @notice Reserve storage gap so introduction of new parent class later on can be done via upgrade
    uint256[50] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address vanillaToken, uint256 vanillaVePerDay)
        external
        initializer
    {
        // Initialize ERC20
        __ERC20_init(name_, symbol_);

        // Initialize access control
        __AccessControlEnumerable_init();
        _grantRole(ROLE_ADMIN, msg.sender);
        _setRoleAdmin(ROLE_ADMIN, ROLE_ADMIN);

        // Initialize reentrancy guard
        __ReentrancyGuard_init();

        // Configure reward for vanilla staking method
        _setStakingMethod(STAKE_VANILLA, vanillaToken, vanillaVePerDay, block.timestamp);
    }

    //* USER INTERFACE *//

    /// @notice Stake token into contract
    /// @param account Account address for receiving staking reward
    /// @param method Staking method account used for staking
    /// @param amount Amount of token to stake
    function stake(address account, bytes32 method, uint256 amount) external nonReentrant {
        if (amount <= 0) {
            revert CustomErrors.ZeroStakeAmount();
        }

        // Calculate unclaimed reward before balance update
        _updateReward(account);

        // if user exists, first update their cached veToken balance
        if (_users.contains(account)) {
            _updateVeTokenCache(account);
        }

        // Do token transfer from user to contract
        address token = _methodInfo[method].token;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // If user not exists before, create user info and add it to an array
        if (!_users.contains(account)) {
            _users.add(account);
        }

        // Update method info, all methods already has lastUpdateSec = block.timestamp in previous update, so only consider the newly added
        StakingStructs.StakingInfo storage info = _userInfo[account][method];
        StakingStructs.VeEmissionInfo[] storage veEmissions = _methodInfo[method].veEmissions;
        uint256 veEmissionLength = veEmissions.length;
        for (uint256 i = 0; i < veEmissionLength;) {
            // Time should be bounded by effective start and end time for current emission
            uint256 effectiveEnd = i < veEmissionLength - 1 ? veEmissions[i + 1].vePerDayEffective : MAX_END_TIME;
            uint256 time = _bounded(block.timestamp, veEmissions[i].vePerDayEffective, effectiveEnd);
            veEmissions[i].tokenAmount += amount;
            veEmissions[i].tokenAmountTime += amount * time;
            unchecked {
                i++;
            }
        }

        // Update user info
        info.amount += amount;
        info.lastUpdateSec = block.timestamp;

        // Emit the event
        emit Stake(account, method, token, amount);
    }

    /// @notice Unstake tokens, note that you will lose ALL your veToken if you unstake ANY amount with either method
    /// So to protect account interest, only sender can unstake, neither admin nor support can act on behalf in this process
    /// @param method Staking method user wish to unstake from
    /// @param amount Amount of tokens to unstake
    function unstake(bytes32 method, uint256 amount) external nonReentrant {
        if (amount <= 0) {
            revert CustomErrors.ZeroUnstakeAmount();
        }

        // User cannot over-unstake
        if (_userInfo[msg.sender][method].amount < amount) {
            revert CustomErrors.InsufficientBalance();
        }

        // Calculate unclaimed reward before balance update
        _updateReward(msg.sender);

        // Reset user ve balance to 0 across all methods
        bool userStaked = false;
        uint256 methodsLength = _methods.length();
        for (uint256 i = 0; i < methodsLength;) {
            bytes32 methodBytes = _methods.at(i);

            StakingStructs.StakingInfo storage info = _userInfo[msg.sender][methodBytes];
            StakingStructs.MethodInfo storage methodInfo_ = _methodInfo[methodBytes];

            // Update method ve balance
            methodInfo_.totalVe -= info.amountVe;

            // For target staked method, reduce token amount across all ve emissions
            StakingStructs.VeEmissionInfo[] storage veEmissions = methodInfo_.veEmissions;
            uint256 veEmissionLength = veEmissions.length;
            for (uint256 j = 0; j < veEmissionLength;) {
                // Time should be bounded by effective start and end time for current emission
                uint256 effectiveEnd = j < veEmissionLength - 1 ? veEmissions[j + 1].vePerDayEffective : MAX_END_TIME;
                uint256 lastUpdateSec = _bounded(info.lastUpdateSec, veEmissions[j].vePerDayEffective, effectiveEnd);
                uint256 time = _bounded(block.timestamp, veEmissions[j].vePerDayEffective, effectiveEnd);

                if (methodBytes == method) {
                    // update token amount and timestamp-related cached value
                    veEmissions[j].tokenAmountTime -=
                        info.amount * lastUpdateSec - (info.amount - amount) * block.timestamp;
                    veEmissions[j].tokenAmount -= amount;
                } else {
                    // update timestamp-related cached value
                    veEmissions[j].tokenAmountTime -= info.amount * (time - lastUpdateSec);
                }
                unchecked {
                    j++;
                }
            }

            // Update account balance and last update time
            info.amountVe = 0;
            info.lastUpdateSec = block.timestamp;
            if (methodBytes == method) {
                info.amount -= amount;
            }
            if (info.amount > 0) {
                userStaked = true;
            }

            unchecked {
                i++;
            }
        }

        // If user no longer stakes, remove user from array
        if (!userStaked) {
            _users.remove(msg.sender);
        }

        // Send back the withdrawn underlying
        address token = _methodInfo[method].token;
        IERC20(token).safeTransfer(msg.sender, amount);

        // Emit the event
        emit Unstake(msg.sender, method, token, amount);
    }

    /// @notice Project / Back-calculate account ve at given timestamp. Note that for simplicity, this function has no knowledge of token amount versus time
    /// in the past, so backward calculation should only be used if it is certain no ve token change has happened in between
    /// @param account Address to check
    /// @param timestamp Timestamp in second when account ve will be calculated
    /// @return uint256 Amount of account veToken at given timestamp
    function accountVe(address account, uint256 timestamp) public view returns (uint256) {
        uint256 methodsLength = _methods.length();
        uint256 accountVe_ = 0;
        for (uint256 i = 0; i < methodsLength;) {
            bytes32 method_ = _methods.at(i);
            StakingStructs.MethodInfo storage method = _methodInfo[method_];
            StakingStructs.StakingInfo memory info = _userInfo[account][method_];

            accountVe_ += info.amountVe;

            if (info.amount > 0) {
                StakingStructs.VeEmissionInfo[] storage veEmissions = method.veEmissions;
                uint256 veEmissionLength = veEmissions.length;
                for (uint256 j = 0; j < veEmissionLength;) {
                    uint256 effectiveEnd =
                        j < veEmissionLength - 1 ? veEmissions[j + 1].vePerDayEffective : MAX_END_TIME;
                    uint256 lastUpdateSec = _bounded(info.lastUpdateSec, veEmissions[j].vePerDayEffective, effectiveEnd);
                    uint256 timeEnd = _bounded(timestamp, veEmissions[j].vePerDayEffective, effectiveEnd);
                    uint256 vePerDay = veEmissions[j].vePerDay;
                    accountVe_ += info.amount * (timeEnd - lastUpdateSec) * vePerDay * 10 ** decimals()
                        / (ONE_DAY_IN_SEC * SCALE_FACTOR_VE_PER_DAY * (10 ** method.tokenDecimal));
                    unchecked {
                        j++;
                    }
                }
            }

            unchecked {
                i++;
            }
        }
        return accountVe_;
    }

    /// @notice Project / Back-calculate total ve at given timestamp. Note that for simplicity, this function has no knowledge of token amount versus time
    /// in the past, so backward calculation should only be used if it is certain no ve token change has happened in between
    /// Explanation for calculation can be found in https://github.com/QodaFi/qoda-dao?tab=readme-ov-file#total-ve-calculation
    /// @param timestamp Timestamp in second when total ve will be calculated
    /// @return uint256 Amount of total veToken at given timestamp
    function totalVe(uint256 timestamp) public view returns (uint256) {
        uint256 methodsLength = _methods.length();
        uint256 totalVe_ = 0;
        for (uint256 i = 0; i < methodsLength;) {
            bytes32 method_ = _methods.at(i);
            StakingStructs.MethodInfo storage method = _methodInfo[method_];

            // Add cached ve value into total
            totalVe_ += method.totalVe;

            StakingStructs.VeEmissionInfo[] storage veEmissions = method.veEmissions;
            uint256 veEmissionLength = veEmissions.length;
            for (uint256 j = 0; j < veEmissionLength;) {
                uint256 effectiveEnd = j < veEmissionLength - 1 ? veEmissions[j + 1].vePerDayEffective : MAX_END_TIME;
                uint256 time = _bounded(timestamp, veEmissions[j].vePerDayEffective, effectiveEnd);
                totalVe_ += (veEmissions[j].tokenAmount * time - veEmissions[j].tokenAmountTime)
                    * veEmissions[j].vePerDay * 10 ** decimals()
                    / (ONE_DAY_IN_SEC * SCALE_FACTOR_VE_PER_DAY * (10 ** method.tokenDecimal));
                unchecked {
                    j++;
                }
            }

            unchecked {
                i++;
            }
        }
        return totalVe_;
    }

    /// @notice Get staking info of user in specified staking method
    /// @param account Address to check
    /// @param method Staking method to check (Vanilla or LP)
    /// @return StakingInfo Staking info for given user and method
    function userStakingInfo(address account, bytes32 method)
        external
        view
        returns (StakingStructs.StakingInfo memory)
    {
        return _userInfo[account][method];
    }

    /// @notice Get info of staking method currently supported
    /// @param method Staking method to check (Vanilla or LP)
    /// @return (Token address, Token decimal, Total staked amount, ve emitted per day, ve per day effective time) for given staking method
    function methodInfo(bytes32 method)
        external
        view
        returns (address, uint8, uint256, uint256[] memory, uint256[] memory)
    {
        StakingStructs.MethodInfo storage method_ = _methodInfo[method];
        StakingStructs.VeEmissionInfo[] storage veEmissions = method_.veEmissions;
        uint256 veEmissionLength = veEmissions.length;

        uint256 tokenAmount = veEmissionLength == 0 ? 0 : veEmissions[veEmissionLength - 1].tokenAmount;
        uint256[] memory vePerDays = new uint256[](veEmissionLength);
        uint256[] memory vePerDayEffectives = new uint256[](veEmissionLength);
        for (uint256 i = 0; i < veEmissionLength;) {
            vePerDays[i] = veEmissions[i].vePerDay;
            vePerDayEffectives[i] = veEmissions[i].vePerDayEffective;
            unchecked {
                i++;
            }
        }

        return (method_.token, method_.tokenDecimal, tokenAmount, vePerDays, vePerDayEffectives);
    }

    /// @notice List all staking methods currently supported
    /// @return bytes32[] All staking methods in keccak256
    function methods() external view returns (bytes32[] memory) {
        return _methods.values();
    }

    //* ADMIN FUNCTIONS *//

    /// @notice Only admin can see list of users in case of maintenance activity like contract migration
    /// @return address[] List of users currently participated in the contract
    function users() external view onlyRole(ROLE_ADMIN) returns (address[] memory) {
        return _users.values();
    }

    /// @notice Admin can set staking method detail
    /// Note that it is assumed insertion sequence in array is sequential to reduce looping inside contract
    /// @param method Staking method in keccak256
    /// @param token Token address account needs to stake for specified staking method
    /// @param vePerDay Amount of ve token that will be distributed each day, scaled with SCALE_FACTOR_VE_PER_DAY
    /// @param vePerDayEffective Timestamp in second for specified vePerDay to become active, 0 means current time
    function _setStakingMethod(bytes32 method, address token, uint256 vePerDay, uint256 vePerDayEffective)
        public
        onlyRole(ROLE_ADMIN)
    {
        if (token == address(0)) {
            revert CustomErrors.InvalidStakingToken();
        }

        if (vePerDayEffective == 0) {
            vePerDayEffective = block.timestamp;
        }
        if (vePerDayEffective < block.timestamp) {
            revert CustomErrors.InvalidEffectiveTime();
        }

        _methodInfo[method].token = token;
        _methodInfo[method].tokenDecimal = IERC20Metadata(token).decimals();

        StakingStructs.VeEmissionInfo[] storage veEmissions = _methodInfo[method].veEmissions;
        uint256 previousAmount = veEmissions.length > 0 ? veEmissions[veEmissions.length - 1].tokenAmount : 0;
        veEmissions.push(
            StakingStructs.VeEmissionInfo({
                vePerDayEffective: vePerDayEffective,
                vePerDay: vePerDay,
                tokenAmount: previousAmount,
                tokenAmountTime: previousAmount * vePerDayEffective
            })
        );
        if (!_methods.contains(method)) {
            _methods.add(method);
        }

        emit SetStakingMethod(method, token, vePerDay, vePerDayEffective);
    }

    /// @notice Only admin can add IRewardDistributor address into the contract for emission during ve balance change
    /// @param rewardDistributor address of contract for IRewardDistributor
    function _addRewardDistributor(address rewardDistributor) external onlyRole(ROLE_ADMIN) {
        if (_rewardDistributors.add(rewardDistributor)) {
            emit AddRewardDistributor(rewardDistributor);
        } else {
            revert CustomErrors.DistributorAlreadyExist();
        }
    }

    /// @notice Only admin can remove IRewardDistributor address
    /// @param rewardDistributor address of contract for IRewardDistributor
    function _removeRewardDistributor(address rewardDistributor) external onlyRole(ROLE_ADMIN) {
        if (_rewardDistributors.remove(rewardDistributor)) {
            emit RemoveRewardDistributor(rewardDistributor);
        } else {
            revert CustomErrors.DistributorNotExist();
        }
    }

    //* INTERNAL FUNCTIONS *//

    /// @notice Function to be called to claim reward up to latest before making any ve balance change
    /// @param account Account address for receiving reward
    function _updateReward(address account) internal {
        uint256 rewardDistributorsLength = _rewardDistributors.length();
        for (uint256 i = 0; i < rewardDistributorsLength;) {
            address rewardDistributor = _rewardDistributors.at(i);
            IRewardDistributor(rewardDistributor).updateAccountReward(account, MAX_END_TIME);
            unchecked {
                i++;
            }
        }
    }

    /// @notice Update cached veToken
    /// @param account Account address
    function _updateVeTokenCache(address account) internal {
        uint256 veTotalIncreaseTotal = 0;
        uint256 methodsLength = _methods.length();
        for (uint256 i = 0; i < methodsLength;) {
            bytes32 method_ = _methods.at(i);

            // Get ve token increment for each method
            uint256 veTokenIncrease = _veTokenIncrease(account, method_, block.timestamp);

            if (veTokenIncrease > 0) {
                veTotalIncreaseTotal += veTokenIncrease;

                // Update method ve balance
                StakingStructs.StakingInfo storage info = _userInfo[account][method_];
                StakingStructs.MethodInfo storage method = _methodInfo[method_];
                method.totalVe += veTokenIncrease;

                StakingStructs.VeEmissionInfo[] storage veEmissions = method.veEmissions;
                uint256 veEmissionLength = veEmissions.length;

                for (uint256 j = 0; j < veEmissionLength;) {
                    // Time should be bounded by effective start and end time for current emission
                    uint256 effectiveEnd =
                        j < veEmissionLength - 1 ? veEmissions[j + 1].vePerDayEffective : MAX_END_TIME;
                    uint256 lastUpdateSec = _bounded(info.lastUpdateSec, veEmissions[j].vePerDayEffective, effectiveEnd);
                    uint256 time = _bounded(block.timestamp, veEmissions[j].vePerDayEffective, effectiveEnd);
                    veEmissions[j].tokenAmountTime += info.amount * (time - lastUpdateSec);

                    unchecked {
                        j++;
                    }
                }

                // Update account balance and last update time
                info.amountVe += veTokenIncrease;
                info.lastUpdateSec = block.timestamp;
            }

            unchecked {
                i++;
            }
        }

        if (veTotalIncreaseTotal > 0) {
            // Calculate unclaimed reward before balance update
            _updateReward(account);
        }
    }

    /// @notice Calculate the amount of veToken increment that needs to be done to reach balance of given timestamp for an account
    /// @param account Address to check
    /// @param method Staking method account used for staking
    /// @param timestamp Timestamp in second when ve balance will be calculated
    /// @return uint256 Amount of veToken that needs to be increased to reach balance
    function _veTokenIncrease(address account, bytes32 method, uint256 timestamp) internal view returns (uint256) {
        StakingStructs.StakingInfo memory info = _userInfo[account][method];
        StakingStructs.MethodInfo storage method_ = _methodInfo[method];

        (uint256 startIndex, uint256[] memory timeElapsed) = _getTimeElapsed(method, info.lastUpdateSec, timestamp);

        if (info.amount == 0 && timeElapsed.length == 0) {
            return 0;
        }

        uint256 timeElapsedLength = timeElapsed.length;
        uint256 accountVe_ = 0;
        for (uint256 i = 0; i < timeElapsedLength;) {
            // veToken amount = native token amount * (time in sec / one day in sec) * ve qoda per day, scaled to decimal of veToken
            uint256 vePerDay = method_.veEmissions[startIndex + i].vePerDay;
            accountVe_ += info.amount * timeElapsed[i] * vePerDay * 10 ** decimals()
                / (ONE_DAY_IN_SEC * SCALE_FACTOR_VE_PER_DAY * (10 ** method_.tokenDecimal));

            unchecked {
                i++;
            }
        }
        return accountVe_;
    }

    /// @notice Given staking method, start time and end time, find out timeElapsed for each vePerDay and how long it lasts
    /// @param method Staking method account used for staking
    /// @param startTime Start time in second for finding overlap
    /// @param endTime End time in second for finding overlap
    /// @return (Start index where overlap will start happening, overlap time in second for each overlapping period) for given staking method
    function _getTimeElapsed(bytes32 method, uint256 startTime, uint256 endTime)
        internal
        view
        returns (uint256, uint256[] memory)
    {
        if (startTime >= endTime) {
            return (0, new uint256[](0));
        }

        StakingStructs.MethodInfo storage method_ = _methodInfo[method];
        StakingStructs.VeEmissionInfo[] storage veEmissions = method_.veEmissions;
        uint256 veEmissionLength = veEmissions.length;

        if (veEmissionLength == 0) {
            return (0, new uint256[](0));
        }

        // Finding index to start calculating ve token increase
        // Note that veEmissions is assumed to be sequential during insertion by admin
        uint256 startIndex = veEmissionLength - 1;
        for (uint256 i = 0; i < veEmissionLength - 1;) {
            if (startTime >= veEmissions[i].vePerDayEffective && startTime < veEmissions[i + 1].vePerDayEffective) {
                startIndex = i;
                break;
            }
            unchecked {
                i++;
            }
        }
        uint256 endIndex = veEmissionLength - 1;
        for (uint256 i = startIndex; i < veEmissionLength - 1;) {
            if (endTime >= veEmissions[i].vePerDayEffective && endTime < veEmissions[i + 1].vePerDayEffective) {
                endIndex = i;
                break;
            }
            unchecked {
                i++;
            }
        }

        uint256[] memory timeElapsed = new uint256[](endIndex - startIndex + 1);
        for (uint256 i = startIndex; i <= endIndex;) {
            uint256 start = startTime > veEmissions[i].vePerDayEffective ? startTime : veEmissions[i].vePerDayEffective;
            uint256 end = endTime;
            if (i + 1 < veEmissionLength) {
                end = end < veEmissions[i + 1].vePerDayEffective ? end : veEmissions[i + 1].vePerDayEffective;
            }
            timeElapsed[i - startIndex] = end - start;

            unchecked {
                i++;
            }
        }
        return (startIndex, timeElapsed);
    }

    function _bounded(uint256 value, uint256 minBound, uint256 maxBound) internal pure returns (uint256) {
        uint256 boundedValue = value;
        if (boundedValue < minBound) {
            boundedValue = minBound;
        }
        if (boundedValue > maxBound) {
            boundedValue = maxBound;
        }
        return boundedValue;
    }

    //* OVERRIDE FUNCTIONS *//

    /// @notice veToken transfers are disabled
    function transfer(address to, uint256 amount) public virtual override(ERC20Upgradeable, IERC20) returns (bool) {
        // Suppress unused variable warnings
        to;
        amount;

        revert CustomErrors.TransferDisabled();
    }

    /// @notice veToken transfers are disabled
    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        // Suppress unused variable warnings
        from;
        to;
        amount;

        revert CustomErrors.TransferDisabled();
    }

    /// @notice veToken transfers are disabled
    function approve(address spender, uint256 amount)
        public
        virtual
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        // Suppress unused variable warnings
        spender;
        amount;

        revert CustomErrors.TransferDisabled();
    }

    /// @notice totalSupply is projected amount of veToken at current time
    function totalSupply() public view virtual override(ERC20Upgradeable, IERC20) returns (uint256) {
        return totalVe(block.timestamp);
    }

    /// @notice balanceOf is projected amount of veToken at current time for given account
    /// @param account Account address for retrieving balance
    function balanceOf(address account) public view virtual override(ERC20Upgradeable, IERC20) returns (uint256) {
        return accountVe(account, block.timestamp);
    }
}
