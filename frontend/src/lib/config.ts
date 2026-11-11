import { isAddress, type Address } from "viem";
import { foundry, sepolia, type Chain } from "wagmi/chains";

const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID || sepolia.id);

export const chain: Chain = chainId === foundry.id ? foundry : sepolia;
export const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || undefined;
export const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "mini-dex-demo";
export const indexerUrl = (process.env.NEXT_PUBLIC_INDEXER_URL || "").replace(/\/$/, "");
export const explorerUrl = chain.blockExplorers?.default.url ?? "";

type RawDeployment = Record<string, string | number>;

function parseDeployment(): RawDeployment {
  try {
    return JSON.parse(process.env.NEXT_PUBLIC_DEPLOYMENT || "{}") as RawDeployment;
  } catch {
    return {};
  }
}

const raw = parseDeployment();

function addr(key: string): Address {
  const v = raw[key];
  return typeof v === "string" && isAddress(v) ? v : ("0x0000000000000000000000000000000000000000" as Address);
}

export const isConfigured = typeof raw.router === "string" && isAddress(raw.router);

export const ROUTER = addr("router");
export const FACTORY = addr("factory");
export const ARBITRAGE = addr("arbitrage");

export type TokenKey = "ETH" | "BTC" | "USD";

export type Token = {
  key: TokenKey;
  address: Address;
  symbol: string;
  name: string;
  color: string;
};

export const TOKENS: Token[] = [
  { key: "ETH", address: addr("tokenETH"), symbol: "mETH", name: "Mini Ether", color: "#8b9cff" },
  { key: "BTC", address: addr("tokenBTC"), symbol: "mBTC", name: "Mini Bitcoin", color: "#f7a440" },
  { key: "USD", address: addr("tokenUSD"), symbol: "mUSD", name: "Mini Dollar", color: "#3ecf8e" },
];

export const REWARD_TOKEN = { address: addr("tokenMDX"), symbol: "MDX" };

export type PoolConfig = {
  key: string;
  address: Address;
  farm: Address;
  a: TokenKey;
  b: TokenKey;
};

export const POOLS: PoolConfig[] = [
  { key: "ETHUSD", address: addr("pairETHUSD"), farm: addr("farmETHUSD"), a: "ETH", b: "USD" },
  { key: "BTCUSD", address: addr("pairBTCUSD"), farm: addr("farmBTCUSD"), a: "BTC", b: "USD" },
  { key: "ETHBTC", address: addr("pairETHBTC"), farm: addr("farmETHBTC"), a: "ETH", b: "BTC" },
];

export const tokenByKey = (key: TokenKey): Token => TOKENS.find((t) => t.key === key)!;
export const tokenByAddress = (a: string): Token | undefined =>
  TOKENS.find((t) => t.address.toLowerCase() === a.toLowerCase());

/** Mirrors StakingRewards.lockOption(). */
export const LOCK_OPTIONS = [
  { id: 0, label: "No lock", days: 0, multiplierBps: 10_000 },
  { id: 1, label: "30 days", days: 30, multiplierBps: 15_000 },
  { id: 2, label: "90 days", days: 90, multiplierBps: 20_000 },
  { id: 3, label: "1 year", days: 365, multiplierBps: 30_000 },
] as const;

export const SLIPPAGE_OPTIONS = [10, 50, 100]; // basis points: 0.1%, 0.5%, 1%
export const DEADLINE_SECONDS = 20 * 60;
