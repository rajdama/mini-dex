"use client";

import { useAccount } from "wagmi";
import { tokenAbi } from "@/lib/abi";
import { TOKENS } from "@/lib/config";
import { fmtAmount, fmtDuration } from "@/lib/format";
import type { UserState } from "@/hooks/useDex";
import { useNow } from "@/hooks/useNow";
import { useTx } from "@/hooks/useTx";

/** Buttons to claim free test tokens, once a day per token. */
export function Faucet({ user }: { user: UserState }) {
  const { isConnected } = useAccount();
  const { send, busy } = useTx();
  const now = useNow();
  if (!isConnected || !user.loaded) return null;

  return (
    <div className="faucet-bar">
      <span>Free test tokens:</span>
      {TOKENS.map((t) => {
        const readyAt = user.faucetReadyAt[t.key] ?? 0;
        const ready = now >= readyAt;
        return (
          <button
            key={t.key}
            className="chip"
            disabled={busy || !ready}
            title={ready ? undefined : `Available again in ${fmtDuration(readyAt - now)}`}
            onClick={() => send(`Get ${t.symbol}`, { address: t.address, abi: tokenAbi, functionName: "faucet" })}
          >
            <span className="dot" style={{ background: t.color }} />
            {ready ? `+${fmtAmount(user.faucetAmounts[t.key])} ${t.symbol}` : `${t.symbol} in ${fmtDuration(readyAt - now)}`}
          </button>
        );
      })}
    </div>
  );
}
