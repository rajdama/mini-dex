package store

import (
	"context"
	"math/big"
	"os"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/rajdama/mini-dex/indexer/internal/chain"
)

// These tests need a real Postgres. CI provides one; locally, set TEST_DATABASE_URL.
func openTestStore(t *testing.T) *Store {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	s, err := Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP TABLE IF EXISTS pairs, swaps, liquidity_events, syncs, arbitrages, sync_state`); err != nil {
		t.Fatal(err)
	}
	if err := s.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	return s
}

var (
	pairA     = common.HexToAddress("0x00000000000000000000000000000000000000AA")
	pairB     = common.HexToAddress("0x00000000000000000000000000000000000000BB")
	tok0      = common.HexToAddress("0x0000000000000000000000000000000000000001")
	tok1      = common.HexToAddress("0x0000000000000000000000000000000000000002")
	tok2      = common.HexToAddress("0x0000000000000000000000000000000000000003")
	trader    = common.HexToAddress("0x00000000000000000000000000000000000a11ce")
	arbitrage = common.HexToAddress("0x000000000000000000000000000000000000a4b1")
)

type builder struct {
	block uint64
	idx   uint
	out   []IndexedEvent
}

func (b *builder) add(ev chain.Event, at time.Time) {
	b.idx++
	ev.BlockNumber, ev.LogIndex = b.block, b.idx
	ev.TxHash = common.BigToHash(big.NewInt(int64(b.block*1000) + int64(b.idx)))
	b.out = append(b.out, IndexedEvent{Event: ev, BlockTime: at})
}

func (b *builder) sync(pair common.Address, r0, r1 int64, at time.Time) {
	b.block++
	b.add(chain.Event{Kind: chain.KindSync, Address: pair, Reserve0: big.NewInt(r0), Reserve1: big.NewInt(r1)}, at)
}

func (b *builder) swap(pair, to common.Address, in0, out1 int64, at time.Time) {
	b.add(chain.Event{
		Kind: chain.KindSwap, Address: pair, Sender: trader, To: to,
		Amount0In: big.NewInt(in0), Amount1In: big.NewInt(0), Amount0Out: big.NewInt(0), Amount1Out: big.NewInt(out1),
	}, at)
}

func TestIndexAndQuery(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 11, 11, 12, 30, 0, 0, time.UTC)

	b := &builder{}
	b.block++
	b.add(chain.Event{Kind: chain.KindPairCreated, Pair: pairA, Token0: tok0, Token1: tok1}, now.Add(-5*time.Hour))
	b.add(chain.Event{Kind: chain.KindPairCreated, Pair: pairB, Token0: tok1, Token1: tok2}, now.Add(-5*time.Hour))
	// An old swap outside the 24h window.
	b.block++
	b.swap(pairA, trader, 1000, 1, now.Add(-48*time.Hour))

	// Pair A price path (token1 per token0): 3h ago 2.0 then 2.5; 1h ago 3.0; nothing since.
	b.sync(pairA, 100, 200, now.Add(-3*time.Hour))
	b.add(chain.Event{Kind: chain.KindMint, Address: pairA, Sender: trader, To: trader,
		Amount0: big.NewInt(100), Amount1: big.NewInt(200), Liquidity: big.NewInt(141)}, now.Add(-3*time.Hour))
	b.sync(pairA, 100, 250, now.Add(-3*time.Hour+10*time.Minute))
	b.sync(pairA, 100, 300, now.Add(-1*time.Hour))
	b.swap(pairA, trader, 40, 70, now.Add(-1*time.Hour))
	// A multi-hop hop into pair B and an arbitrage trade: both hidden from the user feed.
	b.swap(pairA, pairB, 5, 9, now.Add(-30*time.Minute))
	b.swap(pairA, arbitrage, 7, 12, now.Add(-20*time.Minute))
	b.add(chain.Event{Kind: chain.KindArbitrage, Address: arbitrage, Caller: trader, Token: tok0,
		AmountIn: big.NewInt(1000), Profit: big.NewInt(42)}, now.Add(-20*time.Minute))

	if err := s.ApplyBatch(ctx, b.out, 99); err != nil {
		t.Fatal(err)
	}
	if err := s.ApplyBatch(ctx, b.out, 99); err != nil { // idempotent
		t.Fatal(err)
	}

	pairs, err := s.Pairs(ctx)
	if err != nil || len(pairs) != 2 || pairs[0].Address != "0x00000000000000000000000000000000000000aa" {
		t.Fatalf("pairs %+v err=%v", pairs, err)
	}
	if last, ok, err := s.LastBlock(ctx); err != nil || !ok || last != 99 {
		t.Fatalf("last block %d ok=%v err=%v", last, ok, err)
	}

	st, err := s.Stats(ctx, now)
	if err != nil || st.Pairs != 2 || st.Swaps != 4 || st.Swaps24h != 3 || st.LiquidityEvents != 1 || st.Arbitrages != 1 {
		t.Fatalf("stats %+v err=%v", st, err)
	}

	ps, err := s.PairStats(ctx, now)
	if err != nil || len(ps) != 2 {
		t.Fatalf("pair stats %+v err=%v", ps, err)
	}
	if ps[0].Reserve1 != "300" || ps[0].Volume0_24h != "52" || ps[0].Swaps24h != 3 {
		t.Errorf("pair A stats %+v", ps[0]) // 40 + 5 + 7 in the last 24h
	}
	if ps[1].Reserve0 != "0" || ps[1].Swaps24h != 0 {
		t.Errorf("pair B stats %+v", ps[1])
	}

	swaps, err := s.Swaps(ctx, 10, "", arbitrage.Hex())
	if err != nil || len(swaps) != 2 { // user swaps only
		t.Fatalf("swaps %+v err=%v", swaps, err)
	}
	if swaps[0].Amount0In != "40" || swaps[0].Trader != "0x00000000000000000000000000000000000a11ce" {
		t.Errorf("newest swap %+v", swaps[0])
	}

	arbs, err := s.Arbitrages(ctx, 10)
	if err != nil || len(arbs) != 1 || arbs[0].Profit != "42" {
		t.Fatalf("arbitrages %+v err=%v", arbs, err)
	}

	candles, err := s.Candles(ctx, pairA.Hex(), 5, now)
	if err != nil {
		t.Fatal(err)
	}
	// Window: 08:00..12:00 (5 hours). Trading starts 09:30 -> first candle is the 09:00 hour.
	if len(candles) != 4 {
		t.Fatalf("want 4 candles (09h-12h), got %d: %+v", len(candles), candles)
	}
	c9 := candles[0]
	if c9.Open != 2.0 || c9.Close != 2.5 || c9.High != 2.5 || c9.Low != 2.0 {
		t.Errorf("09h candle %+v", c9)
	}
	if c10 := candles[1]; c10.Open != 2.5 || c10.Close != 2.5 { // no trades: flat at previous close
		t.Errorf("10h candle %+v", c10)
	}
	if c11 := candles[2]; c11.Open != 2.5 || c11.Close != 3.0 || c11.High != 3.0 {
		t.Errorf("11h candle %+v", c11)
	}
	if c12 := candles[3]; c12.Open != 3.0 || c12.Close != 3.0 {
		t.Errorf("12h candle %+v", c12)
	}
}

func TestFillCandles(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(2 * time.Hour)
	// Price before the window was 1.0; one trade hour at 01:00 that only went up.
	got := fillCandles([]Candle{{Time: start.Add(time.Hour).Unix(), Open: 1.2, High: 1.5, Low: 1.2, Close: 1.5}}, start, end, 1.0, true)
	if len(got) != 3 || got[0].Close != 1.0 || got[1].Open != 1.0 || got[1].Low != 1.0 || got[2].Open != 1.5 {
		t.Fatalf("filled %+v", got)
	}
	if empty := fillCandles(nil, start, end, 0, false); len(empty) != 0 {
		t.Fatalf("expected no candles before any trade, got %+v", empty)
	}
}
