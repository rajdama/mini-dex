import { existsSync, readFileSync } from "node:fs";

// Contract addresses come from the deploy script's output (contracts/deployments/<chainId>.json),
// so a redeploy only needs a rebuild. NEXT_PUBLIC_DEPLOYMENT (a JSON string) overrides it.
const chainId = process.env.NEXT_PUBLIC_CHAIN_ID || "11155111";
const file = new URL(`../contracts/deployments/${chainId}.json`, import.meta.url);
const deployment = process.env.NEXT_PUBLIC_DEPLOYMENT || (existsSync(file) ? readFileSync(file, "utf8") : "{}");

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  eslint: { ignoreDuringBuilds: true },
  env: { NEXT_PUBLIC_DEPLOYMENT: deployment },
  webpack: (config) => {
    // Optional dependencies of WalletConnect that aren't needed in the browser.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};

export default nextConfig;
