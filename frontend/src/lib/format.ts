import { formatUnits } from "viem";

/** Formats an 18-decimal token amount for display, e.g. 1234.5678 -> "1,234.57". */
export function fmt(value: bigint | undefined, maxDecimals = 2): string {
  if (value === undefined) return "–";
  const n = Number(formatUnits(value, 18));
  if (n !== 0 && Math.abs(n) < 10 ** -maxDecimals) return `<${10 ** -maxDecimals}`;
  return n.toLocaleString("en-US", { maximumFractionDigits: maxDecimals });
}

export function fmtMultiplier(bps: number): string {
  return `${(bps / 10_000).toLocaleString("en-US", { maximumFractionDigits: 2 })}x`;
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** "3d 4h", "5h 12m", "2m 10s" or "now". */
export function fmtDuration(seconds: number): string {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export function fmtDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleDateString("en-US", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export function fmtPercent(value: number): string {
  if (!Number.isFinite(value)) return "–";
  if (value >= 10_000) return ">10,000%";
  return `${value.toLocaleString("en-US", { maximumFractionDigits: value < 10 ? 2 : 0 })}%`;
}

export function fmtUsd(value: number): string {
  if (!Number.isFinite(value)) return "–";
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: value < 100 ? 2 : 0 });
}

/** A token amount with sensible precision for its size. */
export function fmtAmount(value: bigint | undefined): string {
  if (value === undefined) return "–";
  const n = Number(value) / 1e18;
  if (n === 0) return "0";
  if (n < 0.0001) return "<0.0001";
  return n.toLocaleString("en-US", { maximumFractionDigits: n < 1 ? 6 : n < 1000 ? 4 : 2 });
}
