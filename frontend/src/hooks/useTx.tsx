"use client";

import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { BaseError, type Hash } from "viem";

type TxStatus = "idle" | "wallet" | "confirming" | "success" | "error";

export type TxState = {
  status: TxStatus;
  label?: string;
  hash?: Hash;
  error?: string;
};

type WriteRequest = Parameters<ReturnType<typeof useWriteContract>["writeContractAsync"]>[0];

type TxContextValue = {
  state: TxState;
  busy: boolean;
  send: (label: string, request: WriteRequest) => Promise<boolean>;
  dismiss: () => void;
};

const TxContext = createContext<TxContextValue | null>(null);

/** Sends transactions one at a time, tracks their status, and refreshes all reads on success. */
export function TxProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<TxState>({ status: "idle" });
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const queryClient = useQueryClient();
  const { address } = useAccount();

  const send = useCallback(
    async (label: string, request: WriteRequest) => {
      setState({ status: "wallet", label });
      try {
        // Estimate gas ourselves and add a 30% margin. Gas use can change between estimation and
        // inclusion: e.g. a pair's price oracle only updates on the first trade in a new block, which
        // the estimate may not include. Estimating first also surfaces revert reasons before the
        // wallet prompt, instead of after paying for a failed transaction.
        const estimate = await publicClient!.estimateContractGas({
          ...(request as Parameters<NonNullable<typeof publicClient>["estimateContractGas"]>[0]),
          account: address,
        });
        const hash = await writeContractAsync({ ...request, gas: (estimate * 13n) / 10n });
        setState({ status: "confirming", label, hash });
        const receipt = await publicClient!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Transaction reverted");
        setState({ status: "success", label, hash });
        await queryClient.invalidateQueries();
        return true;
      } catch (e) {
        const message = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
        setState((s) => ({ status: "error", label, hash: s.hash, error: message }));
        return false;
      }
    },
    [writeContractAsync, publicClient, queryClient, address],
  );

  const dismiss = useCallback(() => setState({ status: "idle" }), []);
  const busy = state.status === "wallet" || state.status === "confirming";

  return <TxContext.Provider value={{ state, busy, send, dismiss }}>{children}</TxContext.Provider>;
}

export function useTx() {
  const ctx = useContext(TxContext);
  if (!ctx) throw new Error("useTx must be used inside TxProvider");
  return ctx;
}
