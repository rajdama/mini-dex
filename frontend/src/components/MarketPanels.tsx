"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { explorerUrl, indexerUrl, tokenByAddress, tokenByKey } from "@/lib/config";
import { poolLabel, usdPrices, type PoolState } from "@/lib/amm";
import { fmtAmount, fmtUsd, shortAddress } from "@/lib/format";
import type { DexState } from "@/hooks/useDex";

type Candle = { time: number; open: number; high: number; low: number; close: number };
type SwapItem = {
  pair: string;
  trader: string;
  amount0In: string;
  amount1In: string;
  amount0Out: string;
  amount1Out: string;
  txHash: string;
  timestamp: number;
};
type ArbItem = { caller: string; token: string; amountIn: string; profit: string; txHash: string; timestamp: number };
type PairStats = { address: string; volume0_24h: string; volume1_24h: string; swaps24h: number };

function useIndexer<T>(key: string, path: string) {
  return useQuery({
    queryKey: ["indexer", key],
    queryFn: async () => {
      const res = await fetch(`${indexerUrl}${path}`);
      if (!res.ok) throw new Error(`Indexer returned ${res.status}`);
      return (await res.json()) as T;
    },
    enabled: indexerUrl !== "",
    refetchInterval: 10_000,
  });
}

function timeAgo(ts: number): string {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

export function MarketPanels({ dex }: { dex: DexState }) {
  const [poolKey, setPoolKey] = useState("ETHUSD");
  const pool = dex.pools.find((p) => p.key === poolKey) ?? dex.pools[0];
  const swaps = useIndexer<{ items: SwapItem[] }>("swaps", "/api/swaps?limit=10");
  const arbs = useIndexer<{ items: ArbItem[] }>("arbs", "/api/arbitrage?limit=5");
  const pairStats = useIndexer<{ items: PairStats[] }>("pairs", "/api/pairs");

  if (indexerUrl === "" || !pool) return null;
  const prices = usdPrices(dex.pools);

  // 24h volume in USD across all pools, valuing each side at current prices.
  const volume24h = (pairStats.data?.items ?? []).reduce((sum, s) => {
    const p = dex.pools.find((x) => x.address.toLowerCase() === s.address.toLowerCase());
    if (!p) return sum;
    const t1 = p.token0 === p.a ? p.b : p.a;
    // Each swap moves value in on one side and out on the other; count the input side once.
    return sum + (Number(BigInt(s.volume0_24h)) / 1e18) * prices[p.token0] + (Number(BigInt(s.volume1_24h)) / 1e18) * prices[t1];
  }, 0);
  const swaps24h = (pairStats.data?.items ?? []).reduce((s, x) => s + x.swaps24h, 0);

  return (
    <div className="stack">
      <div className="card">
        <div className="card-head">
          <h2>Price</h2>
          <div className="chips">
            {dex.pools.map((p) => (
              <button key={p.key} className={`chip ${p.key === pool.key ? "active" : ""}`} onClick={() => setPoolKey(p.key)}>
                {poolLabel(p)}
              </button>
            ))}
          </div>
        </div>
        <PriceChart pool={pool} />
        <div className="kv" style={{ marginTop: 8 }}>
          <span>24h volume (all pools)</span>
          <span>
            {fmtUsd(volume24h)} · {swaps24h} swaps
          </span>
        </div>
      </div>

      <div className="card">
        <h2>Recent trades</h2>
        {(swaps.data?.items.length ?? 0) === 0 ? (
          <p className="empty">No trades yet.</p>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <tbody>
                {swaps.data!.items.map((s) => (
                  <SwapRow key={`${s.txHash}-${s.pair}`} s={s} pools={dex.pools} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <div className="card">
        <h2>Arbitrage bot</h2>
        <p className="hint" style={{ marginTop: -8 }}>
          When pools disagree on a price, the bot trades a loop across them in one transaction, with no capital, and
          pockets the difference. That pushes prices back in line.
        </p>
        {(arbs.data?.items.length ?? 0) === 0 ? (
          <p className="empty">No arbitrage yet: prices are in line.</p>
        ) : (
          <table className="table">
            <tbody>
              {arbs.data!.items.map((a) => {
                const t = tokenByAddress(a.token);
                return (
                  <tr key={a.txHash}>
                    <td>
                      <span className="pill good">+{fmtAmount(BigInt(a.profit))} {t?.symbol}</span>
                    </td>
                    <td>
                      traded {fmtAmount(BigInt(a.amountIn))} {t?.symbol}
                    </td>
                    <td className="mono">{shortAddress(a.caller)}</td>
                    <td>
                      <a href={`${explorerUrl}/tx/${a.txHash}`} target="_blank" rel="noreferrer">
                        {timeAgo(a.timestamp)}
                      </a>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

function SwapRow({ s, pools }: { s: SwapItem; pools: PoolState[] }) {
  const pool = pools.find((p) => p.address.toLowerCase() === s.pair.toLowerCase());
  if (!pool) return null;
  const t0 = tokenByKey(pool.token0);
  const t1 = tokenByKey(pool.token0 === pool.a ? pool.b : pool.a);
  const sold0 = BigInt(s.amount0In) > 0n;
  const [inTok, inAmt, outTok, outAmt] = sold0
    ? [t0, BigInt(s.amount0In), t1, BigInt(s.amount1Out)]
    : [t1, BigInt(s.amount1In), t0, BigInt(s.amount0Out)];
  return (
    <tr>
      <td>
        {fmtAmount(inAmt)} {inTok.symbol}
      </td>
      <td>
        → {fmtAmount(outAmt)} {outTok.symbol}
      </td>
      <td className="mono">{shortAddress(s.trader)}</td>
      <td>
        <a href={`${explorerUrl}/tx/${s.txHash}`} target="_blank" rel="noreferrer">
          {timeAgo(s.timestamp)}
        </a>
      </td>
    </tr>
  );
}

/** Hourly candlesticks of the pool price, drawn as SVG. */
function PriceChart({ pool }: { pool: PoolState }) {
  const candles = useIndexer<{ items: Candle[] }>(`candles-${pool.address}`, `/api/pairs/${pool.address}/candles?limit=48`);
  const items = candles.data?.items ?? [];
  // Candles are token1 per token0; show the price of `a` in `b`.
  const invert = pool.token0 !== pool.a;
  const data = items.map((c) =>
    invert
      ? { time: c.time, open: 1 / c.open, close: 1 / c.close, high: 1 / c.low, low: 1 / c.high }
      : { time: c.time, open: c.open, close: c.close, high: c.high, low: c.low },
  );
  const current = Number(pool.reserves[pool.b]) / Number(pool.reserves[pool.a]);

  if (data.length < 2) {
    return (
      <div>
        <div className="big-number">{current.toLocaleString("en-US", { maximumSignificantDigits: 6 })}</div>
        <p className="empty">Not enough trading history for a chart yet.</p>
      </div>
    );
  }

  const W = 600;
  const H = 220;
  const pad = 8;
  const lo = Math.min(...data.map((d) => d.low));
  const hi = Math.max(...data.map((d) => d.high));
  const range = hi - lo || hi * 0.01 || 1;
  const y = (v: number) => pad + (1 - (v - lo) / range) * (H - 2 * pad);
  const step = W / data.length;
  const first = data[0].open;
  const change = ((current - first) / first) * 100;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
        <div className="big-number">{current.toLocaleString("en-US", { maximumSignificantDigits: 6 })}</div>
        <span className={change >= 0 ? "pill good" : "pill"} style={change < 0 ? { color: "var(--bad)" } : undefined}>
          {change >= 0 ? "+" : ""}
          {change.toFixed(2)}%
        </span>
        <span className="hint" style={{ margin: 0 }}>
          {tokenByKey(pool.b).symbol} per {tokenByKey(pool.a).symbol} · {data.length}h
        </span>
      </div>
      <svg className="chart-lg" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label="Price candles">
        {data.map((d, i) => {
          const up = d.close >= d.open;
          const x = i * step + step / 2;
          const bodyTop = y(Math.max(d.open, d.close));
          const bodyH = Math.max(1, Math.abs(y(d.open) - y(d.close)));
          return (
            <g key={d.time} className={up ? "candle-up" : "candle-down"}>
              <line x1={x} x2={x} y1={y(d.high)} y2={y(d.low)} strokeWidth={1} vectorEffect="non-scaling-stroke" />
              <rect x={x - step * 0.32} width={step * 0.64} y={bodyTop} height={bodyH} />
            </g>
          );
        })}
      </svg>
    </div>
  );
}
