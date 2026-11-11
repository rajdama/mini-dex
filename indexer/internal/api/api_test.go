package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

type fakeReader struct {
	fail       bool
	candlePair string
	hours      int
	swapLimit  int
	swapPair   string
	arbFilter  string
}

func (f *fakeReader) Stats(context.Context, time.Time) (store.Stats, error) {
	if f.fail {
		return store.Stats{}, errors.New("boom")
	}
	return store.Stats{Pairs: 3}, nil
}
func (f *fakeReader) PairStats(context.Context, time.Time) ([]store.PairStats, error) {
	return nil, nil
}
func (f *fakeReader) Candles(_ context.Context, pair string, hours int, _ time.Time) ([]store.Candle, error) {
	f.candlePair, f.hours = pair, hours
	return []store.Candle{{Time: 1, Open: 1, High: 2, Low: 1, Close: 2}}, nil
}
func (f *fakeReader) Swaps(_ context.Context, limit int, pair, arb string) ([]store.Swap, error) {
	f.swapLimit, f.swapPair, f.arbFilter = limit, pair, arb
	return nil, nil
}
func (f *fakeReader) Arbitrages(context.Context, int) ([]store.Arbitrage, error) { return nil, nil }

var arb = common.HexToAddress("0x000000000000000000000000000000000000a4b1")

func get(t *testing.T, f *fakeReader, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	New(f, arb, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestEndpoints(t *testing.T) {
	f := &fakeReader{}
	if rec := get(t, f, "/api/stats"); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"pairs":3`) {
		t.Fatalf("stats %d %s", rec.Code, rec.Body)
	}
	if rec := get(t, f, "/api/pairs"); rec.Body.String() != "{\"items\":[]}\n" {
		t.Fatalf("pairs %s", rec.Body)
	}
	pair := "0x00000000000000000000000000000000000000AA"
	if rec := get(t, f, "/api/pairs/"+pair+"/candles?limit=99999"); rec.Code != 200 || f.candlePair != pair || f.hours != 720 {
		t.Fatalf("candles %d pair=%s hours=%d", rec.Code, f.candlePair, f.hours)
	}
	if rec := get(t, f, "/api/swaps?limit=5&pair="+pair); rec.Code != 200 || f.swapLimit != 5 || f.swapPair != pair || f.arbFilter != arb.Hex() {
		t.Fatalf("swaps %d %+v", rec.Code, f)
	}
	if rec := get(t, f, "/api/arbitrage"); rec.Code != 200 || rec.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("arbitrage %d", rec.Code)
	}
	if rec := get(t, f, "/healthz"); rec.Code != 200 {
		t.Fatalf("health %d", rec.Code)
	}
}

func TestBadInputAndErrors(t *testing.T) {
	f := &fakeReader{}
	if rec := get(t, f, "/api/pairs/nope/candles"); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad pair %d", rec.Code)
	}
	if rec := get(t, f, "/api/swaps?pair=nope"); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad swap pair %d", rec.Code)
	}
	if rec := get(t, &fakeReader{fail: true}, "/api/stats"); rec.Code != http.StatusInternalServerError {
		t.Fatalf("failure %d", rec.Code)
	}
}
