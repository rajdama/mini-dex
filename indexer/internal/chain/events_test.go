package chain

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

var (
	pairAddr = common.HexToAddress("0x00000000000000000000000000000000000000aa")
	alice    = common.HexToAddress("0x00000000000000000000000000000000000a11ce")
	router   = common.HexToAddress("0x00000000000000000000000000000000000000cc")
)

func codec(t *testing.T) *Codec {
	t.Helper()
	c, err := NewCodec()
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func logFor(t *testing.T, c *Codec, name string, indexed []common.Hash, args ...any) types.Log {
	t.Helper()
	ev := c.abi.Events[name]
	data, err := ev.Inputs.NonIndexed().Pack(args...)
	if err != nil {
		t.Fatalf("pack %s: %v", name, err)
	}
	return types.Log{Address: pairAddr, Topics: append([]common.Hash{ev.ID}, indexed...), Data: data, BlockNumber: 7, Index: 2}
}

func addrTopic(a common.Address) common.Hash { return common.BytesToHash(a.Bytes()) }

func TestDecodeSwap(t *testing.T) {
	c := codec(t)
	lg := logFor(t, c, "Swap", []common.Hash{addrTopic(router), addrTopic(alice)},
		big.NewInt(100), big.NewInt(0), big.NewInt(0), big.NewInt(295))
	ev, ok, err := c.Decode(lg)
	if err != nil || !ok || ev.Kind != KindSwap {
		t.Fatalf("ok=%v err=%v ev=%+v", ok, err, ev)
	}
	if ev.Sender != router || ev.To != alice || ev.Amount0In.Int64() != 100 || ev.Amount1Out.Int64() != 295 {
		t.Fatalf("unexpected %+v", ev)
	}
	if ev.Address != pairAddr || ev.BlockNumber != 7 || ev.LogIndex != 2 {
		t.Fatalf("unexpected metadata %+v", ev)
	}
}

func TestDecodeMintBurnSync(t *testing.T) {
	c := codec(t)
	mint, ok, err := c.Decode(logFor(t, c, "Mint", []common.Hash{addrTopic(router), addrTopic(alice)},
		big.NewInt(1), big.NewInt(2), big.NewInt(3)))
	if err != nil || !ok || mint.Kind != KindMint || mint.Liquidity.Int64() != 3 || mint.To != alice {
		t.Fatalf("mint: %+v ok=%v err=%v", mint, ok, err)
	}
	burn, ok, err := c.Decode(logFor(t, c, "Burn", []common.Hash{addrTopic(router), addrTopic(alice)},
		big.NewInt(4), big.NewInt(5), big.NewInt(6)))
	if err != nil || !ok || burn.Kind != KindBurn || burn.Amount1.Int64() != 5 {
		t.Fatalf("burn: %+v ok=%v err=%v", burn, ok, err)
	}
	sync, ok, err := c.Decode(logFor(t, c, "Sync", nil, big.NewInt(10), big.NewInt(20)))
	if err != nil || !ok || sync.Kind != KindSync || sync.Reserve0.Int64() != 10 || sync.Reserve1.Int64() != 20 {
		t.Fatalf("sync: %+v ok=%v err=%v", sync, ok, err)
	}
}

func TestDecodePairCreatedAndArbitrage(t *testing.T) {
	c := codec(t)
	t0 := common.HexToAddress("0x0000000000000000000000000000000000000001")
	t1 := common.HexToAddress("0x0000000000000000000000000000000000000002")
	pc, ok, err := c.Decode(logFor(t, c, "PairCreated", []common.Hash{addrTopic(t0), addrTopic(t1)}, pairAddr, big.NewInt(0)))
	if err != nil || !ok || pc.Kind != KindPairCreated || pc.Token0 != t0 || pc.Token1 != t1 || pc.Pair != pairAddr {
		t.Fatalf("pair created: %+v ok=%v err=%v", pc, ok, err)
	}
	arb, ok, err := c.Decode(logFor(t, c, "ArbitrageExecuted", []common.Hash{addrTopic(alice), addrTopic(t0)},
		big.NewInt(1000), big.NewInt(25)))
	if err != nil || !ok || arb.Kind != KindArbitrage || arb.Caller != alice || arb.Token != t0 || arb.Profit.Int64() != 25 {
		t.Fatalf("arbitrage: %+v ok=%v err=%v", arb, ok, err)
	}
}

func TestDecodeSkipsUnknownAndRejectsMalformed(t *testing.T) {
	c := codec(t)
	if _, ok, err := c.Decode(types.Log{Topics: []common.Hash{common.HexToHash("0xdead")}}); ok || err != nil {
		t.Fatalf("unknown event: ok=%v err=%v", ok, err)
	}
	if _, ok, err := c.Decode(types.Log{}); ok || err != nil {
		t.Fatalf("no topics: ok=%v err=%v", ok, err)
	}
	bad := logFor(t, c, "Swap", []common.Hash{addrTopic(router)}, big.NewInt(1), big.NewInt(0), big.NewInt(0), big.NewInt(1))
	if _, _, err := c.Decode(bad); err == nil {
		t.Fatal("expected an error for missing topics")
	}
}

// Signatures must match the Solidity events exactly, or no logs will match.
func TestSignaturesMatchSolidity(t *testing.T) {
	c := codec(t)
	want := map[string]string{
		"PairCreated":       "PairCreated(address,address,address,uint256)",
		"Swap":              "Swap(address,address,uint256,uint256,uint256,uint256)",
		"Mint":              "Mint(address,address,uint256,uint256,uint256)",
		"Burn":              "Burn(address,address,uint256,uint256,uint256)",
		"Sync":              "Sync(uint112,uint112)",
		"ArbitrageExecuted": "ArbitrageExecuted(address,address,uint256,uint256)",
	}
	for name, sig := range want {
		if got := c.abi.Events[name].Sig; got != sig {
			t.Errorf("%s = %s, want %s", name, got, sig)
		}
	}
	if len(c.FactoryTopics()) != 2 || len(c.PairTopics()) != 4 {
		t.Fatal("unexpected topic counts")
	}
}
