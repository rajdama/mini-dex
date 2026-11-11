// Takes screenshots of the running DEX with a test wallet connected to a local Anvil chain.
// Usage: node screenshots.mjs <output-dir>
// Expects the app on http://127.0.0.1:3000, Anvil on :8545 and the indexer on :8080.
import { chromium } from "playwright";
import { mkdirSync } from "node:fs";

const OUT = process.argv[2] ?? "screenshots";
const APP = "http://127.0.0.1:3000";
// Anvil test account #1 (unlocked on Anvil, so the "wallet" can send transactions without signing).
const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

mkdirSync(OUT, { recursive: true });

// A minimal EIP-1193 wallet that forwards to Anvil. Injected before the app loads.
const injectWallet = ([account]) => {
  let id = 0;
  const rpc = async (method, params) => {
    const res = await fetch("http://127.0.0.1:8545", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: params ?? [] }),
    });
    const json = await res.json();
    if (json.error) {
      const err = new Error(json.error.message);
      err.code = json.error.code;
      err.data = json.error.data;
      throw err;
    }
    return json.result;
  };
  const provider = {
    isMetaMask: true,
    async request({ method, params }) {
      switch (method) {
        case "eth_requestAccounts":
        case "eth_accounts":
          return [account];
        case "eth_chainId":
          return "0x7a69";
        case "net_version":
          return "31337";
        case "wallet_requestPermissions":
        case "wallet_getPermissions":
          return [{ parentCapability: "eth_accounts" }];
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain":
        case "wallet_revokePermissions":
          return null;
        default:
          return rpc(method, params);
      }
    },
    on() {
      return provider;
    },
    removeListener() {
      return provider;
    },
  };
  window.ethereum = provider;
};

async function newPage(browser, viewport) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 2, colorScheme: "dark" });
  await context.addInitScript(injectWallet, [ACCOUNT]);
  const page = await context.newPage();
  page.on("pageerror", (e) => console.log("page error:", e.message));
  return page;
}

/** The injected wallet usually auto-connects; open the modal only if it didn't. */
async function ensureConnected(page) {
  const connected = page.getByText("0x70", { exact: false }).first();
  const connectButton = page.getByRole("button", { name: "Connect Wallet" }).first();
  await Promise.race([connected.waitFor(), connectButton.waitFor()]);
  if (!(await connected.isVisible())) {
    await connectButton.click();
    const dialog = page.getByRole("dialog");
    for (let attempt = 1; attempt <= 8; attempt++) {
      await page.waitForTimeout(1000);
      if (await connected.isVisible()) break;
      await dialog.getByRole("button", { name: /MetaMask/ }).first().click({ force: true, timeout: 3000 }).catch(() => {});
    }
    await connected.waitFor();
  }
  await page.getByText("Free test tokens").waitFor();
  await page.waitForTimeout(2500);
}

async function waitForTx(page) {
  await page.locator(".toast.success, .toast.error").waitFor({ timeout: 60_000 });
  if (await page.locator(".toast.error").count()) {
    throw new Error(`Transaction failed: ${await page.locator(".toast").innerText()}`);
  }
}

async function openTab(page, name) {
  await page.getByRole("button", { name, exact: true }).click();
  await page.waitForTimeout(1500);
}

const browser = await chromium.launch();
let current;
try {
  const page = await newPage(browser, { width: 1360, height: 900 });
  current = page;
  await page.goto(APP);
  await ensureConnected(page);
  await page.getByText("Arbitrage bot").waitFor();
  await page.waitForTimeout(4000); // let the indexer panels load

  // 1. Swap screen with a quote.
  await page.getByLabel("Amount to pay").fill("2");
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${OUT}/01-swap.png`, fullPage: true });

  // 2. Execute the swap: approve if needed, then swap.
  const approve = page.getByRole("button", { name: /^Approve mETH$/ });
  if (await approve.isVisible()) {
    await approve.click();
    await waitForTx(page);
    await page.waitForTimeout(1500);
  }
  await page.getByRole("button", { name: /^Swap/ }).last().click();
  await waitForTx(page);
  await page.waitForTimeout(3000);
  await page.screenshot({ path: `${OUT}/02-swap-done.png` });

  // 3. Multi-hop quote: BTC -> ETH routes through USD when that's better.
  await page.getByLabel("Token to pay").selectOption("BTC");
  await page.getByLabel("Token to receive").selectOption("ETH");
  await page.getByLabel("Amount to pay").fill("0.3");
  await page.waitForTimeout(800);
  await page.locator(".swap-wrap > .card").first().screenshot({ path: `${OUT}/03-swap-quote.png` });

  // 4. Pools, with the add-liquidity panel open.
  await openTab(page, "Pools");
  await page.getByRole("button", { name: "Add", exact: true }).first().click();
  await page.getByLabel(/amount to add/).fill("1");
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${OUT}/04-pools.png`, fullPage: true });

  // 5. Farms.
  await openTab(page, "Farms");
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${OUT}/05-farms.png`, fullPage: true });
  await page.context().close();

  // 6. Mobile swap screen.
  const mobile = await newPage(browser, { width: 390, height: 844 });
  current = mobile;
  await mobile.goto(APP);
  await ensureConnected(mobile);
  await mobile.waitForTimeout(3000);
  await mobile.getByLabel("Amount to pay").fill("1");
  await mobile.waitForTimeout(800);
  await mobile.screenshot({ path: `${OUT}/06-mobile.png`, fullPage: true });
  await mobile.context().close();

  console.log("Screenshots saved to", OUT);
} catch (e) {
  if (current) await current.screenshot({ path: `${OUT}/debug-failure.png`, fullPage: true }).catch(() => {});
  throw e;
} finally {
  await browser.close();
}
