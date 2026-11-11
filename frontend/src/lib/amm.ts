import type { Address } from "viem";
import { POOLS, tokenByKey, type TokenKey } from "./config";

/** Reserves of a pool, keyed by token, as read from the chain. */
export type PoolState = {
  key: string;
  address: Address;
  farm: Address;
  a: TokenKey;
  b: TokenKey;
  token0: TokenKey; // which of a/b the pair contract calls token0
  reserves: Record<string, bigint>; // token key -> reserve
  totalSupply: bigint;
};

/** Same formula as DexLibrary.getAmountOut: out = in*0.997*rOut / (rIn + in*0.997). */
export function getAmountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountIn <= 0n || reserveIn <= 0n || reserveOut <= 0n) return 0n;
  const inWithFee = amountIn * 9970n;
  return (inWithFee * reserveOut) / (reserveIn * 10_000n + inWithFee);
}

export function findPool(pools: PoolState[], x: TokenKey, y: TokenKey): PoolState | undefined {
  return pools.find((p) => (p.a === x && p.b === y) || (p.a === y && p.b === x));
}

export type Route = {
  path: TokenKey[];
  amounts: bigint[];
  amountOut: bigint;
  /** Output if the whole trade filled at the current mid prices, before fees. */
  idealOut: bigint;
  priceImpactPct: number;
};

function quotePath(pools: PoolState[], path: TokenKey[], amountIn: bigint): Route | undefined {
  const amounts = [amountIn];
  let ideal = amountIn;
  for (let i = 0; i < path.length - 1; i++) {
    const pool = findPool(pools, path[i], path[i + 1]);
    if (!pool) return undefined;
    const rIn = pool.reserves[path[i]];
    const rOut = pool.reserves[path[i + 1]];
    if (!rIn || !rOut) return undefined;
    amounts.push(getAmountOut(amounts[i], rIn, rOut));
    ideal = (ideal * rOut) / rIn;
  }
  const amountOut = amounts[amounts.length - 1];
  // Price impact = how much worse than the mid price, excluding the 0.3% fee per hop.
  const feeFactor = 0.997 ** (path.length - 1);
  const impact = ideal > 0n ? 1 - Number(amountOut) / (Number(ideal) * feeFactor) : 0;
  return { path, amounts, amountOut, idealOut: ideal, priceImpactPct: Math.max(0, impact * 100) };
}

/** Best of the direct route and the route through the third token. */
export function bestRoute(pools: PoolState[], from: TokenKey, to: TokenKey, amountIn: bigint): Route | undefined {
  if (from === to || amountIn <= 0n) return undefined;
  const mid = (["ETH", "BTC", "USD"] as TokenKey[]).find((t) => t !== from && t !== to)!;
  const candidates = [quotePath(pools, [from, to], amountIn), quotePath(pools, [from, mid, to], amountIn)].filter(
    (r): r is Route => r !== undefined && r.amountOut > 0n,
  );
  return candidates.sort((x, y) => (y.amountOut > x.amountOut ? 1 : y.amountOut < x.amountOut ? -1 : 0))[0];
}

/** USD price of each token, from the ETH/USD and BTC/USD pools. */
export function usdPrices(pools: PoolState[]): Record<TokenKey, number> {
  const price = (t: TokenKey) => {
    if (t === "USD") return 1;
    const pool = findPool(pools, t, "USD");
    if (!pool || !pool.reserves[t]) return 0;
    return Number(pool.reserves.USD) / Number(pool.reserves[t]);
  };
  return { ETH: price("ETH"), BTC: price("BTC"), USD: 1 };
}

export function poolTvlUsd(pool: PoolState, prices: Record<TokenKey, number>): number {
  return (
    (Number(pool.reserves[pool.a] ?? 0n) / 1e18) * prices[pool.a] +
    (Number(pool.reserves[pool.b] ?? 0n) / 1e18) * prices[pool.b]
  );
}

export const poolLabel = (pool: { a: TokenKey; b: TokenKey }) =>
  `${tokenByKey(pool.a).symbol} / ${tokenByKey(pool.b).symbol}`;

export const configuredPools = POOLS;
