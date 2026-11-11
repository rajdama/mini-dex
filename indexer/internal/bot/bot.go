// Package bot finds and executes cycle arbitrage across Mini DEX pools.
//
// When three pools disagree on prices (say ETH is cheap in ETH/USD but not in ETH/BTC and
// BTC/USD), trading around the loop USD -> ETH -> BTC -> USD returns more than it started with.
// The bot reads all reserves, finds the most profitable loop and trade size, and executes it
// through the FlashArbitrage contract, which needs no capital: it flash-borrows the first hop.
package bot

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

// Client is the subset of an Ethereum RPC client the bot needs.
type Client interface {
	CallContract(ctx context.Context, msg ethereum.CallMsg, block *big.Int) ([]byte, error)
	ChainID(ctx context.Context) (*big.Int, error)
	PendingNonceAt(ctx context.Context, account common.Address) (uint64, error)
	SuggestGasTipCap(ctx context.Context) (*big.Int, error)
	HeaderByNumber(ctx context.Context, number *big.Int) (*types.Header, error)
	EstimateGas(ctx context.Context, msg ethereum.CallMsg) (uint64, error)
	SendTransaction(ctx context.Context, tx *types.Transaction) error
	TransactionReceipt(ctx context.Context, txHash common.Hash) (*types.Receipt, error)
}

// PairSource lists the known pools (the indexer's store in production).
type PairSource interface {
	Pairs(ctx context.Context) ([]store.Pair, error)
}

// Pool is a pair with its current reserves.
type Pool struct {
	Address            common.Address
	Token0, Token1     common.Address
	Reserve0, Reserve1 *big.Int
}

// Opportunity is a profitable loop and the trade size that maximizes its profit.
type Opportunity struct {
	Path     []common.Address // starts and ends with the same token
	AmountIn *big.Int
	Out      *big.Int
	Profit   *big.Int
}

// ProfitBps is the profit as basis points of the amount traded.
func (o Opportunity) ProfitBps() int64 {
	if o.AmountIn.Sign() == 0 {
		return 0
	}
	return new(big.Int).Div(new(big.Int).Mul(o.Profit, big.NewInt(10_000)), o.AmountIn).Int64()
}

// ---------------------------------------------------------------------------
// Pure math (mirrors DexLibrary)
// ---------------------------------------------------------------------------

var (
	feeMul = big.NewInt(9_970)
	feeDen = big.NewInt(10_000)
)

// GetAmountOut: out = in*0.997*rOut / (rIn + in*0.997), rounded down, like the contract.
func GetAmountOut(amountIn, reserveIn, reserveOut *big.Int) *big.Int {
	if amountIn.Sign() <= 0 || reserveIn.Sign() <= 0 || reserveOut.Sign() <= 0 {
		return new(big.Int)
	}
	inWithFee := new(big.Int).Mul(amountIn, feeMul)
	num := new(big.Int).Mul(inWithFee, reserveOut)
	den := new(big.Int).Add(new(big.Int).Mul(reserveIn, feeDen), inWithFee)
	return num.Div(num, den)
}

type edge struct{ rIn, rOut *big.Int }

func edgeFor(pools []Pool, from, to common.Address) (edge, bool) {
	for _, p := range pools {
		switch {
		case p.Token0 == from && p.Token1 == to:
			return edge{p.Reserve0, p.Reserve1}, true
		case p.Token1 == from && p.Token0 == to:
			return edge{p.Reserve1, p.Reserve0}, true
		}
	}
	return edge{}, false
}

func cycleOut(edges []edge, amountIn *big.Int) *big.Int {
	out := amountIn
	for _, e := range edges {
		out = GetAmountOut(out, e.rIn, e.rOut)
	}
	return out
}

