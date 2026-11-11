"use client";

import { useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { chain, explorerUrl, isConfigured, ROUTER } from "@/lib/config";
import { useDexState, useUserState } from "@/hooks/useDex";
import { SwapCard } from "./SwapCard";
import { PoolsView } from "./PoolsView";
import { FarmsView } from "./FarmsView";
import { MarketPanels } from "./MarketPanels";
import { Faucet } from "./Faucet";
import { TxToast } from "./TxToast";

type Tab = "swap" | "pools" | "farms";

export default function App() {
  const [tab, setTab] = useState<Tab>("swap");
  const dex = useDexState();
  const user = useUserState();

  return (
    <div className="container">
      <header className="header">
        <div className="brand">
          <div className="logo" aria-hidden />
          Mini DEX
          <span className="badge">{chain.id === 31337 ? "Local chain" : `${chain.name} testnet`}</span>
        </div>
        <nav className="tabs" aria-label="Sections">
          {(["swap", "pools", "farms"] as Tab[]).map((t) => (
            <button key={t} className={`tab ${tab === t ? "active" : ""}`} onClick={() => setTab(t)}>
              {t[0].toUpperCase() + t.slice(1)}
            </button>
          ))}
        </nav>
        <div className="header-right">
          <ConnectButton chainStatus="icon" showBalance={false} />
        </div>
      </header>

      {!isConfigured ? (
        <div className="notice" style={{ marginTop: 24 }}>
          <strong>Contracts not configured.</strong> Deploy the contracts (see the README) so that{" "}
          <code>contracts/deployments/{chain.id}.json</code> exists, then rebuild.
        </div>
      ) : dex.error ? (
        <div className="notice" style={{ marginTop: 24 }}>
          <strong>Can&apos;t reach the contracts.</strong> Check that they&apos;re deployed on {chain.name} and the RPC
          URL works.
        </div>
      ) : !dex.loaded ? (
        <p className="empty">Loading pools…</p>
      ) : (
        <>
          <Faucet user={user} />
          {tab === "swap" && (
            <div className="swap-wrap">
              <SwapCard dex={dex} user={user} />
              <MarketPanels dex={dex} />
            </div>
          )}
          {tab === "pools" && <PoolsView dex={dex} user={user} />}
          {tab === "farms" && <FarmsView dex={dex} user={user} />}
        </>
      )}

      <footer className="footer">
        Open source on{" "}
        <a href="https://github.com/rajdama/mini-dex" target="_blank" rel="noreferrer">
          GitHub
        </a>
        {isConfigured && explorerUrl && (
          <>
            {" · "}
            <a href={`${explorerUrl}/address/${ROUTER}#code`} target="_blank" rel="noreferrer">
              Router contract
            </a>
          </>
        )}
        {" · Testnet demo with free test tokens, not audited by a third party."}
      </footer>

      <TxToast />
    </div>
  );
}
