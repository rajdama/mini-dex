package bot

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

var (
	eth = common.HexToAddress("0x00000000000000000000000000000000000000e1")
	btc = common.HexToAddress("0x00000000000000000000000000000000000000b1")
	usd = common.HexToAddress("0x00000000000000000000000000000000000000d1")
)

func e18(n int64) *big.Int { return new(big.Int).Mul(big.NewInt(n), big.NewInt(1e18)) }

func pool(a common.Address, ra *big.Int, b common.Address, rb *big.Int) Pool {
	if a.Hex() < b.Hex() {
		return Pool{Token0: a, Token1: b, Reserve0: ra, Reserve1: rb}
	}
	return Pool{Token0: b, Token1: a, Reserve0: rb, Reserve1: ra}
}

// Consistent prices: 1 ETH = 3,000 USD, 1 BTC = 60,000 USD = 20 ETH.
func consistentPools() []Pool {
	return []Pool{
		pool(eth, e18(100), usd, e18(300_000)),
		pool(btc, e18(5), usd, e18(300_000)),
		pool(eth, e18(100), btc, e18(5)),
	}
}

func TestGetAmountOutMatchesContract(t *testing.T) {
	// Same numbers as the Solidity test: 1 ETH into 100 ETH / 300,000 USD.
	out := GetAmountOut(e18(1), e18(100), e18(300_000))
	want, _ := new(big.Int).SetString("2961474103191183896551", 10)
	if out.Cmp(want) != 0 {
		t.Fatalf("got %s, want %s", out, want)
	}
	if GetAmountOut(big.NewInt(0), e18(1), e18(1)).Sign() != 0 {
		t.Fatal("zero input should give zero output")
	}
}

func TestNoOpportunityWhenPricesAgree(t *testing.T) {
	if opp, ok := FindBest(consistentPools(), 0); ok {
		t.Fatalf("expected no arbitrage, found %+v", opp)
	}
}

func TestFindsProfitableLoopAfterDislocation(t *testing.T) {
	pools := consistentPools()
	// Someone dumps 20 ETH into ETH/USD: ETH is now cheap there.
	sold := e18(20)
	out := GetAmountOut(sold, e18(100), e18(300_000))
	pools[0] = pool(eth, e18(120), usd, new(big.Int).Sub(e18(300_000), out))

	opp, ok := FindBest(pools, 10)
	if !ok {
		t.Fatal("expected an opportunity")
	}
	if opp.Path[0] != opp.Path[3] || len(opp.Path) != 4 {
		t.Fatalf("path must be a loop: %v", opp.Path)
	}
	if opp.Profit.Sign() <= 0 || opp.ProfitBps() < 10 {
		t.Fatalf("expected profit, got %s (%d bps)", opp.Profit, opp.ProfitBps())
	}
	// The cheap leg must be buying ETH in the ETH/USD pool: ...USD -> ETH...
	foundCheapLeg := false
	for i := 0; i < 3; i++ {
		if opp.Path[i] == usd && opp.Path[i+1] == eth {
			foundCheapLeg = true
		}
	}
	if !foundCheapLeg {
		t.Fatalf("expected the loop to buy ETH with USD, got %v", opp.Path)
	}
}

// The ternary search must land on the true optimum: no nearby size does better.
func TestBestSizeIsOptimal(t *testing.T) {
	edges := []edge{
		{rIn: e18(1_000), rOut: e18(2_000)},
		{rIn: e18(2_000), rOut: e18(1_100)},
		{rIn: e18(1_000), rOut: e18(1_000)},
	}
	amountIn, out := bestSize(edges)
	best := new(big.Int).Sub(out, amountIn)
	if best.Sign() <= 0 {
		t.Fatal("expected a profitable size")
	}
	step := new(big.Int).Div(amountIn, big.NewInt(100)) // 1% either side
	for _, x := range []*big.Int{new(big.Int).Sub(amountIn, step), new(big.Int).Add(amountIn, step)} {
		p := new(big.Int).Sub(cycleOut(edges, x), x)
		if p.Cmp(best) > 0 {
			t.Fatalf("size %s earns %s, more than the chosen %s earning %s", x, p, amountIn, best)
		}
	}
}

func TestMinProfitFiltersSmallOpportunities(t *testing.T) {
	pools := consistentPools()
	// A tiny dislocation: just above break-even after fees.
	out := GetAmountOut(e18(2), e18(100), e18(300_000))
	pools[0] = pool(eth, e18(102), usd, new(big.Int).Sub(e18(300_000), out))
	opp, ok := FindBest(pools, 0)
	if !ok {
		t.Skip("dislocation too small to be profitable at all")
	}
	if _, ok := FindBest(pools, opp.ProfitBps()+1); ok {
		t.Fatal("an opportunity below the minimum should be ignored")
	}
}

func TestInvalidKey(t *testing.T) {
	if _, err := New(nil, nil, emptyABI(), common.Address{}, "nope", 10, 0, nil); err == nil {
		t.Fatal("expected an error for an invalid key")
	}
}