// bestSize finds the trade size with the highest profit. Profit rises then falls as the trade
// grows (each unit moves the price further against you), so a ternary search converges on it.
func bestSize(edges []edge) (amountIn, out *big.Int) {
	lo := big.NewInt(1)
	hi := new(big.Int).Div(edges[0].rIn, big.NewInt(2)) // never more than half the first pool
	profit := func(x *big.Int) *big.Int { return new(big.Int).Sub(cycleOut(edges, x), x) }
	three := big.NewInt(3)
	for i := 0; i < 200 && new(big.Int).Sub(hi, lo).Cmp(three) > 0; i++ {
		third := new(big.Int).Div(new(big.Int).Sub(hi, lo), three)
		m1 := new(big.Int).Add(lo, third)
		m2 := new(big.Int).Sub(hi, third)
		if profit(m1).Cmp(profit(m2)) < 0 {
			lo = m1
		} else {
			hi = m2
		}
	}
	best, bestProfit := lo, profit(lo)
	for x := new(big.Int).Add(lo, big.NewInt(1)); x.Cmp(hi) <= 0; x = new(big.Int).Add(x, big.NewInt(1)) {
		if p := profit(x); p.Cmp(bestProfit) > 0 {
			best, bestProfit = x, p
		}
	}
	return best, cycleOut(edges, best)
}

// FindBest checks every three-pool loop in both directions and returns the most profitable
// one (by profit relative to size), or ok=false if none clears minProfitBps.
func FindBest(pools []Pool, minProfitBps int64) (best Opportunity, ok bool) {
	tokens := map[common.Address]bool{}
	for _, p := range pools {
		tokens[p.Token0], tokens[p.Token1] = true, true
	}
	list := make([]common.Address, 0, len(tokens))
	for t := range tokens {
		list = append(list, t)
	}
	for _, a := range list {
		for _, b := range list {
			for _, c := range list {
				if a == b || b == c || a == c {
					continue
				}
				e1, ok1 := edgeFor(pools, a, b)
				e2, ok2 := edgeFor(pools, b, c)
				e3, ok3 := edgeFor(pools, c, a)
				if !ok1 || !ok2 || !ok3 {
					continue
				}
				amountIn, out := bestSize([]edge{e1, e2, e3})
				profit := new(big.Int).Sub(out, amountIn)
				if profit.Sign() <= 0 {
					continue
				}
				opp := Opportunity{Path: []common.Address{a, b, c, a}, AmountIn: amountIn, Out: out, Profit: profit}
				if opp.ProfitBps() < minProfitBps {
					continue
				}
				if !ok || opp.ProfitBps() > best.ProfitBps() {
					best, ok = opp, true
				}
			}
		}
	}
	return best, ok
}

// ---------------------------------------------------------------------------
// Bot
// ---------------------------------------------------------------------------

type Bot struct {
	client       Client
	pairs        PairSource
	abi          abi.ABI
	arbitrage    common.Address
	key          *ecdsa.PrivateKey
	from         common.Address
	minProfitBps int64
	interval     time.Duration
	log          *slog.Logger
}

func New(client Client, pairs PairSource, dexABI abi.ABI, arbitrage common.Address, hexKey string,
	minProfitBps uint64, interval time.Duration, log *slog.Logger) (*Bot, error) {
	key, err := crypto.HexToECDSA(trim0x(hexKey))
	if err != nil {
		return nil, fmt.Errorf("invalid BOT_PRIVATE_KEY: %w", err)
	}
	return &Bot{
		client: client, pairs: pairs, abi: dexABI, arbitrage: arbitrage, key: key,
		from: crypto.PubkeyToAddress(key.PublicKey), minProfitBps: int64(minProfitBps), interval: interval, log: log,
	}, nil
}

func (b *Bot) Address() common.Address { return b.from }

