// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "./mock/TestToken.sol";
import "../src/CustomErrors.sol";
import "../src/IRewardDistributor.sol";
import "../src/IVeQoda.sol";
import "../src/RewardDistributor.sol";
import "../src/VeQoda.sol";

contract TestRewardDistributor is Test {
    IRewardDistributor public rewardDistributor;
    IVeQoda public veQoda;
    TestToken public qodaToken;

    uint256 public constant DAYS_PER_EPOCH = 10;
    uint256 public constant TIME_NOW_SECS = 1_704_067_200 - 86_400; // 1 day before 2024-01-01 00:00:00

    address public constant _user1 = 0x1111111111111111111111111111111111111111;
    address public constant _user2 = 0x2222222222222222222222222222222222222222;
    address public constant _adminUpgrade = 0x8888888888888888888888888888888888888888;
    address public constant _admin = 0x9999999999999999999999999999999999999999;

    bytes32 public vanillaMethod;

    function setUp() public {
        vm.warp(TIME_NOW_SECS);
        vm.startPrank(_admin);

        qodaToken = new TestToken("Qoda Token", "Qoda", 6);

        VeQoda veQodaImpl = new VeQoda();
        TransparentUpgradeableProxy veQodaProxy = new TransparentUpgradeableProxy(
            address(veQodaImpl),
            _adminUpgrade,
            abi.encodeWithSignature(
                "initialize(string,string,address,uint256)", "Staked Qoda Token", "veQoda", address(qodaToken), 1e6
            )
        );
        veQoda = VeQoda(address(veQodaProxy));
        vanillaMethod = VeQoda(address(veQoda)).STAKE_VANILLA();

        RewardDistributor rewardDistributorImpl = new RewardDistributor();
        TransparentUpgradeableProxy rewardDistributorProxy = new TransparentUpgradeableProxy(
            address(rewardDistributorImpl),
            _adminUpgrade,
            abi.encodeWithSignature(
                "initialize(address,address,uint256,uint256,uint256)",
                address(qodaToken),
                address(veQoda),
                DAYS_PER_EPOCH,
                TIME_NOW_SECS + 86400,
                1
            )
        );
        rewardDistributor = RewardDistributor(address(rewardDistributorProxy));

        veQoda._addRewardDistributor(address(rewardDistributor));

        vm.stopPrank();
    }

    function stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        qodaToken.mint(account, amount);
        qodaToken.approve(address(veQoda), amount);
        veQoda.stake(account, vanillaMethod, amount);
        vm.stopPrank();
    }

    function distribute(address account, uint256 amount, uint256 epochStart, uint256 epochNum) internal {
        vm.startPrank(account);
        qodaToken.mint(account, amount);
        qodaToken.approve(address(rewardDistributor), amount);
        rewardDistributor.distribute(amount, epochStart, epochNum);
        vm.stopPrank();
    }

    function testEpochUpdate() public {
        // Epoch before system start time is 0
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS), 0);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 - 1), 0);

        // Epoch at system start time is 1, which lasts for DAYS_PER_EPOCH days
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400), 1);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400 - 1), 1);

        // After that epoch is 2
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400), 2);

        // Move time to start of epoch 2
        vm.warp(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400);

        // Make sure epoch calculation is independent of current timestamp
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS), 0);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 - 1), 0);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400), 1);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400 - 1), 1);
        assertEq(rewardDistributor.getEpoch(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400), 2);
    }

    function testUnclaimedReward() public {
        // User2 put 100 Qoda into reward distributor from epoch 1 to 5
        distribute(_user2, 100e6, 1, 5);

        // User1 put 20 Qoda for staking before epoch 1
        stake(_user1, 20e6);

        // Make sure calculation is correct
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 0), 0);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 1), 20e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 5), 100e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, type(uint256).max), 100e6);

        // Move time by 1 day and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + 86400);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 1), 20e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 5), 100e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, type(uint256).max), 100e6);

        // User2 has staked 50 Qoda in the middle of epoch 1
        vm.warp(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400 / 2);
        stake(_user2, 50e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 1), 20e6);
        assertEq(rewardDistributor.getUnclaimedReward(_user2, 1), 0);

        // At start of epoch 2, user1 should have 20 * 11 days = 220 veQoda, user2 should have 50 * 5 days = 250 veQoda
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 2), 20e6 + 20e6 * 220 / uint256(470));
        assertEq(rewardDistributor.getUnclaimedReward(_user2, 2), 20e6 * 250 / uint256(470));

        // At start of epoch 3, user1 should have 20 * 21 days = 420 veQoda, user2 should have 50 * 15 days = 750 veQoda
        assertEq(
            rewardDistributor.getUnclaimedReward(_user1, 3),
            20e6 + 20e6 * 220 / uint256(470) + 20e6 * 420 / uint256(1170)
        );
        assertEq(
            rewardDistributor.getUnclaimedReward(_user2, 3), 20e6 * 250 / uint256(470) + 20e6 * 750 / uint256(1170)
        );

        // User2 has unstaked 10 Qoda at the start of epoch 2
        vm.warp(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400);
        vm.prank(_user2);
        veQoda.unstake(vanillaMethod, 10e6);

        // Unstake will reset ve balance, but unclaimed reward should remain
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 2), 20e6 + 20e6 * 220 / uint256(470));
        assertEq(rewardDistributor.getUnclaimedReward(_user2, 2), 20e6 * 250 / uint256(470));

        // User1 has further staked 10 Qoda at the start of epoch 2;
        stake(_user1, 10e6);

        // Stake will increase subsequent ve balance, but current unclaimed reward should remain
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 2), 20e6 + 20e6 * 220 / uint256(470));
        assertEq(rewardDistributor.getUnclaimedReward(_user2, 2), 20e6 * 250 / uint256(470));

        // At start of epoch 3, user1 should have 20 * 21 days + 10 * 10 days = 520 veQoda, user2 should have 40 * 10 days = 400 veQoda
        assertEq(
            rewardDistributor.getUnclaimedReward(_user1, 3),
            20e6 + 20e6 * 220 / uint256(470) + 20e6 * 520 / uint256(920)
        );
        assertEq(rewardDistributor.getUnclaimedReward(_user2, 3), 20e6 * 250 / uint256(470) + 20e6 * 400 / uint256(920));
    }

    function testClaimReward() public {
        // User2 put 100 Qoda into reward distributor from epoch 1 to 5
        distribute(_user2, 100e6, 1, 5);

        // User1 puts 20 Qoda for staking before epoch 1, and User2 puts 30 Qoda
        stake(_user1, 20e6);
        stake(_user2, 30e6);

        // Make sure user has nothing to claim initially
        rewardDistributor.claimReward(_user1, type(uint256).max);
        rewardDistributor.claimReward(_user2, type(uint256).max);
        assertEq(qodaToken.balanceOf(_user1), 0);
        assertEq(qodaToken.balanceOf(_user2), 0);

        // Move time to start of epoch 1
        vm.warp(TIME_NOW_SECS + 86400);

        // 20 Qoda will be distributed in each round, and user1 will be entitled to 8 Qoda
        rewardDistributor.claimReward(_user1, type(uint256).max);
        assertEq(qodaToken.balanceOf(_user1), 8e6);

        // Move time to middle of epoch 3
        vm.warp(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400 * 5 / 2);

        // User can claim 2 epoches at once
        rewardDistributor.claimReward(_user1, type(uint256).max);
        assertEq(qodaToken.balanceOf(_user1), 24e6);

        // User can claim epoch by epoch (in case looping causes gas to run out)
        rewardDistributor.claimReward(_user2, 1);
        assertEq(qodaToken.balanceOf(_user2), 12e6);
        rewardDistributor.claimReward(_user2, 2);
        assertEq(qodaToken.balanceOf(_user2), 24e6);

        // Staking will cause calculated reward to be placed in unclaimedReward, but balance will not be changed
        stake(_user2, 10e6);
        assertEq(qodaToken.balanceOf(_user2), 24e6);

        // Unstaking ve will cause calculated reward to be placed in unclaimedReward, but balance will only be changed by unstaked amount
        vm.prank(_user2);
        veQoda.unstake(vanillaMethod, 10e6);
        assertEq(qodaToken.balanceOf(_user2), 34e6);

        // User can still claim previous calculated reward
        rewardDistributor.claimReward(_user2, 3);
        assertEq(qodaToken.balanceOf(_user2), 46e6);

        // Repeated claiming will have no effect on Qoda balance
        rewardDistributor.claimReward(_user2, 3);
        assertEq(qodaToken.balanceOf(_user2), 46e6);
    }

    function testDistribute() public {
        // Any user distributing reward must distribute a minimum of 100 Qoda
        vm.prank(_admin);
        rewardDistributor._setMinReward(100e6);

        // Move time to start of epoch 2
        vm.warp(TIME_NOW_SECS + 86400 + DAYS_PER_EPOCH * 86400);

        vm.startPrank(_user2);
        qodaToken.mint(_user2, 600e6);
        qodaToken.approve(address(rewardDistributor), 600e6);

        // Cannot distribute in current or earlier epoch
        vm.expectRevert(CustomErrors.EpochHasPassed.selector);
        rewardDistributor.distribute(100e6, 1, 5);

        vm.expectRevert(CustomErrors.EpochHasPassed.selector);
        rewardDistributor.distribute(100e6, 2, 5);

        // Must distribute in at least 1 epoch
        vm.expectRevert(CustomErrors.MinEpochNotMet.selector);
        rewardDistributor.distribute(100e6, 3, 0);

        // Min reward requirement must be met
        vm.expectRevert(CustomErrors.MinRewardNotMet.selector);
        rewardDistributor.distribute(99e6, 3, 5);

        vm.stopPrank();

        // User2 puts in reward:
        // 1. 100 Qoda for epoch 3 to 7
        // 2. 200 Qoda for epoch 4 to 11
        // 3. 300 Qoda for epoch 13 to 14
        vm.startPrank(_user2);
        rewardDistributor.distribute(100e6, 3, 5);
        rewardDistributor.distribute(200e6, 4, 8);
        rewardDistributor.distribute(300e6, 13, 1);
        vm.stopPrank();

        // User1 put 10 Qoda for staking before epoch 1
        stake(_user1, 10e6);

        // Schedule 1 will be distributed
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 3), 20e6);

        // Schedule 1 and 2 will be distributed
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 4), 40e6 + 25e6);

        // Schedule 1 last emission
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 7), 100e6 + 100e6);

        // Schedule 1 no longer applies
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 8), 100e6 + 125e6);

        // Schedule 2 no longer applies
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 11), 100e6 + 200e6);

        // No schedule applies
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 12), 100e6 + 200e6);

        // Schedule 3 will be distributed
        assertEq(rewardDistributor.getUnclaimedReward(_user1, 13), 100e6 + 200e6 + 300e6);
    }
}
