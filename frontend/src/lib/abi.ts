import { parseAbi } from "viem";

const errors = [
  "error Expired()",
  "error InsufficientAAmount()",
  "error InsufficientBAmount()",
  "error InsufficientOutputAmount()",
  "error ExcessiveInputAmount()",
  "error K()",
  "error Locked()",
  "error InsufficientLiquidity()",
  "error InsufficientLiquidityMinted()",
  "error InsufficientLiquidityBurned()",
  "error PairNotFound(address tokenA, address tokenB)",
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
] as const;

export const routerAbi = parseAbi([
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) returns (uint256[])",
  "function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) returns (uint256, uint256, uint256)",
  "function removeLiquidity(address tokenA, address tokenB, uint256 liquidity, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) returns (uint256, uint256)",
  ...errors,
]);

export const pairAbi = parseAbi([
  "function token0() view returns (address)",
  "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  ...errors,
]);

export const tokenAbi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function faucet()",
  "function faucetAmount() view returns (uint256)",
  "function lastFaucetAt(address user) view returns (uint256)",
  "error FaucetCooldown(uint256 availableAt)",
]);

export const farmAbi = parseAbi([
  "function totalStaked() view returns (uint256)",
  "function totalEffective() view returns (uint256)",
  "function rewardRate() view returns (uint256)",
  "function finishAt() view returns (uint256)",
  "function stakedOf(address user) view returns (uint256)",
  "function effectiveBalanceOf(address user) view returns (uint256)",
  "function earned(address user) view returns (uint256)",
  "function getPositions(address user) view returns ((uint128 amount, uint64 unlockTime, uint16 multiplierBps)[])",
  "function stake(uint256 amount, uint8 lockId) returns (uint256)",
  "function withdraw(uint256 positionId)",
  "function getReward()",
  "function exit()",
  "error ZeroAmount()",
  "error StillLocked(uint256 unlockTime)",
  "error InvalidPosition(uint256 positionId)",
]);
