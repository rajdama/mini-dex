#!/usr/bin/env bash
# Seeds a local Anvil chain with ~48 hours of DEX activity ending at the real current time:
# hourly trades in every pool, a demo user who provides liquidity and farms, and a final
# "whale" dump that knocks prices out of line so the arbitrage bot has something to do.
#
# Usage (from the repo root):
#   anvil --timestamp $(( $(date +%s) - 48*3600 )) &
#   scripts/demo/seed.sh
set -euo pipefail

RPC=${RPC:-http://127.0.0.1:8545}
RANDOM=42 # deterministic "random" trades

# Anvil's well-known test accounts. Never use these keys on a real network.
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # deployer / token owner
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d # demo user (screenshots)
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a # traders
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
K4=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935

addr() { cast wallet address --private-key "$1"; }
send() { cast send --rpc-url "$RPC" "$@" >/dev/null; }
warp() { cast rpc --rpc-url "$RPC" evm_increaseTime "$1" >/dev/null; cast rpc --rpc-url "$RPC" evm_mine >/dev/null; }

cd "$(dirname "$0")/../../contracts"
PRIVATE_KEY=$K0 forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast >/dev/null
D=deployments/31337.json
ROUTER=$(jq -r .router $D)
ETH=$(jq -r .tokenETH $D)
BTC=$(jq -r .tokenBTC $D)
USD=$(jq -r .tokenUSD $D)
PAIR_ETHUSD=$(jq -r .pairETHUSD $D)
FARM_ETHUSD=$(jq -r .farmETHUSD $D)
echo "Router: $ROUTER"

# Fund the traders generously and the demo user modestly; everyone approves the router once.
fund() { # key eth btc usd
  local A; A=$(addr "$1")
  send $ETH "mint(address,uint256)" "$A" "$2" --private-key $K0
  send $BTC "mint(address,uint256)" "$A" "$3" --private-key $K0
  send $USD "mint(address,uint256)" "$A" "$4" --private-key $K0
  for T in $ETH $BTC $USD; do send $T "approve(address,uint256)" $ROUTER $MAX --private-key "$1"; done
}
fund $K1 25ether 1.2ether 75000ether
for K in $K2 $K3 $K4; do fund $K 5000ether 250ether 15000000ether; done

swap() { # key amountIn tokenIn tokenOut
  send $ROUTER "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)" \
    "$2" 0 "[$3,$4]" "$(addr $1)" 99999999999 --private-key "$1"
}
# Sets AMOUNT to a random amount between $1 and $2 tokens (two decimals), in wei.
# Runs in the current shell (not a subshell) so $RANDOM keeps advancing.
rnd() {
  local r=$RANDOM
  AMOUNT=$(cast to-wei "$(awk -v a="$1" -v b="$2" -v r="$r" 'BEGIN { printf "%.2f", a + (b - a) * r / 32767 }')")
}

# The demo user provides liquidity to ETH/USD and farms half of it with a 90-day lock.
A1=$(addr $K1)
send $ROUTER "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)" \
  $ETH $USD 10ether 30000ether 0 0 $A1 99999999999 --private-key $K1
LP=$(cast call --rpc-url "$RPC" $PAIR_ETHUSD "balanceOf(address)(uint256)" $A1 | awk '{print $1}')
send $PAIR_ETHUSD "approve(address,uint256)" $FARM_ETHUSD $MAX --private-key $K1
send $FARM_ETHUSD "stake(uint256,uint8)" "$(python3 -c "print($LP // 2)")" 2 --private-key $K1

# 46 hours of trading: each hour, one trade per pool in a random direction and size.
for hour in $(seq 1 46); do
  if (( RANDOM % 2 )); then rnd 0.2 4; swap $K2 $AMOUNT $ETH $USD; else rnd 600 12000; swap $K2 $AMOUNT $USD $ETH; fi
  if (( RANDOM % 2 )); then rnd 0.01 0.2; swap $K3 $AMOUNT $BTC $USD; else rnd 600 12000; swap $K3 $AMOUNT $USD $BTC; fi
  if (( RANDOM % 2 )); then rnd 0.2 4; swap $K4 $AMOUNT $ETH $BTC; else rnd 0.01 0.2; swap $K4 $AMOUNT $BTC $ETH; fi
  if (( hour == 20 )); then
    send $ROUTER "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)" \
      $BTC $USD 0.5ether 40000ether 0 0 "$(addr $K3)" 99999999999 --private-key $K3
  fi
  warp 3600
done

# A whale dumps ETH into ETH/USD: ETH is now cheap there compared to the other pools.
swap $K2 25ether $ETH $USD
cast rpc --rpc-url "$RPC" evm_setNextBlockTimestamp "$(date +%s)" >/dev/null
cast rpc --rpc-url "$RPC" evm_mine >/dev/null

echo "Seeded. Demo user: $A1"
