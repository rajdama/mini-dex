"use client";

import { useState } from "react";
import { formatEther, maxUint256 } from "viem";
import { useAccount } from "wagmi";
import { pairAbi, routerAbi, tokenAbi } from "@/lib/abi";
import { poolLabel, poolTvlUsd, usdPrices, type PoolState } from "@/lib/amm";
import { DEADLINE_SECONDS, ROUTER, tokenByKey, type TokenKey } from "@/lib/config";
import { fmtAmount, fmtUsd } from "@/lib/format";
import type { DexState, UserState } from "@/hooks/useDex";
import { useTx } from "@/hooks/useTx";
import { parseAmount } from "./SwapCard";

const SLIPPAGE_BPS = 50n;
const withSlippage = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;
const deadline = () => BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS);

export function PoolsView({ dex, user }: { dex: DexState; user: UserState }) {
  const [open, setOpen] = useState<{ pool: string; mode: "add" | "remove" } | null>(null);
  const prices = usdPrices(dex.pools);
  const totalTvl = dex.pools.reduce((s, p) => s + poolTvlUsd(p, prices), 0);

  return (
    <div className="card" style={{ marginTop: 24 }}>
      <div className="card-head">
        <h2>Pools</h2>
        <span className="badge">Total liquidity {fmtUsd(totalTvl)}</span>
      </div>
      <p className="hint" style={{ marginTop: -8, marginBottom: 12 }}>
        Deposit both tokens of a pool to earn 0.3% of every trade through it, in proportion to your share. Stake the LP
        tokens you get in a farm to earn MDX on top.
      </p>
      {dex.pools.map((pool) => {
        const lp = user.lpBalances[pool.key] ?? 0n;
        const farmed = user.farms[pool.key]?.staked ?? 0n;
        const yours = lp + farmed;
        const share = pool.totalSupply > 0n ? Number((yours * 1_000_000n) / pool.totalSupply) / 10_000 : 0;
        const price = Number(pool.reserves[pool.b]) / Number(pool.reserves[pool.a]);
        const isOpen = open?.pool === pool.key;
        return (
          <div key={pool.key}>
            <div className="pool-row">
              <div>
                <div className="pool-name">
                  <span className="dot" style={{ background: tokenByKey(pool.a).color }} />
                  {poolLabel(pool)}
                </div>
                <div className="muted">
                  1 {tokenByKey(pool.a).symbol} = {price.toLocaleString("en-US", { maximumSignificantDigits: 6 })}{" "}
                  {tokenByKey(pool.b).symbol}
                </div>
              </div>
              <div>
                <div>{fmtUsd(poolTvlUsd(pool, prices))}</div>
                <div className="muted">liquidity</div>
              </div>
              <div>
                <div>
                  {fmtAmount(pool.reserves[pool.a])} {tokenByKey(pool.a).symbol}
                </div>
                <div className="muted">
                  {fmtAmount(pool.reserves[pool.b])} {tokenByKey(pool.b).symbol}
                </div>
              </div>
              <div>
                <div>{share > 0 ? `${share.toLocaleString("en-US", { maximumFractionDigits: 2 })}%` : "–"}</div>
                <div className="muted">your share{farmed > 0n ? " (incl. farm)" : ""}</div>
              </div>
              <div className="btn-row">
                <button
                  className="btn small"
                  onClick={() => setOpen(isOpen && open?.mode === "add" ? null : { pool: pool.key, mode: "add" })}
                >
                  Add
                </button>
                <button
                  className="btn secondary small"
                  disabled={lp === 0n}
                  onClick={() => setOpen(isOpen && open?.mode === "remove" ? null : { pool: pool.key, mode: "remove" })}
                >
                  Remove
                </button>
              </div>
            </div>
            {isOpen && open?.mode === "add" && <AddLiquidity pool={pool} user={user} />}
            {isOpen && open?.mode === "remove" && <RemoveLiquidity pool={pool} user={user} />}
          </div>
        );
      })}
    </div>
  );
}

