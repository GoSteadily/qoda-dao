// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "./mock/TestToken.sol";
import "../src/CustomErrors.sol";
import "../src/IVeQoda.sol";
import "../src/VeQoda.sol";

contract TestVeQoda is Test {
    IVeQoda public veQoda;
    TestToken public qodaToken;
    TestToken public lpToken;

    uint256 public constant TIME_NOW_SECS = 1_704_067_200; // 2024-01-01 00:00:00

    address public constant _user1 = 0x1111111111111111111111111111111111111111;
    address public constant _user2 = 0x2222222222222222222222222222222222222222;
    address public constant _adminUpgrade = 0x8888888888888888888888888888888888888888;
    address public constant _admin = 0x9999999999999999999999999999999999999999;

    bytes32 public vanillaMethod;
    bytes32 public lpMethod;

    function setUp() public {
        vm.warp(TIME_NOW_SECS);
        vm.startPrank(_admin);

        // Qoda token and LP token will be of different decimal to make sure decimal will not affect veQoda calculation
        qodaToken = new TestToken("Qoda Token", "Qoda", 6);
        lpToken = new TestToken("LP Token", "LP", 12);
        VeQoda veQodaImpl = new VeQoda();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(veQodaImpl),
            _adminUpgrade,
            abi.encodeWithSignature(
                "initialize(string,string,address,uint256)", "Staked Qoda Token", "veQoda", address(qodaToken), 1e6
            )
        );
        veQoda = IVeQoda(address(proxy));
        vanillaMethod = veQodaImpl.STAKE_VANILLA();
        lpMethod = veQodaImpl.STAKE_LIQUIDITY_POOL();

        // Set staking method for LP token as well
        veQoda._setStakingMethod(lpMethod, address(lpToken), 10e6, 0);

        vm.stopPrank();
    }

    function setStakingMethod() internal {
        vm.startPrank(_admin);
        veQoda._setStakingMethod(vanillaMethod, address(qodaToken), 1e6, 0);
        veQoda._setStakingMethod(lpMethod, address(lpToken), 10e6, 0);
        vm.stopPrank();
    }

    function stake(address account, bytes32 method, uint256 amount) internal {
        TestToken token = method == vanillaMethod ? qodaToken : lpToken;
        vm.startPrank(account);
        token.mint(account, amount);
        token.approve(address(veQoda), amount);
        veQoda.stake(account, method, amount);
        vm.stopPrank();
    }

    function testStakingZeroAmount() public {
        vm.expectRevert(CustomErrors.ZeroStakeAmount.selector);
        veQoda.stake(_user1, vanillaMethod, 0);
    }

    function testStakingVanilla() public {
        // Stake Qoda as user1 using vanilla method
        stake(_user1, vanillaMethod, 1e6);

        // Make sure money is transferred from user to contract
        assertEq(qodaToken.balanceOf(address(veQoda)), 1e6);
        assertEq(qodaToken.balanceOf(_user1), 0);

        // Make sure Qoda balance is updated accordingly
        StakingStructs.StakingInfo memory stakingInfo = veQoda.userStakingInfo(_user1, vanillaMethod);
        assertEq(stakingInfo.amount, 1e6);
        assertEq(stakingInfo.amountVe, 0);
        assertEq(stakingInfo.lastUpdateSec, block.timestamp);

        (,, uint256 tokenAmount,,) = veQoda.methodInfo(vanillaMethod);
        assertEq(tokenAmount, 1e6);

        // Make sure veQoda balance is still 0
        assertEq(veQoda.balanceOf(_user1), 0);
    }

    function testStakingLP() public {
        // Stake Qoda as LP for user1 using LP method
        // Token is minted for LP here, but in reality token should be transferred from user to LP
        stake(_user1, lpMethod, 1e12);

        // Make sure money is transferred from LP to contract
        assertEq(lpToken.balanceOf(address(veQoda)), 1e12);

        // Make sure Qoda balance is updated accordingly
        StakingStructs.StakingInfo memory stakingInfo = veQoda.userStakingInfo(_user1, lpMethod);
        assertEq(stakingInfo.amount, 1e12);
        assertEq(stakingInfo.amountVe, 0);
        assertEq(stakingInfo.lastUpdateSec, block.timestamp);

        (,, uint256 tokenAmount,,) = veQoda.methodInfo(lpMethod);
        assertEq(tokenAmount, 1e12);

        // Make sure veQoda balance is still 0
        assertEq(veQoda.balanceOf(_user1), 0);
    }

    function testAccountVe() public {
        // Stake Qoda as both user1 and user2 using vanilla method
        stake(_user1, vanillaMethod, 1e6);
        stake(_user2, vanillaMethod, 4e6);

        // Stake Qoda as LP for user1 using LP method
        stake(_user1, lpMethod, 1e12);

        // Make sure total ve calculation now and in the future is correct
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS), 0);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 11e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 27.5e18);

        // Move time by 1 day and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + 86400);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS), 0);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 11e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 27.5e18);

        // Unstake should reset all ve balance of given account
        vm.prank(_user1);
        veQoda.unstake(vanillaMethod, 1e6);
        // Only ve accrued by LP method should remain
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 0);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 15e18);

        // Move time by 2.5 days and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + 86400 * 5 / 2);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 0);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 15e18);
    }

    function testTotalVeSingleVePerDay() public {
        // Stake Qoda as both user1 and user2 using vanilla method
        stake(_user1, vanillaMethod, 1e6);
        stake(_user2, vanillaMethod, 4e6);

        // Stake Qoda as LP for user1 using LP method
        stake(_user1, lpMethod, 1e12);

        // Make sure total ve calculation now and in the future is correct
        uint256 timePassSec = 86400 * 5 / 2;
        assertEq(veQoda.totalVe(TIME_NOW_SECS), 0);

        // Total ve with Vanilla: 5 Qoda * 2.5 days * 1 ve per day = 12.5 ve
        // Total ve with LP: 1 Qoda * 2.5 days * 10 ve per day = 25 ve
        // Total ve = 12.5 + 25 = 37.5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + timePassSec), 37.5e18);

        // Move time by 1 day and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + 86400);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + timePassSec), 37.5e18);

        // User1 has now staked 5 more tokens
        stake(_user1, vanillaMethod, 5e6);

        // Total ve with Vanilla after 2.5 days will now increase by 5 Qoda * 1.5 days * 1 ve per day = 7.5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + timePassSec), 45e18);

        // User1 has not unstaked 5 tokens
        vm.prank(_user1);
        veQoda.unstake(vanillaMethod, 5e6);

        // Total ve in 2.5 days will now become:
        // Total ve with Vanilla for User1: 1 Qoda * 1.5 days * 1 ve per day = 1.5 ve
        // Total ve with Vanilla for User2: 4 Qoda * 2.5 days * 1 ve per day = 10 ve
        // Total ve with LP for User1: 1 Qoda * 1.5 days * 10 ve per day = 15 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + timePassSec), 26.5e18);

        // Move time by 2.5 days and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + timePassSec);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + timePassSec), 26.5e18);

        // Make sure backward calculation is still correct
        // Total ve in 1 day will now become:
        // Total ve with Vanilla for User2: 4 Qoda * 1 day * 1 ve per day = 4 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400), 4e18);
    }

    function testTotalVeMultipleVePerDay() public {
        // Stake Qoda as both user1 and user2 using vanilla method
        stake(_user1, vanillaMethod, 1e6);
        stake(_user2, vanillaMethod, 4e6);

        // After one day, ve distribution changes from 1 to 3 ve per Qoda per day
        // After two days, ve distribution changes from 3 to 2 ve per Qoda per day
        vm.startPrank(_admin);
        veQoda._setStakingMethod(vanillaMethod, address(qodaToken), 3e6, TIME_NOW_SECS + 86400);
        veQoda._setStakingMethod(vanillaMethod, address(qodaToken), 2e6, TIME_NOW_SECS + 86400 * 2);
        vm.stopPrank();

        // After 0.5 days, total ve will be 5 Qoda * 0.5 days * 1 ve per day = 2.5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 / 2), 2.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 / 2), 2.5e18 / 5);
        // After 1 day, total ve will be 5 Qoda * 1 days * 1 ve per day = 5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400), 5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 5e18 / 5);
        // After 1.5 days, total ve will be 5 Qoda * 1 days * 1 ve per day + 5 Qoda * 0.5 days * 3 ve per day = 12.5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18 / 5);
        // After 2 days, total ve will be 5 Qoda * 1 days * 1 ve per day + 5 Qoda * 1 days * 3 ve per day = 20 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 2), 20e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 2), 20e18 / 5);
        // After 2.5 days, total ve will be 5 Qoda * 1 days * 1 ve per day + 5 Qoda * 1 days * 3 ve per day + 5 Qoda * 0.5 days * 2 ve per day = 25 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5 / 2), 25e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 25e18 / 5);
        // After 5 days, total ve will be 5 Qoda * 1 days * 1 ve per day + 5 Qoda * 1 days * 3 ve per day + 5 Qoda * 3 days * 2 ve per day = 50 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5), 50e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5), 50e18 / 5);

        // Move time by 1.5 days and make sure calculation is still correct
        vm.warp(TIME_NOW_SECS + 86400 * 3 / 2);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 / 2), 2.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 / 2), 2.5e18 / 5);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400), 5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400), 5e18 / 5);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18 / 5);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 2), 20e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 2), 20e18 / 5);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5 / 2), 25e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5 / 2), 25e18 / 5);
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5), 50e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5), 50e18 / 5);

        // User1 has now staked 5 more tokens
        stake(_user1, vanillaMethod, 5e6);

        // ve balance will remain unchanged at given time
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 3 / 2), 12.5e18 / 5);

        // After 0.5 days more, ve balance will increase by 10 Qoda * 0.5 days * 3 ve per day = 15 ve
        // User 1 balance will be 2.5 ve + 6 Qoda * 0.5 days * 3 ve per day = 11.5 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 2), 27.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 2), 11.5e18);

        // User 2 will have 4 Qoda * 1 day * 1 ve per day + 4 Qoda * 1 day * 3 ve per day = 16 ve
        assertEq(veQoda.accountVe(_user2, TIME_NOW_SECS + 86400 * 2), 16e18);

        // At T = 5, ve balance will be 27.5 ve + 10 Qoda * 3 days * 2 ve per day = 87.5 ve
        // User 1 balance will be 11.5 ve + 6 Qoda * 3 days * 2 ve per day = 47.5 ve
        // User 2 balance will be 16 ve + 4 Qoda * 3 days * 2 ve per day = 40 ve
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5), 87.5e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5), 47.5e18);
        assertEq(veQoda.accountVe(_user2, TIME_NOW_SECS + 86400 * 5), 40e18);
    }

    function testVeQodaBalance() public {
        // Stake Qoda as user1 using vanilla method
        stake(_user1, vanillaMethod, 1e6);

        // Stake Qoda as LP for user1 using LP method
        stake(_user1, lpMethod, 1e12);

        // Do the same for user2 to make sure token updating will not spill over
        stake(_user2, vanillaMethod, 2e6);
        stake(_user2, lpMethod, 2e12);

        // Make sure veQoda is 0 right after staking
        assertEq(veQoda.balanceOf(_user1), 0);

        // Make sure updated veQoda in future is correct
        uint256 timePassSec = 86400 * 5 / 2;
        vm.warp(TIME_NOW_SECS + timePassSec);

        // Make sure veQoda for users are calculated correctly
        assertEq(veQoda.balanceOf(_user1), 2.5e18 + 2.5e19);
        assertEq(veQoda.balanceOf(_user2), 5e18 + 5e19);
    }

    function testStakingDoesNotAffectVeQodaBalance() public {
        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        stake(_user1, lpMethod, 1e12);

        // Time passed by 2.5 days
        uint256 timePassSec = 86400 * 5 / 2;
        vm.warp(TIME_NOW_SECS + timePassSec);

        // Make sure veToken amount is still unchanged upon staking even though user does not explicitly claim
        assertEq(veQoda.balanceOf(_user1), 2.5e18 + 2.5e19);
        stake(_user1, vanillaMethod, 1e6);
        assertEq(veQoda.balanceOf(_user1), 2.5e18 + 2.5e19);
    }

    function testUnstakingZeroAmount() public {
        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        stake(_user1, lpMethod, 1e12);
        vm.warp(TIME_NOW_SECS + 86400);

        // Make sure unstake 0 amount will be reverted
        vm.startPrank(_user1);

        vm.expectRevert(CustomErrors.ZeroUnstakeAmount.selector);
        veQoda.unstake(vanillaMethod, 0);

        vm.expectRevert(CustomErrors.ZeroUnstakeAmount.selector);
        veQoda.unstake(lpMethod, 0);

        vm.stopPrank();
    }

    function testUnstakingResetVe() public {
        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        stake(_user1, lpMethod, 1e12);
        vm.warp(TIME_NOW_SECS + 86400);

        // Unstake from one method
        vm.startPrank(_user1);
        assertEq(veQoda.balanceOf(_user1), 1e18 + 1e19);
        veQoda.unstake(vanillaMethod, 0.5e6);

        StakingStructs.StakingInfo memory vanillaInfo = veQoda.userStakingInfo(_user1, vanillaMethod);
        StakingStructs.StakingInfo memory lpInfo = veQoda.userStakingInfo(_user1, lpMethod);

        // Make sure veToken balance is reset to 0 for both
        assertEq(veQoda.balanceOf(_user1), 0);
        assertEq(vanillaInfo.amountVe, 0);
        assertEq(lpInfo.amountVe, 0);

        // Make sure token balance is adjusted accordingly
        assertEq(vanillaInfo.amount, 0.5e6);
        assertEq(lpInfo.amount, 1e12);

        // Make sure last update time is adjusted accordingly
        assertEq(vanillaInfo.lastUpdateSec, TIME_NOW_SECS + 86400);
        assertEq(lpInfo.lastUpdateSec, TIME_NOW_SECS + 86400);

        vm.stopPrank();
    }

    function testUnstakingSmallAmount() public {
        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        stake(_user1, lpMethod, 1e12);
        vm.warp(TIME_NOW_SECS + 86400);

        // Unstake tiny amount
        vm.startPrank(_user1);
        veQoda.unstake(vanillaMethod, 1);
        vm.stopPrank();

        StakingStructs.StakingInfo memory vanillaInfo = veQoda.userStakingInfo(_user1, vanillaMethod);
        StakingStructs.StakingInfo memory lpInfo = veQoda.userStakingInfo(_user1, lpMethod);

        // Make sure veToken balance is reset to 0 for both
        assertEq(veQoda.balanceOf(_user1), 0);
        assertEq(vanillaInfo.amountVe, 0);
        assertEq(lpInfo.amountVe, 0);

        // Make sure token balance is adjusted accordingly
        assertEq(vanillaInfo.amount, 1e6 - 1);
        assertEq(lpInfo.amount, 1e12);
    }

    function testUnstakingInDifferentEmissionRate() public {
        // Stake Qoda as both user1 and user2 using vanilla method
        stake(_user1, vanillaMethod, 1e6);
        stake(_user2, vanillaMethod, 4e6);

        // Default ve distribution is 1 ve per Qoda per day
        // After one day, ve distribution changes from 1 to 3 ve per Qoda per day
        // After two days, ve distribution changes from 3 to 2 ve per Qoda per day
        vm.startPrank(_admin);
        veQoda._setStakingMethod(vanillaMethod, address(qodaToken), 3e6, TIME_NOW_SECS + 86400);
        veQoda._setStakingMethod(vanillaMethod, address(qodaToken), 2e6, TIME_NOW_SECS + 86400 * 2);
        vm.stopPrank();

        // Move time by 5 days and User2 unstakes 1 Qoda token
        vm.warp(TIME_NOW_SECS + 86400 * 5);
        vm.prank(_user2);
        veQoda.unstake(vanillaMethod, 1e6);

        // At T = 5, User 1 balance will be
        //   1 Qoda * 1 days * 1 ve per day
        // + 1 Qoda * 1 days * 3 ve per day
        // + 1 Qoda * 3 days * 2 ve per day
        // = 10 ve
        // User 2 balance will be 0 ve as unstaking has just been done
        assertEq(veQoda.totalVe(TIME_NOW_SECS + 86400 * 5), 10e18);
        assertEq(veQoda.accountVe(_user1, TIME_NOW_SECS + 86400 * 5), 10e18);
        assertEq(veQoda.accountVe(_user2, TIME_NOW_SECS + 86400 * 5), 0);
    }

    function testUnstakingAllRemoveUser() public {
        // Make sure user does not exist beforehand
        vm.startPrank(_admin);
        assertEq(veQoda.users().length, 0);
        vm.stopPrank();

        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        stake(_user1, lpMethod, 1e12);

        // Make sure user exists in array
        vm.startPrank(_admin);
        assertEq(veQoda.users().length, 1);
        vm.stopPrank();

        // Unstake all from one will not have user removed
        vm.startPrank(_user1);
        veQoda.unstake(vanillaMethod, 1e6);
        vm.stopPrank();

        // Make sure user still exists in array
        vm.startPrank(_admin);
        assertEq(veQoda.users().length, 1);
        vm.stopPrank();

        // Unstake all from both will have user removed
        vm.startPrank(_user1);
        veQoda.unstake(lpMethod, 1e12);
        vm.stopPrank();

        // Make sure user no longer exists in array
        vm.startPrank(_admin);
        assertEq(veQoda.users().length, 0);
        vm.stopPrank();
    }

    function testTransferDisabled() public {
        // Stake Qoda as user1
        stake(_user1, vanillaMethod, 1e6);
        vm.warp(TIME_NOW_SECS + 86400);

        // Make sure transfer-related functions are disabled
        vm.startPrank(_user1);

        vm.expectRevert(CustomErrors.TransferDisabled.selector);
        veQoda.approve(_user2, 1e18);

        vm.expectRevert(CustomErrors.TransferDisabled.selector);
        veQoda.transfer(_user2, 1e18);

        vm.expectRevert(CustomErrors.TransferDisabled.selector);
        veQoda.transferFrom(_user1, _user2, 1e18);

        vm.stopPrank();
    }
}
