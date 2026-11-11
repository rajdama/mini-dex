"use client";

import { useAccount, useReadContracts } from "wagmi";
import { zeroAddress, type Address, type ContractFunctionParameters } from "viem";
import { farmAbi, pairAbi, tokenAbi } from "@/lib/abi";
import { isConfigured, POOLS, ROUTER, TOKENS, type TokenKey } from "@/lib/config";
import type { PoolState } from "@/lib/amm";

const REFRESH_MS = 10_000;

export type FarmState = {
  totalStaked: bigint;
  totalEffective: bigint;
  rewardRate: bigint;
  finishAt: number;
};

export type Position = { id: number; amount: bigint; unlockTime: number; multiplierBps: number };

export type UserFarm = {
  staked: bigint;
  effective: bigint;
  earned: bigint;
  positions: Position[];
  lpAllowance: bigint; // LP approved to the farm
};

/** Pool reserves and farm totals, readable without a wallet. */
export function useDexState() {
  const contracts: ContractFunctionParameters[] = POOLS.flatMap((p) => [
    { address: p.address, abi: pairAbi, functionName: "getReserves" } as const,
    { address: p.address, abi: pairAbi, functionName: "token0" } as const,
    { address: p.address, abi: pairAbi, functionName: "totalSupply" } as const,
    { address: p.farm, abi: farmAbi, functionName: "totalStaked" } as const,
    { address: p.farm, abi: farmAbi, functionName: "totalEffective" } as const,
    { address: p.farm, abi: farmAbi, functionName: "rewardRate" } as const,
    { address: p.farm, abi: farmAbi, functionName: "finishAt" } as const,
  ]);
  const { data, dataUpdatedAt, error } = useReadContracts({
    contracts,
    allowFailure: false,
    query: { enabled: isConfigured, refetchInterval: REFRESH_MS },
  });

  const pools: PoolState[] = [];
  const farms: Record<string, FarmState> = {};
  if (data) {
    POOLS.forEach((p, i) => {
      const d = data.slice(i * 7, i * 7 + 7) as unknown[];
      const [r0, r1] = d[0] as readonly [bigint, bigint, number];
      const token0 = (d[1] as string).toLowerCase();
      const aAddress = TOKENS.find((t) => t.key === p.a)!.address.toLowerCase();
      const aIs0 = token0 === aAddress;
      pools.push({
        ...p,
        token0: aIs0 ? p.a : p.b,
        reserves: { [p.a]: aIs0 ? r0 : r1, [p.b]: aIs0 ? r1 : r0 },
        totalSupply: d[2] as bigint,
      });
      farms[p.key] = {
        totalStaked: d[3] as bigint,
        totalEffective: d[4] as bigint,
        rewardRate: d[5] as bigint,
        finishAt: Number(d[6] as bigint),
      };
    });
  }
  return { pools, farms, fetchedAt: dataUpdatedAt, error, loaded: data !== undefined };
}

/** The connected wallet's token balances, LP balances, allowances and farm positions. */
export function useUserState() {
  const { address } = useAccount();
  const user = (address ?? zeroAddress) as Address;

  const tokenCalls: ContractFunctionParameters[] = TOKENS.flatMap((t) => [
    { address: t.address, abi: tokenAbi, functionName: "balanceOf", args: [user] } as const,
    { address: t.address, abi: tokenAbi, functionName: "allowance", args: [user, ROUTER] } as const,
    { address: t.address, abi: tokenAbi, functionName: "lastFaucetAt", args: [user] } as const,
    { address: t.address, abi: tokenAbi, functionName: "faucetAmount" } as const,
  ]);
  const poolCalls: ContractFunctionParameters[] = POOLS.flatMap((p) => [
    { address: p.address, abi: pairAbi, functionName: "balanceOf", args: [user] } as const,
    { address: p.address, abi: pairAbi, functionName: "allowance", args: [user, ROUTER] } as const,
    { address: p.address, abi: pairAbi, functionName: "allowance", args: [user, p.farm] } as const,
    { address: p.farm, abi: farmAbi, functionName: "stakedOf", args: [user] } as const,
    { address: p.farm, abi: farmAbi, functionName: "effectiveBalanceOf", args: [user] } as const,
    { address: p.farm, abi: farmAbi, functionName: "earned", args: [user] } as const,
    { address: p.farm, abi: farmAbi, functionName: "getPositions", args: [user] } as const,
  ]);

  const { data, dataUpdatedAt } = useReadContracts({
    contracts: [...tokenCalls, ...poolCalls],
    allowFailure: false,
    query: { enabled: isConfigured && address !== undefined, refetchInterval: REFRESH_MS },
  });

  const balances = {} as Record<TokenKey, bigint>;
  const allowances = {} as Record<TokenKey, bigint>;
  const faucetReadyAt = {} as Record<TokenKey, number>;
  const faucetAmounts = {} as Record<TokenKey, bigint>;
  const lpBalances: Record<string, bigint> = {};
  const lpRouterAllowances: Record<string, bigint> = {};
  const farms: Record<string, UserFarm> = {};

  if (data) {
    const d = data as unknown[];
    TOKENS.forEach((t, i) => {
      balances[t.key] = d[i * 4] as bigint;
      allowances[t.key] = d[i * 4 + 1] as bigint;
      const last = Number(d[i * 4 + 2] as bigint);
      faucetReadyAt[t.key] = last === 0 ? 0 : last + 86_400;
      faucetAmounts[t.key] = d[i * 4 + 3] as bigint;
    });
    const base = TOKENS.length * 4;
    POOLS.forEach((p, i) => {
      const o = base + i * 7;
      lpBalances[p.key] = d[o] as bigint;
      lpRouterAllowances[p.key] = d[o + 1] as bigint;
      const raw = d[o + 6] as readonly { amount: bigint; unlockTime: bigint; multiplierBps: number }[];
      farms[p.key] = {
        lpAllowance: d[o + 2] as bigint,
        staked: d[o + 3] as bigint,
        effective: d[o + 4] as bigint,
        earned: d[o + 5] as bigint,
        positions: raw.map((x, id) => ({
          id,
          amount: x.amount,
          unlockTime: Number(x.unlockTime),
          multiplierBps: Number(x.multiplierBps),
        })),
      };
    });
  }

  return {
    address,
    loaded: data !== undefined,
    fetchedAt: dataUpdatedAt,
    balances,
    allowances,
    faucetReadyAt,
    faucetAmounts,
    lpBalances,
    lpRouterAllowances,
    farms,
  };
}

export type DexState = ReturnType<typeof useDexState>;
export type UserState = ReturnType<typeof useUserState>;
