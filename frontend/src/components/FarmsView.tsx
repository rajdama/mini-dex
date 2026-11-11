"use client";

import { useState } from "react";
import { formatEther, maxUint256 } from "viem";
import { useAccount } from "wagmi";
import { farmAbi, pairAbi } from "@/lib/abi";
import { poolLabel, poolTvlUsd, usdPrices, type PoolState } from "@/lib/amm";
import { BASE_MULTIPLIER_BPS, LOCK_OPTIONS } from "@/lib/farm";
import { tokenByKey } from "@/lib/config";
import { fmtAmount, fmtDuration, fmtUsd } from "@/lib/format";
import type { DexState, FarmState, UserFarm, UserState } from "@/hooks/useDex";
import { useNow } from "@/hooks/useNow";
import { useTx } from "@/hooks/useTx";
import { parseAmount } from "./SwapCard";

export function FarmsView({ dex, user }: { dex: DexState; user: UserState }) {
  const prices = usdPrices(dex.pools);
  return (
    <>
      <p className="hint" style={{ marginTop: 24 }}>
        Stake your LP tokens to earn MDX rewards on top of trading fees. Lock them for longer to earn up to 3x more. You
        keep earning swap fees while your LP tokens are staked.
      </p>
      <div className="farm-grid" style={{ marginTop: 12 }}>
        {dex.pools.map((pool) => (
          <FarmCard
            key={pool.key}
            pool={pool}
            farm={dex.farms[pool.key]}
            mine={user.farms[pool.key]}
            lpBalance={user.lpBalances[pool.key] ?? 0n}
            fetchedAt={user.fetchedAt}
            lpValueUsd={pool.totalSupply > 0n ? poolTvlUsd(pool, prices) / (Number(pool.totalSupply) / 1e18) : 0}
          />
        ))}
      </div>
    </>
  );
}

function FarmCard({
  pool,
  farm,
  mine,
  lpBalance,
  fetchedAt,
  lpValueUsd,
}: {
  pool: PoolState;
  farm: FarmState | undefined;
  mine: UserFarm | undefined;
  lpBalance: bigint;
  fetchedAt: number;
  lpValueUsd: number;
}) {
  const { isConnected } = useAccount();
  const { send, busy } = useTx();
  const now = useNow();
  const [input, setInput] = useState("");
  const [lockId, setLockId] = useState(0);

  if (!farm) return null;
  const active = now < farm.finishAt;
  const perDay = active ? farm.rewardRate * 86_400n : 0n;
  const amount = parseAmount(input);
  const needsApproval = amount > 0n && (mine?.lpAllowance ?? 0n) < amount;

  // Rewards tick up locally between reads, using the same math as the contract.
  let earned = mine?.earned ?? 0n;
  if (mine && farm.totalEffective > 0n && mine.effective > 0n && fetchedAt > 0) {
    const from = Math.floor(fetchedAt / 1000);
    const to = Math.min(now, farm.finishAt);
    if (to > from) earned += (mine.effective * farm.rewardRate * BigInt(to - from)) / farm.totalEffective;
  }
  const open = mine?.positions.filter((p) => p.amount > 0n) ?? [];

  const approve = () =>
    send("Approve LP tokens for farm", {
      address: pool.address,
      abi: pairAbi,
      functionName: "approve",
      args: [pool.farm, maxUint256],
    });
  const stake = async () => {
    const ok = await send(`Stake ${fmtAmount(amount)} LP`, {
      address: pool.farm,
      abi: farmAbi,
      functionName: "stake",
      args: [amount, lockId],
    });
    if (ok) setInput("");
  };
  const claim = () => send("Claim MDX", { address: pool.farm, abi: farmAbi, functionName: "getReward" });
  const withdraw = (id: number) =>
    send("Withdraw LP", { address: pool.farm, abi: farmAbi, functionName: "withdraw", args: [BigInt(id)] });

  return (
    <div className="card">
      <div className="card-head">
        <h2>
          <span className="dot" style={{ background: tokenByKey(pool.a).color }} />
          {poolLabel(pool)}
        </h2>
        <span className="badge">{active ? `ends in ${fmtDuration(farm.finishAt - now)}` : "paused"}</span>
      </div>

      <div className="kv">
        <span>Staked in farm</span>
        <span>{fmtUsd((Number(farm.totalStaked) / 1e18) * lpValueUsd)}</span>
      </div>
      <div className="kv">
        <span>Rewards</span>
        <span>{fmtAmount(perDay)} MDX / day</span>
      </div>
      <div className="kv">
        <span>Your stake</span>
        <span>
          {fmtAmount(mine?.staked)} LP{mine && mine.staked > 0n ? ` (${fmtUsd((Number(mine.staked) / 1e18) * lpValueUsd)})` : ""}
        </span>
      </div>

      <div style={{ margin: "16px 0" }}>
        <div className="stat-label">Your MDX rewards</div>
        <div className="big-number" style={{ fontSize: 26 }}>
          {fmtAmount(earned)}
        </div>
      </div>

      <div className="field-label">
        <span>LP to stake</span>
        <span>
          {fmtAmount(lpBalance)} in wallet{" "}
          <button className="link-btn" onClick={() => setInput(lpBalance > 0n ? formatEther(lpBalance) : "")}>
            Max
          </button>
        </span>
      </div>
      <div className="input-row">
        <input
          inputMode="decimal"
          placeholder="0.0"
          value={input}
          onChange={(e) => setInput(e.target.value.replace(/[^0-9.]/g, ""))}
          aria-label={`LP amount to stake in ${poolLabel(pool)} farm`}
        />
      </div>
      <div className="locks" role="radiogroup" aria-label="Lock period">
        {LOCK_OPTIONS.map((o) => (
          <button
            key={o.id}
            role="radio"
            aria-checked={lockId === o.id}
            className={`lock ${lockId === o.id ? "selected" : ""}`}
            onClick={() => setLockId(o.id)}
          >
            <div className="lock-mult">{o.multiplierBps / BASE_MULTIPLIER_BPS}x</div>
            <div className="lock-label">{o.label}</div>
          </button>
        ))}
      </div>
      {!isConnected ? (
        <button className="btn" disabled>
          Connect a wallet to farm
        </button>
      ) : amount > lpBalance ? (
        <button className="btn" disabled>
          Not enough LP tokens
        </button>
      ) : needsApproval ? (
        <button className="btn" disabled={busy} onClick={approve}>
          Approve LP tokens
        </button>
      ) : (
        <button className="btn" disabled={busy || amount === 0n} onClick={stake}>
          {amount === 0n ? "Enter an amount" : "Stake LP"}
        </button>
      )}

      {open.length > 0 && (
        <table className="table" style={{ marginTop: 16 }}>
          <tbody>
            {open.map((p) => {
              const unlocked = p.unlockTime <= now;
              return (
                <tr key={p.id}>
                  <td>{fmtAmount(p.amount)} LP</td>
                  <td>{p.multiplierBps / BASE_MULTIPLIER_BPS}x</td>
                  <td>
                    <button className="btn secondary small" disabled={busy || !unlocked} onClick={() => withdraw(p.id)}>
                      {unlocked ? "Withdraw" : `in ${fmtDuration(p.unlockTime - now)}`}
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <button className="btn secondary" style={{ marginTop: 12 }} disabled={busy || earned === 0n} onClick={claim}>
        Claim MDX
      </button>
    </div>
  );
}
