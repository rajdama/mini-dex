"use client";

import { useEffect } from "react";
import { useTx } from "@/hooks/useTx";
import { explorerUrl } from "@/lib/config";

const TITLES = {
  wallet: "Confirm in your wallet",
  confirming: "Waiting for confirmation…",
  success: "Done",
  error: "Transaction failed",
} as const;

export function TxToast() {
  const { state, dismiss } = useTx();

  useEffect(() => {
    if (state.status !== "success") return;
    const id = setTimeout(dismiss, 6000);
    return () => clearTimeout(id);
  }, [state.status, dismiss]);

  if (state.status === "idle") return null;

  return (
    <div className={`toast ${state.status}`} role="status" aria-live="polite">
      <div className="toast-title">
        <span>{TITLES[state.status]}</span>
        {(state.status === "success" || state.status === "error") && (
          <button className="link-btn" onClick={dismiss} aria-label="Dismiss">
            ✕
          </button>
        )}
      </div>
      <p>
        {state.label}
        {state.error && <>: {state.error}</>}
      </p>
      {state.hash && explorerUrl && (
        <p>
          <a href={`${explorerUrl}/tx/${state.hash}`} target="_blank" rel="noreferrer">
            View on explorer ↗
          </a>
        </p>
      )}
    </div>
  );
}
