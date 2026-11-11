// Package store persists DEX events in Postgres and answers the API's queries.
package store

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rajdama/mini-dex/indexer/internal/chain"
)

const schema = `
CREATE TABLE IF NOT EXISTS pairs (
  address       TEXT PRIMARY KEY,
  token0        TEXT    NOT NULL,
  token1        TEXT    NOT NULL,
  created_block BIGINT  NOT NULL
);

CREATE TABLE IF NOT EXISTS swaps (
  tx_hash      TEXT          NOT NULL,
  log_index    INTEGER       NOT NULL,
  pair         TEXT          NOT NULL,
  block_number BIGINT        NOT NULL,
  block_time   TIMESTAMPTZ   NOT NULL,
  sender       TEXT          NOT NULL,
  recipient    TEXT          NOT NULL,
  amount0_in   NUMERIC(78,0) NOT NULL,
  amount1_in   NUMERIC(78,0) NOT NULL,
  amount0_out  NUMERIC(78,0) NOT NULL,
  amount1_out  NUMERIC(78,0) NOT NULL,
  PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS swaps_pair_time_idx ON swaps (pair, block_time);

CREATE TABLE IF NOT EXISTS liquidity_events (
  tx_hash      TEXT          NOT NULL,
  log_index    INTEGER       NOT NULL,
  pair         TEXT          NOT NULL,
  kind         TEXT          NOT NULL,
  block_number BIGINT        NOT NULL,
  block_time   TIMESTAMPTZ   NOT NULL,
  recipient    TEXT          NOT NULL,
  amount0      NUMERIC(78,0) NOT NULL,
  amount1      NUMERIC(78,0) NOT NULL,
  liquidity    NUMERIC(78,0) NOT NULL,
  PRIMARY KEY (tx_hash, log_index)
);

CREATE TABLE IF NOT EXISTS syncs (
  tx_hash      TEXT          NOT NULL,
  log_index    INTEGER       NOT NULL,
  pair         TEXT          NOT NULL,
  block_number BIGINT        NOT NULL,
  block_time   TIMESTAMPTZ   NOT NULL,
  reserve0     NUMERIC(78,0) NOT NULL,
  reserve1     NUMERIC(78,0) NOT NULL,
  PRIMARY KEY (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS syncs_pair_time_idx ON syncs (pair, block_time);

CREATE TABLE IF NOT EXISTS arbitrages (
  tx_hash      TEXT          NOT NULL,
  log_index    INTEGER       NOT NULL,
  block_number BIGINT        NOT NULL,
  block_time   TIMESTAMPTZ   NOT NULL,
  caller       TEXT          NOT NULL,
  token        TEXT          NOT NULL,
  amount_in    NUMERIC(78,0) NOT NULL,
  profit       NUMERIC(78,0) NOT NULL,
  PRIMARY KEY (tx_hash, log_index)
);

CREATE TABLE IF NOT EXISTS sync_state (
  id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_block BIGINT  NOT NULL
);
`

// IndexedEvent is a decoded event plus its block time.
type IndexedEvent struct {
	chain.Event
	BlockTime time.Time
}

type Pair struct {
	Address, Token0, Token1 string
}

type Store struct {
	pool *pgxpool.Pool
}

func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

func (s *Store) Migrate(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, schema)
	return err
}

func lower(a string) string { return strings.ToLower(a) }

func num(n *big.Int) string {
	if n == nil {
		return "0"
	}
	return n.String()
}

// LastBlock returns the last fully indexed block, or ok=false if nothing is indexed yet.
func (s *Store) LastBlock(ctx context.Context) (uint64, bool, error) {
	var block int64
	err := s.pool.QueryRow(ctx, `SELECT last_block FROM sync_state WHERE id = 1`).Scan(&block)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	return uint64(block), err == nil, err
}

// Pairs returns every known pair.
func (s *Store) Pairs(ctx context.Context) ([]Pair, error) {
	rows, err := s.pool.Query(ctx, `SELECT address, token0, token1 FROM pairs ORDER BY created_block, address`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Pair, error) {
		var p Pair
		err := r.Scan(&p.Address, &p.Token0, &p.Token1)
		return p, err
	})
}

