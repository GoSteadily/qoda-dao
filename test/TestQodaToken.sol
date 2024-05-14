// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "./mock/TestToken.sol";
import "./mock/TestUniswapFactory.sol";
import "../src/CustomErrors.sol";
import "../src/IVeQoda.sol";
import "../src/VeQoda.sol";
import "../src/QodaToken.sol";

contract TestQodaToken is Test {
    TestUniswapFactory public uniswapFactory;

    QodaToken public qodaToken;
    TestToken public usdcToken;

    address public constant _user1 = 0x1111111111111111111111111111111111111111;
    address public constant _admin = 0x9999999999999999999999999999999999999999;

    address public constant _revStream1Wallet = 0x7777777777777777777777777777777777777777;
    address public constant _revStream2Wallet = 0x8888888888888888888888888888888888888888;

    function setUp() public {
        uint256 usdcAmount = 100e6;

        vm.startPrank(_admin);

        uniswapFactory = new TestUniswapFactory();

        usdcToken = new TestToken("USDC Token", "USDC", 6);
        usdcToken.mint(_admin, usdcAmount);

        qodaToken = new QodaToken(
            "Qoda", "QODA", address(usdcToken), address(uniswapFactory), _revStream1Wallet, _revStream2Wallet
        );
        qodaToken.updateBuyFees(0, 0);
        qodaToken.updateSellFees(150, 50);

        vm.stopPrank();
    }

    function testMintRevert() public {
        // Make sure token minting cannot be done
        vm.startPrank(_admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, _admin, 0, 1e18));
        qodaToken.transferFrom(address(0), _admin, 1e18);
        vm.stopPrank();
    }

    function testBurn() public {
        // Make sure token burning can only be done by burn function
        vm.startPrank(_admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        qodaToken.transfer(address(0), 1e18);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, _admin, 0, 1e18));
        qodaToken.transferFrom(_admin, address(0), 1e18);

        qodaToken.burn(1e18);
        vm.stopPrank();

        // Make sure token burning can only be done by admin
        vm.prank(_admin);
        qodaToken.transfer(_user1, 1e18);
        vm.startPrank(_user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _user1));
        qodaToken.burn(1e18);
        vm.stopPrank();
    }

    function testNormalTransferNoCharge() public {
        uint256 totalSupply = qodaToken.totalSupply();

        // Make sure no fee is charged during normal transfer
        vm.prank(_admin);
        qodaToken.transfer(_user1, 100e18);
        assertEq(qodaToken.balanceOf(_user1), 100e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 0);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0);
    }

    function testQodaTokenSellFee() public {
        uint256 totalSupply = qodaToken.totalSupply();

        address tokenPair = uniswapFactory.getPair(address(qodaToken), address(usdcToken));
        assertTrue(qodaToken.automatedMarketMakerPairs(tokenPair));

        // Make sure 2% fee is charged for transfer to tokenPair, 75% to wallet 1, 25% to wallet 2
        vm.prank(_admin);
        qodaToken.transfer(tokenPair, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 98e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 1.5e18);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0.5e18);

        // Make sure fee is not charged when pool is transferring token back
        vm.prank(tokenPair);
        qodaToken.transfer(_user1, 98e18);
        assertEq(qodaToken.balanceOf(tokenPair), 0);
        assertEq(qodaToken.balanceOf(_user1), 98e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 1.5e18);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0.5e18);
    }

    function testQodaTokenBuyFee() public {
        vm.startPrank(_admin);
        qodaToken.updateBuyFees(150, 50);
        qodaToken.updateSellFees(0, 0);
        vm.stopPrank();

        uint256 totalSupply = qodaToken.totalSupply();
        address tokenPair = uniswapFactory.getPair(address(qodaToken), address(usdcToken));

        // Make sure fee is not charged for transfer to tokenPair
        vm.prank(_admin);
        qodaToken.transfer(tokenPair, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 100e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 0);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0);

        // Make sure 2% fee is charged for transfer to tokenPair, 75% to wallet 1, 25% to wallet 2
        vm.prank(tokenPair);
        qodaToken.transfer(_user1, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 0);
        assertEq(qodaToken.balanceOf(_user1), 98e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 1.5e18);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0.5e18);
    }

    function testSellFeeSingleWallet() public {
        vm.startPrank(_admin);
        qodaToken.updateBuyFees(0, 0);
        qodaToken.updateSellFees(200, 0);
        qodaToken.updateRevStream2Wallet(address(0));
        vm.stopPrank();

        uint256 totalSupply = qodaToken.totalSupply();
        address tokenPair = uniswapFactory.getPair(address(qodaToken), address(usdcToken));

        // Make sure 2% fee is charged for transfer to tokenPair
        vm.prank(_admin);
        qodaToken.transfer(tokenPair, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 98e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 2e18);

        // Make sure fee is not charged when pool is transferring token back
        vm.prank(tokenPair);
        qodaToken.transfer(_user1, 98e18);
        assertEq(qodaToken.balanceOf(tokenPair), 0);
        assertEq(qodaToken.balanceOf(_user1), 98e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 2e18);
    }

    function testBuyFeeSingleWallet() public {
        vm.startPrank(_admin);
        qodaToken.updateBuyFees(200, 0);
        qodaToken.updateSellFees(0, 0);
        qodaToken.updateRevStream2Wallet(address(0));
        vm.stopPrank();

        uint256 totalSupply = qodaToken.totalSupply();
        address tokenPair = uniswapFactory.getPair(address(qodaToken), address(usdcToken));

        // Make sure fee is not charged for transfer to tokenPair
        vm.prank(_admin);
        qodaToken.transfer(tokenPair, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 100e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 0);

        // Make sure 2% fee is charged for transfer to tokenPair
        vm.prank(tokenPair);
        qodaToken.transfer(_user1, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 0);
        assertEq(qodaToken.balanceOf(_user1), 98e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 2e18);
    }

    function testUpdateRevert() public {
        vm.startPrank(_admin);

        // Make sure buy fee higher than 5% is reverted
        vm.expectRevert(CustomErrors.BuyFeesTooHigh.selector);
        qodaToken.updateBuyFees(250, 251);

        vm.expectRevert(CustomErrors.BuyFeesTooHigh.selector);
        qodaToken.updateBuyFees(501, 0);

        // Make sure sell fee higher than 5% is reverted
        vm.expectRevert(CustomErrors.SellFeesTooHigh.selector);
        qodaToken.updateSellFees(250, 251);

        vm.expectRevert(CustomErrors.SellFeesTooHigh.selector);
        qodaToken.updateSellFees(501, 0);

        vm.stopPrank();
    }

    function testExcludeFromFees() public {
        vm.startPrank(_admin);
        // Exclude fee for admin account
        qodaToken.excludeFromFees(_admin, true);

        // Set fee for both buy and sell
        qodaToken.updateBuyFees(150, 50);
        qodaToken.updateSellFees(150, 50);
        vm.stopPrank();

        uint256 totalSupply = qodaToken.totalSupply();
        address tokenPair = uniswapFactory.getPair(address(qodaToken), address(usdcToken));

        // Make sure 2% fee is not charged for transfer to tokenPair for admin
        vm.prank(_admin);
        qodaToken.transfer(tokenPair, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 100e18);
        assertEq(qodaToken.balanceOf(_admin), totalSupply - 100e18);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 0);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0);

        // Make sure fee is not charged when pool is transferring token back to admin
        vm.prank(tokenPair);
        qodaToken.transfer(_admin, 100e18);
        assertEq(qodaToken.balanceOf(tokenPair), 0);
        assertEq(qodaToken.balanceOf(_admin), totalSupply);
        assertEq(qodaToken.balanceOf(_revStream1Wallet), 0);
        assertEq(qodaToken.balanceOf(_revStream2Wallet), 0);
    }
}
