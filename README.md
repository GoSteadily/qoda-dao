# Qoda DAO
## Build Instructions

1. Install npm dependencies: `npm install`
1. Install foundry according to [Foundry Book Installation Page](https://book.getfoundry.sh/getting-started/installation)
1. Compile smart contracts: `forge build`
1. Format code: `forge fmt`
1. Run test: `forge test`
1. Run single test with prefix testTotal: `forge test -vvv --match-test testTotal`
1. Run test in forked network: `forge test --fork-url https://[NODE_PROVIDER]`

## Mechanism
User can stake in pre-defined ERC20 token and earn

veQoda balance will be computed , so no claiming is needed to 

There is no lock-up period in place, but to encourage continuous staking, unstaking for any method at any point of time will reset all veQoda balance to 0.

## Total Ve Calculation
For reward distribution, reward at each epoch will be distributed according to account ve / total ve. Ve balance will be calculated automatically without user explicitly claiming token. To avoid iterating all user accounts to deduce total ve at the end of each epoch, total ve will be calculated as follow:

Terminology:
1. Staked token amount of Account A = `S(A)` = StakingInfo.amount
1. Last ve balance of Account A = `LS(A)` = StakingInfo.amountVe
1. Last ve claim time of Account A = `T(A)` = StakingInfo.lastUpdateSec
1. Reward distribution rate = `R` = MethodInfo.vePerDay

$Total\ Ve\ at\ time\ T$  
$= LS(A) + S(A) \cdot [T - T(A)] \cdot R + LS(B) + S(B) \cdot [T - T(B)] \cdot R + ...$  
$= [LS(A) + LS(B) + ...] + S(A) \cdot T \cdot R - S(A) \cdot T(A) \cdot R + S(B) \cdot T \cdot R - S(B) \cdot T(B) \cdot R + ...$  
$= [LS(A) + LS(B) + ...] + [S(A) + S(B) + ...] \cdot T \cdot R - [S(A) \cdot T(A) + S(B) \cdot T(B) + ...] \cdot R$  
$= [LS(A) + LS(B) + ...] + \{ [S(A) + S(B) + ...] \cdot T - [S(A) \cdot T(A) + S(B) \cdot T(B) + ...] \} \cdot R $

So by keeping track of following upon balance update:
1. `[LS(A) + LS(B) + ...]` = MethodInfo.totalVe
1. `[S(A) + S(B) + ...]` = MethodInfo.tokenAmount
1. `[S(A) T(A) + S(B) T(B) + ...]` = MethodInfo.tokenAmountTime

Total ve at any given time can be calculated as `totalVe + (tokenAmount * time - tokenAmountTime) * vePerDay`, as shown in `totalVe()` of VeQoda contract
To support multiple ve per day distribution, tokenAmount, tokenAmountTime and vePerDay should be stored separately

## Development Guide:
1. All contract implementations should be made upgradable (except QodaToken) so DAO can propose upgrade to it.
1. If for-loop is used, make sure looping condition is exposed as parameter to avoid breaching gas limit upon iteration, unless number of entries is guaranteed to be small.
1. Any account can act on behalf on another account to facilitate support, unless the operation will damage benefit of target account (e.g. unstake).
1. Coding style should follow [Solidity Style Guide](https://docs.soliditylang.org/en/v0.8.11/style-guide.html) and [NatSpec Comment Format](https://docs.soliditylang.org/en/v0.8.10/natspec-format.html)
