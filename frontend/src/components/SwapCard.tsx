"use client";

import { useState, type ReactNode } from "react";
import { formatEther, maxUint256, parseEther } from "viem";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { routerAbi, tokenAbi } from "@/lib/abi";
import { bestRoute } from "@/lib/amm";
import { DEADLINE_SECONDS, ROUTER, SLIPPAGE_OPTIONS, TOKENS, tokenByKey, type TokenKey } from "@/lib/config";
import { fmtAmount } from "@/lib/format";
import type { DexState, UserState } from "@/hooks/useDex";
import { useTx } from "@/hooks/useTx";

export function parseAmount(input: string): bigint {
  try {
    return input.trim() === "" ? 0n : parseEther(input.trim());
  } catch {
    return 0n;
  }
}

export function TokenSelect({ value, onChange, label }: { value: TokenKey; onChange: (k: TokenKey) => void; label: string }) {
  return (
    <select className="token-select" value={value} onChange={(e) => onChange(e.target.value as TokenKey)} aria-label={label}>
      {TOKENS.map((t) => (
        <option key={t.key} value={t.key}>
          {t.symbol}
        </option>
      ))}
    </select>
  );
}

export function SwapCard({ dex, user }: { dex: DexState; user: UserState }) {
  const { isConnected } = useAccount();
  const { send, busy } = useTx();
  const [from, setFrom] = useState<TokenKey>("ETH");
  const [to, setTo] = useState<TokenKey>("USD");
  const [input, setInput] = useState("");
  const [slippageBps, setSlippageBps] = useState(50);

  const amountIn = parseAmount(input);
  const route = bestRoute(dex.pools, from, to, amountIn);
  const minOut = route ? (route.amountOut * BigInt(10_000 - slippageBps)) / 10_000n : 0n;
  const balance = user.balances[from] ?? 0n;
  const tooMuch = amountIn > balance;
  const needsApproval = amountIn > 0n && (user.allowances[from] ?? 0n) < amountIn;

  const fromToken = tokenByKey(from);
  const toToken = tokenByKey(to);
  const midRate = route && amountIn > 0n ? Number(route.idealOut) / Number(amountIn) : undefined;
  const impact = route?.priceImpactPct ?? 0;
  const impactClass = impact > 10 ? "impact-bad" : impact > 3 ? "impact-warn" : "";

  function setFromToken(k: TokenKey) {
    if (k === to) setTo(from);
    setFrom(k);
  }
  function setToToken(k: TokenKey) {
    if (k === from) setFrom(to);
    setTo(k);
  }
  function flip() {
    setFrom(to);
    setTo(from);
    setInput(route ? formatEther(route.amountOut) : "");
  }

  async function onApprove() {
    await send(`Approve ${fromToken.symbol}`, {
      address: fromToken.address,
      abi: tokenAbi,
      functionName: "approve",
      args: [ROUTER, maxUint256],
    });
  }

  async function onSwap() {
    if (!route || !user.address) return;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS);
    const ok = await send(`Swap ${fmtAmount(amountIn)} ${fromToken.symbol} for ${toToken.symbol}`, {
      address: ROUTER,
      abi: routerAbi,
      functionName: "swapExactTokensForTokens",
      args: [amountIn, minOut, route.path.map((k) => tokenByKey(k).address), user.address, deadline],
    });
    if (ok) setInput("");
  }

  let action: ReactNode;
  if (!isConnected) {
    action = (
      <ConnectButton.Custom>
        {({ openConnectModal }) => (
          <button className="btn" onClick={openConnectModal}>
            Connect wallet
          </button>
        )}
      </ConnectButton.Custom>
    );
  } else if (amountIn === 0n) {
    action = <button className="btn" disabled>Enter an amount</button>;
  } else if (tooMuch) {
    action = <button className="btn" disabled>Not enough {fromToken.symbol}</button>;
  } else if (!route) {
    action = <button className="btn" disabled>Not enough liquidity</button>;
  } else if (needsApproval) {
    action = (
      <button className="btn" onClick={onApprove} disabled={busy}>
        Approve {fromToken.symbol}
      </button>
    );
  } else {
    action = (
      <button className="btn" onClick={onSwap} disabled={busy}>
        {impact > 10 ? "Swap anyway (high price impact)" : "Swap"}
      </button>
    );
  }

  return (
    <div className="card">
      <div className="card-head">
        <h2>Swap</h2>
        <div className="chips" role="radiogroup" aria-label="Slippage tolerance">
          <span className="hint" style={{ margin: 0 }}>
            Slippage
          </span>
          {SLIPPAGE_OPTIONS.map((bps) => (
            <button
              key={bps}
              role="radio"
              aria-checked={slippageBps === bps}
              className={`chip ${slippageBps === bps ? "active" : ""}`}
              onClick={() => setSlippageBps(bps)}
            >
              {bps / 100}%
            </button>
          ))}
        </div>
      </div>

      <div className="token-box">
        <div className="token-meta">
          <span>You pay</span>
          <span>
            Balance: {fmtAmount(balance)}{" "}
            <button className="link-btn" onClick={() => setInput(balance > 0n ? formatEther(balance) : "")}>
              Max
            </button>
          </span>
        </div>
        <div className="token-row">
          <input
            inputMode="decimal"
            placeholder="0.0"
            value={input}
            onChange={(e) => setInput(e.target.value.replace(/[^0-9.]/g, ""))}
            aria-label="Amount to pay"
          />
          <TokenSelect value={from} onChange={setFromToken} label="Token to pay" />
        </div>
      </div>

      <div className="flip">
        <button onClick={flip} aria-label="Switch tokens">
          ↓
        </button>
      </div>

      <div className="token-box">
        <div className="token-meta">
          <span>You receive</span>
          <span>Balance: {fmtAmount(user.balances[to])}</span>
        </div>
        <div className="token-row">
          <div className="out" aria-label="Amount to receive">
            {route ? fmtAmount(route.amountOut) : "0.0"}
          </div>
          <TokenSelect value={to} onChange={setToToken} label="Token to receive" />
        </div>
      </div>

      {route && midRate !== undefined && (
        <div className="details">
          <div className="kv">
            <span>Rate</span>
            <span>
              1 {fromToken.symbol} = {midRate.toLocaleString("en-US", { maximumSignificantDigits: 6 })} {toToken.symbol}
            </span>
          </div>
          <div className="kv">
            <span>Price impact</span>
            <span className={impactClass}>{impact < 0.01 ? "<0.01" : impact.toFixed(2)}%</span>
          </div>
          <div className="kv">
            <span>Minimum received</span>
            <span>
              {fmtAmount(minOut)} {toToken.symbol}
            </span>
          </div>
          <div className="kv">
            <span>Route</span>
            <span className="route">
              {route.path.map((k, i) => (
                <span key={k}>
                  {i > 0 && "→ "}
                  {tokenByKey(k).symbol}
                </span>
              ))}
            </span>
          </div>
          <div className="kv">
            <span>Fee</span>
            <span>{(0.3 * (route.path.length - 1)).toFixed(1)}% to liquidity providers</span>
          </div>
        </div>
      )}

      {action}
      <p className="hint">
        If the price moves more than {slippageBps / 100}% before your swap confirms, it reverts instead of filling at a
        worse price. This also protects against sandwich attacks.
      </p>
    </div>
  );
}