func (b *Bot) Run(ctx context.Context) error {
	ticker := time.NewTicker(b.interval)
	defer ticker.Stop()
	for {
		if opp, sent, err := b.Tick(ctx); err != nil {
			b.log.Error("bot tick failed", "err", err)
		} else if sent {
			b.log.Info("arbitrage executed", "profit", opp.Profit.String(), "amountIn", opp.AmountIn.String(), "bps", opp.ProfitBps())
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// LoadPools reads current reserves for every known pair.
func (b *Bot) LoadPools(ctx context.Context) ([]Pool, error) {
	known, err := b.pairs.Pairs(ctx)
	if err != nil {
		return nil, err
	}
	data, err := b.abi.Pack("getReserves")
	if err != nil {
		return nil, err
	}
	pools := make([]Pool, 0, len(known))
	for _, p := range known {
		addr := common.HexToAddress(p.Address)
		raw, err := b.client.CallContract(ctx, ethereum.CallMsg{To: &addr, Data: data}, nil)
		if err != nil {
			return nil, fmt.Errorf("getReserves %s: %w", p.Address, err)
		}
		vals, err := b.abi.Unpack("getReserves", raw)
		if err != nil {
			return nil, fmt.Errorf("decode reserves %s: %w", p.Address, err)
		}
		pools = append(pools, Pool{
			Address: addr, Token0: common.HexToAddress(p.Token0), Token1: common.HexToAddress(p.Token1),
			Reserve0: vals[0].(*big.Int), Reserve1: vals[1].(*big.Int),
		})
	}
	return pools, nil
}

// Tick looks for an opportunity and executes it. Returns sent=true if a transaction went out.
func (b *Bot) Tick(ctx context.Context) (Opportunity, bool, error) {
	pools, err := b.LoadPools(ctx)
	if err != nil {
		return Opportunity{}, false, err
	}
	opp, ok := FindBest(pools, b.minProfitBps)
	if !ok {
		return Opportunity{}, false, nil
	}
	// Require at least 90% of the expected profit on-chain; less means someone else moved first.
	minProfit := new(big.Int).Div(new(big.Int).Mul(opp.Profit, big.NewInt(9)), big.NewInt(10))
	deadline := big.NewInt(time.Now().Add(2 * time.Minute).Unix())
	data, err := b.abi.Pack("execute", opp.Path, opp.AmountIn, minProfit, deadline)
	if err != nil {
		return opp, false, err
	}
	if err := b.send(ctx, data); err != nil {
		return opp, false, err
	}
	return opp, true, nil
}

func (b *Bot) send(ctx context.Context, data []byte) error {
	chainID, err := b.client.ChainID(ctx)
	if err != nil {
		return err
	}
	gas, err := b.client.EstimateGas(ctx, ethereum.CallMsg{From: b.from, To: &b.arbitrage, Data: data})
	if err != nil {
		return fmt.Errorf("estimate gas (opportunity may be gone): %w", err)
	}
	nonce, err := b.client.PendingNonceAt(ctx, b.from)
	if err != nil {
		return err
	}
	tip, err := b.client.SuggestGasTipCap(ctx)
	if err != nil {
		return err
	}
	head, err := b.client.HeaderByNumber(ctx, nil)
	if err != nil {
		return err
	}
	baseFee := head.BaseFee
	if baseFee == nil {
		baseFee = big.NewInt(0)
	}
	tx, err := types.SignTx(types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: tip,
		GasFeeCap: new(big.Int).Add(tip, new(big.Int).Mul(baseFee, big.NewInt(2))),
		Gas:       gas * 12 / 10,
		To:        &b.arbitrage,
		Data:      data,
	}), types.LatestSignerForChainID(chainID), b.key)
	if err != nil {
		return err
	}
	if err := b.client.SendTransaction(ctx, tx); err != nil {
		return fmt.Errorf("send: %w", err)
	}
	b.log.Info("sent arbitrage", "tx", tx.Hash().Hex())
	return b.waitMined(ctx, tx.Hash())
}

func (b *Bot) waitMined(ctx context.Context, hash common.Hash) error {
	for i := 0; i < 60; i++ {
		receipt, err := b.client.TransactionReceipt(ctx, hash)
		if err == nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				return fmt.Errorf("arbitrage tx %s reverted", hash.Hex())
			}
			return nil
		}
		if !errors.Is(err, ethereum.NotFound) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("arbitrage tx %s not mined after 60s", hash.Hex())
}

func trim0x(s string) string {
	if len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}