// ApplyBatch stores events and moves the cursor to toBlock in one transaction.
// Re-applying the same events is a no-op, so a crash mid-batch is safe to retry.
func (s *Store) ApplyBatch(ctx context.Context, events []IndexedEvent, toBlock uint64) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit

	for _, ev := range events {
		if err := insert(ctx, tx, ev); err != nil {
			return fmt.Errorf("store %s: %w", ev.Kind, err)
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO sync_state (id, last_block) VALUES (1, $1)
		ON CONFLICT (id) DO UPDATE SET last_block = EXCLUDED.last_block`, int64(toBlock)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func insert(ctx context.Context, tx pgx.Tx, ev IndexedEvent) error {
	key := []any{ev.TxHash.Hex(), int32(ev.LogIndex)}
	block := int64(ev.BlockNumber)
	var err error
	switch ev.Kind {
	case chain.KindPairCreated:
		_, err = tx.Exec(ctx, `
			INSERT INTO pairs (address, token0, token1, created_block) VALUES ($1, $2, $3, $4)
			ON CONFLICT (address) DO NOTHING`,
			lower(ev.Pair.Hex()), lower(ev.Token0.Hex()), lower(ev.Token1.Hex()), block)
	case chain.KindSwap:
		_, err = tx.Exec(ctx, `
			INSERT INTO swaps (tx_hash, log_index, pair, block_number, block_time, sender, recipient,
			                   amount0_in, amount1_in, amount0_out, amount1_out)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::numeric, $9::text::numeric, $10::text::numeric, $11::text::numeric)
			ON CONFLICT DO NOTHING`,
			key[0], key[1], lower(ev.Address.Hex()), block, ev.BlockTime, lower(ev.Sender.Hex()), lower(ev.To.Hex()),
			num(ev.Amount0In), num(ev.Amount1In), num(ev.Amount0Out), num(ev.Amount1Out))
	case chain.KindMint, chain.KindBurn:
		_, err = tx.Exec(ctx, `
			INSERT INTO liquidity_events (tx_hash, log_index, pair, kind, block_number, block_time, recipient,
			                              amount0, amount1, liquidity)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::numeric, $9::text::numeric, $10::text::numeric)
			ON CONFLICT DO NOTHING`,
			key[0], key[1], lower(ev.Address.Hex()), string(ev.Kind), block, ev.BlockTime, lower(ev.To.Hex()),
			num(ev.Amount0), num(ev.Amount1), num(ev.Liquidity))
	case chain.KindSync:
		_, err = tx.Exec(ctx, `
			INSERT INTO syncs (tx_hash, log_index, pair, block_number, block_time, reserve0, reserve1)
			VALUES ($1, $2, $3, $4, $5, $6::text::numeric, $7::text::numeric)
			ON CONFLICT DO NOTHING`,
			key[0], key[1], lower(ev.Address.Hex()), block, ev.BlockTime, num(ev.Reserve0), num(ev.Reserve1))
	case chain.KindArbitrage:
		_, err = tx.Exec(ctx, `
			INSERT INTO arbitrages (tx_hash, log_index, block_number, block_time, caller, token, amount_in, profit)
			VALUES ($1, $2, $3, $4, $5, $6, $7::text::numeric, $8::text::numeric)
			ON CONFLICT DO NOTHING`,
			key[0], key[1], block, ev.BlockTime, lower(ev.Caller.Hex()), lower(ev.Token.Hex()),
			num(ev.AmountIn), num(ev.Profit))
	}
	return err
}

// ---------------------------------------------------------------------------
// API queries
// ---------------------------------------------------------------------------

type PairStats struct {
	Address     string `json:"address"`
	Token0      string `json:"token0"`
	Token1      string `json:"token1"`
	Reserve0    string `json:"reserve0"`
	Reserve1    string `json:"reserve1"`
	Volume0_24h string `json:"volume0_24h"` // token0 sold into the pool
	Volume1_24h string `json:"volume1_24h"` // token1 sold into the pool
	Swaps24h    int64  `json:"swaps24h"`
}

type Candle struct {
	Time  int64   `json:"time"`
	Open  float64 `json:"open"`
	High  float64 `json:"high"`
	Low   float64 `json:"low"`
	Close float64 `json:"close"`
}

type Swap struct {
	Pair       string `json:"pair"`
	Trader     string `json:"trader"`
	Amount0In  string `json:"amount0In"`
	Amount1In  string `json:"amount1In"`
	Amount0Out string `json:"amount0Out"`
	Amount1Out string `json:"amount1Out"`
	TxHash     string `json:"txHash"`
	Block      int64  `json:"blockNumber"`
	Timestamp  int64  `json:"timestamp"`
}

type Arbitrage struct {
	Caller    string `json:"caller"`
	Token     string `json:"token"`
	AmountIn  string `json:"amountIn"`
	Profit    string `json:"profit"`
	TxHash    string `json:"txHash"`
	Block     int64  `json:"blockNumber"`
	Timestamp int64  `json:"timestamp"`
}

type Stats struct {
	Pairs            int64 `json:"pairs"`
	Swaps            int64 `json:"swaps"`
	Swaps24h         int64 `json:"swaps24h"`
	LiquidityEvents  int64 `json:"liquidityEvents"`
	Arbitrages       int64 `json:"arbitrages"`
	LastIndexedBlock int64 `json:"lastIndexedBlock"`
}

func (s *Store) Stats(ctx context.Context, now time.Time) (Stats, error) {
	var st Stats
	err := s.pool.QueryRow(ctx, `
		SELECT (SELECT COUNT(*) FROM pairs),
		       (SELECT COUNT(*) FROM swaps),
		       (SELECT COUNT(*) FROM swaps WHERE block_time > $1),
		       (SELECT COUNT(*) FROM liquidity_events),
		       (SELECT COUNT(*) FROM arbitrages),
		       (SELECT COALESCE(MAX(last_block), 0) FROM sync_state)`, now.Add(-24*time.Hour)).
		Scan(&st.Pairs, &st.Swaps, &st.Swaps24h, &st.LiquidityEvents, &st.Arbitrages, &st.LastIndexedBlock)
	return st, err
}

// PairStats returns each pair's latest reserves and 24h volume.
func (s *Store) PairStats(ctx context.Context, now time.Time) ([]PairStats, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT p.address, p.token0, p.token1,
		       COALESCE(r.reserve0, 0)::text, COALESCE(r.reserve1, 0)::text,
		       COALESCE(v.vol0, 0)::text, COALESCE(v.vol1, 0)::text, COALESCE(v.n, 0)
		FROM pairs p
		LEFT JOIN LATERAL (
		  SELECT reserve0, reserve1 FROM syncs WHERE pair = p.address
		  ORDER BY block_number DESC, log_index DESC LIMIT 1
		) r ON TRUE
		LEFT JOIN LATERAL (
		  SELECT SUM(amount0_in) AS vol0, SUM(amount1_in) AS vol1, COUNT(*) AS n
		  FROM swaps WHERE pair = p.address AND block_time > $1
		) v ON TRUE
		ORDER BY p.created_block, p.address`, now.Add(-24*time.Hour))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (PairStats, error) {
		var p PairStats
		err := r.Scan(&p.Address, &p.Token0, &p.Token1, &p.Reserve0, &p.Reserve1, &p.Volume0_24h, &p.Volume1_24h, &p.Swaps24h)
		return p, err
	})
}

