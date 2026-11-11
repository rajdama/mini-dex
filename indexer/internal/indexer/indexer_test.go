package indexer

import (
	"context"
	"io"
	"log/slog"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/rajdama/mini-dex/indexer/internal/chain"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

var (
	factory   = common.HexToAddress("0x00000000000000000000000000000000000000f1")
	arbitrage = common.HexToAddress("0x00000000000000000000000000000000000000a1")
	pair      = common.HexToAddress("0x00000000000000000000000000000000000000aa")
	stranger  = common.HexToAddress("0x00000000000000000000000000000000000000ee")
)

type fakeClient struct {
	head    uint64
	logs    []types.Log
	queries []ethereum.FilterQuery
}

func (c *fakeClient) BlockNumber(context.Context) (uint64, error) { return c.head, nil }

// FilterLogs honours block range, addresses and the first topic, like a real node.
func (c *fakeClient) FilterLogs(_ context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	c.queries = append(c.queries, q)
	var out []types.Log
	for _, lg := range c.logs {
		if lg.BlockNumber < q.FromBlock.Uint64() || lg.BlockNumber > q.ToBlock.Uint64() {
			continue
		}
		if !containsAddr(q.Addresses, lg.Address) || !containsHash(q.Topics[0], lg.Topics[0]) {
			continue
		}
		out = append(out, lg)
	}
	return out, nil
}

func (c *fakeClient) HeaderByNumber(_ context.Context, n *big.Int) (*types.Header, error) {
	return &types.Header{Number: n, Time: 1_700_000_000 + n.Uint64()*12}, nil
}

func containsAddr(list []common.Address, a common.Address) bool {
	for _, x := range list {
		if x == a {
			return true
		}
	}
	return false
}

func containsHash(list []common.Hash, h common.Hash) bool {
	for _, x := range list {
		if x == h {
			return true
		}
	}
	return false
}

type fakeSink struct {
	last    uint64
	hasLast bool
	events  []store.IndexedEvent
}

func (s *fakeSink) LastBlock(context.Context) (uint64, bool, error) { return s.last, s.hasLast, nil }
func (s *fakeSink) Pairs(context.Context) ([]store.Pair, error)     { return nil, nil }
func (s *fakeSink) ApplyBatch(_ context.Context, ev []store.IndexedEvent, to uint64) error {
	s.events = append(s.events, ev...)
	s.last, s.hasLast = to, true
	return nil
}

func mkLog(t *testing.T, c *chain.Codec, addr common.Address, name string, block uint64, idx uint, indexed []common.Hash, args ...any) types.Log {
	t.Helper()
	ev := c.ABI().Events[name]
	data, err := ev.Inputs.NonIndexed().Pack(args...)
	if err != nil {
		t.Fatal(err)
	}
	return types.Log{Address: addr, Topics: append([]common.Hash{ev.ID}, indexed...), Data: data,
		BlockNumber: block, Index: idx, TxHash: common.BigToHash(big.NewInt(int64(block)))}
}

func h(a common.Address) common.Hash { return common.BytesToHash(a.Bytes()) }

func TestNewPairEventsAreIndexedInTheSameBatch(t *testing.T) {
	c, _ := chain.NewCodec()
	t0 := common.HexToAddress("0x01")
	t1 := common.HexToAddress("0x02")
	client := &fakeClient{head: 20, logs: []types.Log{
		mkLog(t, c, factory, "PairCreated", 10, 0, []common.Hash{h(t0), h(t1)}, pair, big.NewInt(0)),
		mkLog(t, c, pair, "Sync", 10, 1, nil, big.NewInt(100), big.NewInt(200)),
		mkLog(t, c, pair, "Swap", 11, 0, []common.Hash{h(stranger), h(stranger)},
			big.NewInt(10), big.NewInt(0), big.NewInt(0), big.NewInt(18)),
		// A look-alike Sync from an unrelated contract must be ignored.
		mkLog(t, c, stranger, "Sync", 11, 1, nil, big.NewInt(1), big.NewInt(1)),
	}}
	sink := &fakeSink{}
	ix := New(client, sink, c, Options{Factory: factory, Arbitrage: arbitrage, BatchSize: 100, Confirmations: 2,
		PollInterval: time.Millisecond}, slog.New(slog.NewTextHandler(io.Discard, nil)))

	caughtUp, err := ix.Step(context.Background())
	if err != nil || !caughtUp {
		t.Fatalf("caughtUp=%v err=%v", caughtUp, err)
	}
	if sink.last != 18 {
		t.Fatalf("cursor %d, want safe head 18", sink.last)
	}
	if len(sink.events) != 3 {
		t.Fatalf("want 3 events, got %d", len(sink.events))
	}
	kinds := []chain.Kind{sink.events[0].Kind, sink.events[1].Kind, sink.events[2].Kind}
	if kinds[0] != chain.KindPairCreated || kinds[1] != chain.KindSync || kinds[2] != chain.KindSwap {
		t.Fatalf("events out of order: %v", kinds)
	}
	if want := time.Unix(1_700_000_000+11*12, 0).UTC(); !sink.events[2].BlockTime.Equal(want) {
		t.Fatalf("block time %v want %v", sink.events[2].BlockTime, want)
	}
	if got := ix.KnownPairs(); len(got) != 1 || got[0] != "0x00000000000000000000000000000000000000aa" {
		t.Fatalf("known pairs %v", got)
	}
}

func TestWaitsForConfirmationsAndResumes(t *testing.T) {
	c, _ := chain.NewCodec()
	client := &fakeClient{head: 3}
	sink := &fakeSink{last: 50, hasLast: true}
	ix := New(client, sink, c, Options{Factory: factory, Arbitrage: arbitrage, BatchSize: 10, Confirmations: 5},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	if caughtUp, err := ix.Step(context.Background()); err != nil || !caughtUp || len(client.queries) != 0 {
		t.Fatalf("head below confirmations: caughtUp=%v err=%v queries=%d", caughtUp, err, len(client.queries))
	}
	client.head = 100
	if _, err := ix.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if q := client.queries[0]; q.FromBlock.Uint64() != 51 || q.ToBlock.Uint64() != 60 {
		t.Fatalf("queried %d-%d, want 51-60", q.FromBlock, q.ToBlock)
	}
}

func TestRunStopsOnCancel(t *testing.T) {
	c, _ := chain.NewCodec()
	ix := New(&fakeClient{head: 10}, &fakeSink{}, c, Options{BatchSize: 100, PollInterval: time.Millisecond},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := ix.Run(ctx); err != context.DeadlineExceeded {
		t.Fatalf("Run returned %v", err)
	}
}
