// Package indexer follows the chain and stores Mini DEX events.
package indexer

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"sort"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/rajdama/mini-dex/indexer/internal/chain"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

// Client is the subset of an Ethereum RPC client the indexer needs.
type Client interface {
	BlockNumber(ctx context.Context) (uint64, error)
	FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error)
	HeaderByNumber(ctx context.Context, number *big.Int) (*types.Header, error)
}

// Sink is where decoded events go (the Postgres store in production).
type Sink interface {
	LastBlock(ctx context.Context) (uint64, bool, error)
	Pairs(ctx context.Context) ([]store.Pair, error)
	ApplyBatch(ctx context.Context, events []store.IndexedEvent, toBlock uint64) error
}

type Options struct {
	Factory       common.Address
	Arbitrage     common.Address
	StartBlock    uint64
	BatchSize     uint64
	Confirmations uint64
	PollInterval  time.Duration
}

type Indexer struct {
	client Client
	sink   Sink
	codec  *chain.Codec
	opts   Options
	log    *slog.Logger
	pairs  map[common.Address]bool // known pairs
}

func New(client Client, sink Sink, codec *chain.Codec, opts Options, log *slog.Logger) *Indexer {
	return &Indexer{client: client, sink: sink, codec: codec, opts: opts, log: log}
}

func (ix *Indexer) Run(ctx context.Context) error {
	for {
		caughtUp, err := ix.Step(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			ix.log.Error("indexing step failed, retrying", "err", err)
		}
		wait := time.Duration(0)
		if caughtUp || err != nil {
			wait = ix.opts.PollInterval
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

func (ix *Indexer) loadPairs(ctx context.Context) error {
	if ix.pairs != nil {
		return nil
	}
	known, err := ix.sink.Pairs(ctx)
	if err != nil {
		return fmt.Errorf("load pairs: %w", err)
	}
	ix.pairs = map[common.Address]bool{}
	for _, p := range known {
		ix.pairs[common.HexToAddress(p.Address)] = true
	}
	return nil
}

// Step indexes one batch of blocks. It returns caughtUp=true when there was nothing new.
func (ix *Indexer) Step(ctx context.Context) (caughtUp bool, err error) {
	if err := ix.loadPairs(ctx); err != nil {
		return false, err
	}
	head, err := ix.client.BlockNumber(ctx)
	if err != nil {
		return false, fmt.Errorf("block number: %w", err)
	}
	if head < ix.opts.Confirmations {
		return true, nil
	}
	safe := head - ix.opts.Confirmations

	from := ix.opts.StartBlock
	last, ok, err := ix.sink.LastBlock(ctx)
	if err != nil {
		return false, fmt.Errorf("read cursor: %w", err)
	}
	if ok && last+1 > from {
		from = last + 1
	}
	if from > safe {
		return true, nil
	}
	to := from + ix.opts.BatchSize - 1
	if to > safe {
		to = safe
	}
	fromBig, toBig := new(big.Int).SetUint64(from), new(big.Int).SetUint64(to)

	// 1. Factory and arbitrage events: new pairs must be known before reading pair events.
	logs, err := ix.client.FilterLogs(ctx, ethereum.FilterQuery{
		FromBlock: fromBig, ToBlock: toBig,
		Addresses: []common.Address{ix.opts.Factory, ix.opts.Arbitrage},
		Topics:    [][]common.Hash{ix.codec.FactoryTopics()},
	})
	if err != nil {
		return false, fmt.Errorf("filter factory logs %d-%d: %w", from, to, err)
	}
	events, err := ix.decode(logs)
	if err != nil {
		return false, err
	}
	newPairs := map[common.Address]bool{}
	for _, ev := range events {
		if ev.Kind == chain.KindPairCreated {
			newPairs[ev.Pair] = true
		}
	}

	// 2. Swap, Mint, Burn and Sync events from every known pair.
	addresses := make([]common.Address, 0, len(ix.pairs)+len(newPairs))
	for p := range ix.pairs {
		addresses = append(addresses, p)
	}
	for p := range newPairs {
		if !ix.pairs[p] {
			addresses = append(addresses, p)
		}
	}
	if len(addresses) > 0 {
		pairLogs, err := ix.client.FilterLogs(ctx, ethereum.FilterQuery{
			FromBlock: fromBig, ToBlock: toBig,
			Addresses: addresses,
			Topics:    [][]common.Hash{ix.codec.PairTopics()},
		})
		if err != nil {
			return false, fmt.Errorf("filter pair logs %d-%d: %w", from, to, err)
		}
		more, err := ix.decode(pairLogs)
		if err != nil {
			return false, err
		}
		events = append(events, more...)
	}

	sort.Slice(events, func(i, j int) bool {
		if events[i].BlockNumber != events[j].BlockNumber {
			return events[i].BlockNumber < events[j].BlockNumber
		}
		return events[i].LogIndex < events[j].LogIndex
	})

	indexed, err := ix.withBlockTimes(ctx, events)
	if err != nil {
		return false, err
	}
	if err := ix.sink.ApplyBatch(ctx, indexed, to); err != nil {
		return false, fmt.Errorf("store batch: %w", err)
	}
	for p := range newPairs {
		ix.pairs[p] = true
	}
	ix.log.Info("indexed", "from", from, "to", to, "events", len(events), "pairs", len(ix.pairs), "head", head)
	return to == safe, nil
}

func (ix *Indexer) decode(logs []types.Log) ([]chain.Event, error) {
	out := make([]chain.Event, 0, len(logs))
	for _, lg := range logs {
		if lg.Removed {
			continue
		}
		ev, ok, err := ix.codec.Decode(lg)
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, ev)
		}
	}
	return out, nil
}

func (ix *Indexer) withBlockTimes(ctx context.Context, events []chain.Event) ([]store.IndexedEvent, error) {
	times := map[uint64]time.Time{}
	out := make([]store.IndexedEvent, 0, len(events))
	for _, ev := range events {
		t, ok := times[ev.BlockNumber]
		if !ok {
			h, err := ix.client.HeaderByNumber(ctx, new(big.Int).SetUint64(ev.BlockNumber))
			if err != nil {
				return nil, fmt.Errorf("header %d: %w", ev.BlockNumber, err)
			}
			t = time.Unix(int64(h.Time), 0).UTC()
			times[ev.BlockNumber] = t
		}
		out = append(out, store.IndexedEvent{Event: ev, BlockTime: t})
	}
	return out, nil
}

// KnownPairs lists the pairs seen so far (used in logs and tests).
func (ix *Indexer) KnownPairs() []string {
	out := make([]string, 0, len(ix.pairs))
	for p := range ix.pairs {
		out = append(out, strings.ToLower(p.Hex()))
	}
	sort.Strings(out)
	return out
}