// Candles returns hourly OHLC prices (token1 per token0) for the last `hours` hours, oldest first.
// Hours without trades repeat the previous close, so the chart has no gaps.
func (s *Store) Candles(ctx context.Context, pair string, hours int, now time.Time) ([]Candle, error) {
	end := now.UTC().Truncate(time.Hour)
	start := end.Add(-time.Duration(hours-1) * time.Hour)

	// The last price before the window, to open the first candle.
	var prev float64
	var hasPrev bool
	err := s.pool.QueryRow(ctx, `
		SELECT reserve1::float8 / NULLIF(reserve0::float8, 0) FROM syncs
		WHERE pair = $1 AND block_time < $2
		ORDER BY block_number DESC, log_index DESC LIMIT 1`, lower(pair), start).Scan(&prev)
	if err == nil {
		hasPrev = true
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	rows, err := s.pool.Query(ctx, `
		WITH s AS (
		  SELECT block_time, block_number, log_index, reserve1::float8 / NULLIF(reserve0::float8, 0) AS price
		  FROM syncs WHERE pair = $1 AND block_time >= $2 AND reserve0 > 0
		)
		SELECT EXTRACT(EPOCH FROM date_trunc('hour', block_time AT TIME ZONE 'UTC'))::bigint,
		       (array_agg(price ORDER BY block_number, log_index))[1],
		       MAX(price), MIN(price),
		       (array_agg(price ORDER BY block_number DESC, log_index DESC))[1]
		FROM s GROUP BY 1 ORDER BY 1`, lower(pair), start)
	if err != nil {
		return nil, err
	}
	buckets, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Candle, error) {
		var c Candle
		err := r.Scan(&c.Time, &c.Open, &c.High, &c.Low, &c.Close)
		return c, err
	})
	if err != nil {
		return nil, err
	}
	return fillCandles(buckets, start, end, prev, hasPrev), nil
}

