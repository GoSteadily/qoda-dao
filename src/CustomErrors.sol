// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

library CustomErrors {
    error TransferFromZeroAddress();

    error BuyFeesTooHigh();

    error SellFeesTooHigh();

    error ZeroStakeAmount();

    error ZeroUnstakeAmount();

    error InvalidStakingToken();

    error InvalidEffectiveTime();

    error DistributorAlreadyExist();

    error DistributorNotExist();

    error InsufficientBalance();

    error TransferDisabled();

    error EpochUndefined();

    error EpochHasPassed();

    error MinEpochNotMet();

    error MaxEpochNotMet();

    error MinRewardNotMet();

    error MinRewardMustExist();

    error InvalidExclusionAddress();

    error InvalidAutomatedMarketMakerPairs();

    error InvalidTokenAddress();

    error InvalidVeTokenAddress();

    error InvalidAccount();
}
