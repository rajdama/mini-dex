// Package api serves indexed DEX data as JSON.
package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

// Reader is the data the API serves (the Postgres store in production).
type Reader interface {
	Stats(ctx context.Context, now time.Time) (store.Stats, error)
	PairStats(ctx context.Context, now time.Time) ([]store.PairStats, error)
	Candles(ctx context.Context, pair string, hours int, now time.Time) ([]store.Candle, error)
	Swaps(ctx context.Context, limit int, pair string, arbitrage string) ([]store.Swap, error)
	Arbitrages(ctx context.Context, limit int) ([]store.Arbitrage, error)
}

type Server struct {
	data      Reader
	arbitrage string
	now       func() time.Time
	log       *slog.Logger
}

func New(data Reader, arbitrage common.Address, log *slog.Logger) *Server {
	return &Server{data: data, arbitrage: arbitrage.Hex(), now: time.Now, log: log}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/stats", s.stats)
	mux.HandleFunc("GET /api/pairs", s.pairs)
	mux.HandleFunc("GET /api/pairs/{address}/candles", s.candles)
	mux.HandleFunc("GET /api/swaps", s.swaps)
	mux.HandleFunc("GET /api/arbitrage", s.arbitrages)
	return cors(mux)
}

type list[T any] struct {
	Items []T `json:"items"`
}

func (s *Server) stats(w http.ResponseWriter, r *http.Request) {
	st, err := s.data.Stats(r.Context(), s.now())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) pairs(w http.ResponseWriter, r *http.Request) {
	items, err := s.data.PairStats(r.Context(), s.now())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list[store.PairStats]{Items: nonNil(items)})
}

func (s *Server) candles(w http.ResponseWriter, r *http.Request) {
	address := r.PathValue("address")
	if !common.IsHexAddress(address) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid pair address"})
		return
	}
	items, err := s.data.Candles(r.Context(), address, intParam(r, "limit", 48, 2, 24*30), s.now())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list[store.Candle]{Items: nonNil(items)})
}

func (s *Server) swaps(w http.ResponseWriter, r *http.Request) {
	pair := r.URL.Query().Get("pair")
	if pair != "" && !common.IsHexAddress(pair) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid pair address"})
		return
	}
	items, err := s.data.Swaps(r.Context(), intParam(r, "limit", 20, 1, 100), pair, s.arbitrage)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list[store.Swap]{Items: nonNil(items)})
}

func (s *Server) arbitrages(w http.ResponseWriter, r *http.Request) {
	items, err := s.data.Arbitrages(r.Context(), intParam(r, "limit", 10, 1, 100))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list[store.Arbitrage]{Items: nonNil(items)})
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	s.log.Error("api error", "err", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
}

// intParam reads an integer query parameter, clamped to [lo, hi].
func intParam(r *http.Request, name string, fallback, lo, hi int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil {
		return fallback
	}
	return max(lo, min(hi, v))
}

func nonNil[T any](items []T) []T {
	if items == nil {
		return []T{}
	}
	return items
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