function AddLiquidity({ pool, user }: { pool: PoolState; user: UserState }) {
  const { isConnected } = useAccount();
  const { send, busy } = useTx();
  const [input, setInput] = useState("");
  const a = tokenByKey(pool.a);
  const b = tokenByKey(pool.b);

  const amountA = parseAmount(input);
  const rA = pool.reserves[pool.a];
  const rB = pool.reserves[pool.b];
  const amountB = rA > 0n ? (amountA * rB) / rA + 1n : 0n;
  const share =
    amountA > 0n && rA > 0n ? (Number(amountA) / (Number(rA) + Number(amountA))) * 100 : 0;

  const needs = (k: TokenKey, amount: bigint) => amount > 0n && (user.allowances[k] ?? 0n) < amount;
  const short = amountA > (user.balances[pool.a] ?? 0n) || amountB > (user.balances[pool.b] ?? 0n);

  async function approve(k: TokenKey) {
    await send(`Approve ${tokenByKey(k).symbol}`, {
      address: tokenByKey(k).address,
      abi: tokenAbi,
      functionName: "approve",
      args: [ROUTER, maxUint256],
    });
  }

  async function add() {
    if (!user.address) return;
    const ok = await send(`Add ${fmtAmount(amountA)} ${a.symbol} + ${fmtAmount(amountB)} ${b.symbol}`, {
      address: ROUTER,
      abi: routerAbi,
      functionName: "addLiquidity",
      args: [a.address, b.address, amountA, amountB, withSlippage(amountA), withSlippage(amountB), user.address, deadline()],
    });
    if (ok) setInput("");
  }

  return (
    <div className="pool-panel">
      <div className="field-label">
        <span>{a.symbol} amount</span>
        <span>
          Balance: {fmtAmount(user.balances[pool.a])}{" "}
          <button
            className="link-btn"
            onClick={() => {
              const balA = user.balances[pool.a] ?? 0n;
              const balB = user.balances[pool.b] ?? 0n;
              // Max that both balances allow at the pool ratio.
              const maxA = rB > 0n ? (balB * rA) / rB : balA;
              setInput(formatEther(balA < maxA ? balA : maxA));
            }}
          >
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
          aria-label={`${a.symbol} amount to add`}
        />
      </div>
      <div className="details">
        <div className="kv">
          <span>{b.symbol} needed (pool ratio)</span>
          <span>{fmtAmount(amountB)}</span>
        </div>
        <div className="kv">
          <span>Your share of the pool after</span>
          <span>{share.toLocaleString("en-US", { maximumFractionDigits: 4 })}%</span>
        </div>
      </div>
      {!isConnected ? (
        <button className="btn" disabled>
          Connect a wallet first
        </button>
      ) : short ? (
        <button className="btn" disabled>
          Not enough {amountA > (user.balances[pool.a] ?? 0n) ? a.symbol : b.symbol}
        </button>
      ) : needs(pool.a, amountA) ? (
        <button className="btn" disabled={busy} onClick={() => approve(pool.a)}>
          Approve {a.symbol}
        </button>
      ) : needs(pool.b, amountB) ? (
        <button className="btn" disabled={busy} onClick={() => approve(pool.b)}>
          Approve {b.symbol}
        </button>
      ) : (
        <button className="btn" disabled={busy || amountA === 0n} onClick={add}>
          {amountA === 0n ? "Enter an amount" : "Add liquidity"}
        </button>
      )}
    </div>
  );
}

function RemoveLiquidity({ pool, user }: { pool: PoolState; user: UserState }) {
  const { send, busy } = useTx();
  const [pct, setPct] = useState(100);
  const a = tokenByKey(pool.a);
  const b = tokenByKey(pool.b);
  const lp = user.lpBalances[pool.key] ?? 0n;
  const liquidity = (lp * BigInt(pct)) / 100n;
  const outA = pool.totalSupply > 0n ? (liquidity * pool.reserves[pool.a]) / pool.totalSupply : 0n;
  const outB = pool.totalSupply > 0n ? (liquidity * pool.reserves[pool.b]) / pool.totalSupply : 0n;
  const needsApproval = liquidity > 0n && (user.lpRouterAllowances[pool.key] ?? 0n) < liquidity;

  async function approve() {
    await send("Approve LP tokens", {
      address: pool.address,
      abi: pairAbi,
      functionName: "approve",
      args: [ROUTER, maxUint256],
    });
  }

  async function remove() {
    if (!user.address) return;
    await send(`Remove ${pct}% of ${poolLabel(pool)} liquidity`, {
      address: ROUTER,
      abi: routerAbi,
      functionName: "removeLiquidity",
      args: [a.address, b.address, liquidity, withSlippage(outA), withSlippage(outB), user.address, deadline()],
    });
  }

  return (
    <div className="pool-panel">
      <div className="field-label">
        <span>Amount to remove</span>
        <span>{fmtAmount(lp)} LP in wallet</span>
      </div>
      <div className="pct-row">
        {[25, 50, 75, 100].map((p) => (
          <button key={p} className={`chip ${pct === p ? "active" : ""}`} onClick={() => setPct(p)}>
            {p}%
          </button>
        ))}
      </div>
      <div className="details">
        <div className="kv">
          <span>You receive</span>
          <span>
            {fmtAmount(outA)} {a.symbol} + {fmtAmount(outB)} {b.symbol}
          </span>
        </div>
      </div>
      {needsApproval ? (
        <button className="btn" disabled={busy} onClick={approve}>
          Approve LP tokens
        </button>
      ) : (
        <button className="btn" disabled={busy || liquidity === 0n} onClick={remove}>
          Remove liquidity
        </button>
      )}
      <p className="hint">LP tokens staked in a farm must be withdrawn from the farm first.</p>
    </div>
  );
}