// fillCandles lays the traded hours onto a continuous hourly series. Each candle opens at
// the previous close, so a gap between two trades doesn't look like a jump.
func fillCandles(buckets []Candle, start, end time.Time, prev float64, hasPrev bool) []Candle {
	byTime := make(map[int64]Candle, len(buckets))
	for _, b := range buckets {
		byTime[b.Time] = b
	}
	var out []Candle
	for t := start; !t.After(end); t = t.Add(time.Hour) {
		ts := t.Unix()
		b, traded := byTime[ts]
		switch {
		case traded && hasPrev:
			b.Open = prev
			if prev > b.High {
				b.High = prev
			}
			if prev < b.Low {
				b.Low = prev
			}
			out = append(out, b)
		case traded:
			out = append(out, b)
		case hasPrev:
			out = append(out, Candle{Time: ts, Open: prev, High: prev, Low: prev, Close: prev})
		default:
			continue // nothing traded yet
		}
		prev, hasPrev = out[len(out)-1].Close, true
	}
	return out
}

// Swaps returns the newest user swaps. Hops into another pair (multi-hop routes) and the
// arbitrage contract's own trades are left out: they show up as their own entries elsewhere.
func (s *Store) Swaps(ctx context.Context, limit int, pair string, arbitrage string) ([]Swap, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT pair, recipient, amount0_in::text, amount1_in::text, amount0_out::text, amount1_out::text,
		       tx_hash, block_number, EXTRACT(EPOCH FROM block_time)::bigint
		FROM swaps
		WHERE ($2 = '' OR pair = $2)
		  AND recipient NOT IN (SELECT address FROM pairs)
		  AND recipient <> $3
		ORDER BY block_number DESC, log_index DESC
		LIMIT $1`, limit, lower(pair), lower(arbitrage))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Swap, error) {
		var x Swap
		err := r.Scan(&x.Pair, &x.Trader, &x.Amount0In, &x.Amount1In, &x.Amount0Out, &x.Amount1Out, &x.TxHash, &x.Block, &x.Timestamp)
		return x, err
	})
}

func (s *Store) Arbitrages(ctx context.Context, limit int) ([]Arbitrage, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT caller, token, amount_in::text, profit::text, tx_hash, block_number, EXTRACT(EPOCH FROM block_time)::bigint
		FROM arbitrages ORDER BY block_number DESC, log_index DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Arbitrage, error) {
		var a Arbitrage
		err := r.Scan(&a.Caller, &a.Token, &a.AmountIn, &a.Profit, &a.TxHash, &a.Block, &a.Timestamp)
		return a, err
	})
}
