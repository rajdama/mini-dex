// Package chain decodes Mini DEX events and encodes calls.
package chain

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// ABI holds every event the indexer reads and the calls the bot makes.
const ABI = `[
  {"type":"event","name":"PairCreated","anonymous":false,"inputs":[
    {"name":"token0","type":"address","indexed":true},
    {"name":"token1","type":"address","indexed":true},
    {"name":"pair","type":"address","indexed":false},
    {"name":"index","type":"uint256","indexed":false}]},
  {"type":"event","name":"Swap","anonymous":false,"inputs":[
    {"name":"sender","type":"address","indexed":true},
    {"name":"to","type":"address","indexed":true},
    {"name":"amount0In","type":"uint256","indexed":false},
    {"name":"amount1In","type":"uint256","indexed":false},
    {"name":"amount0Out","type":"uint256","indexed":false},
    {"name":"amount1Out","type":"uint256","indexed":false}]},
  {"type":"event","name":"Mint","anonymous":false,"inputs":[
    {"name":"sender","type":"address","indexed":true},
    {"name":"to","type":"address","indexed":true},
    {"name":"amount0","type":"uint256","indexed":false},
    {"name":"amount1","type":"uint256","indexed":false},
    {"name":"liquidity","type":"uint256","indexed":false}]},
  {"type":"event","name":"Burn","anonymous":false,"inputs":[
    {"name":"sender","type":"address","indexed":true},
    {"name":"to","type":"address","indexed":true},
    {"name":"amount0","type":"uint256","indexed":false},
    {"name":"amount1","type":"uint256","indexed":false},
    {"name":"liquidity","type":"uint256","indexed":false}]},
  {"type":"event","name":"Sync","anonymous":false,"inputs":[
    {"name":"reserve0","type":"uint112","indexed":false},
    {"name":"reserve1","type":"uint112","indexed":false}]},
  {"type":"event","name":"ArbitrageExecuted","anonymous":false,"inputs":[
    {"name":"caller","type":"address","indexed":true},
    {"name":"token","type":"address","indexed":true},
    {"name":"amountIn","type":"uint256","indexed":false},
    {"name":"profit","type":"uint256","indexed":false}]},
  {"type":"function","name":"getReserves","stateMutability":"view","inputs":[],"outputs":[
    {"name":"reserve0","type":"uint112"},{"name":"reserve1","type":"uint112"},{"name":"blockTimestampLast","type":"uint32"}]},
  {"type":"function","name":"execute","stateMutability":"nonpayable","inputs":[
    {"name":"path","type":"address[]"},{"name":"amountIn","type":"uint256"},
    {"name":"minProfit","type":"uint256"},{"name":"deadline","type":"uint256"}],
   "outputs":[{"name":"profit","type":"uint256"}]}
]`

type Kind string

const (
	KindPairCreated Kind = "pair_created"
	KindSwap        Kind = "swap"
	KindMint        Kind = "mint"
	KindBurn        Kind = "burn"
	KindSync        Kind = "sync"
	KindArbitrage   Kind = "arbitrage"
)

// Event is a decoded log. Only the fields for its Kind are set.
type Event struct {
	Kind        Kind
	Address     common.Address // emitting contract
	BlockNumber uint64
	TxHash      common.Hash
	LogIndex    uint

	// PairCreated
	Token0, Token1, Pair common.Address
	// Swap, Mint, Burn: Sender is msg.sender (usually the router), To the recipient.
	Sender, To common.Address
	Amount0In  *big.Int
	Amount1In  *big.Int
	Amount0Out *big.Int
	Amount1Out *big.Int
	Amount0    *big.Int
	Amount1    *big.Int
	Liquidity  *big.Int
	// Sync
	Reserve0, Reserve1 *big.Int
	// ArbitrageExecuted
	Caller, Token    common.Address
	AmountIn, Profit *big.Int
}

type Codec struct {
	abi abi.ABI
}

func NewCodec() (*Codec, error) {
	parsed, err := abi.JSON(strings.NewReader(ABI))
	if err != nil {
		return nil, fmt.Errorf("parse ABI: %w", err)
	}
	return &Codec{abi: parsed}, nil
}

func (c *Codec) ABI() abi.ABI { return c.abi }

func (c *Codec) topic(name string) common.Hash { return c.abi.Events[name].ID }

// FactoryTopics and PairTopics are the event signatures to filter logs by.
func (c *Codec) FactoryTopics() []common.Hash {
	return []common.Hash{c.topic("PairCreated"), c.topic("ArbitrageExecuted")}
}

func (c *Codec) PairTopics() []common.Hash {
	return []common.Hash{c.topic("Swap"), c.topic("Mint"), c.topic("Burn"), c.topic("Sync")}
}

// Decode returns the event in a log, or ok=false for events this indexer doesn't track.
func (c *Codec) Decode(lg types.Log) (ev Event, ok bool, err error) {
	if len(lg.Topics) == 0 {
		return ev, false, nil
	}
	event, err := c.abi.EventByID(lg.Topics[0])
	if err != nil {
		return ev, false, nil
	}
	ev = Event{Address: lg.Address, BlockNumber: lg.BlockNumber, TxHash: lg.TxHash, LogIndex: lg.Index}

	var indexed abi.Arguments
	for _, in := range event.Inputs {
		if in.Indexed {
			indexed = append(indexed, in)
		}
	}
	if len(lg.Topics) != len(indexed)+1 {
		return ev, false, fmt.Errorf("%s log %s:%d has %d topics, want %d",
			event.Name, lg.TxHash.Hex(), lg.Index, len(lg.Topics), len(indexed)+1)
	}
	v := map[string]any{}
	if err := c.abi.UnpackIntoMap(v, event.Name, lg.Data); err != nil {
		return ev, false, fmt.Errorf("unpack %s: %w", event.Name, err)
	}
	if err := abi.ParseTopicsIntoMap(v, indexed, lg.Topics[1:]); err != nil {
		return ev, false, fmt.Errorf("topics %s: %w", event.Name, err)
	}

	switch event.Name {
	case "PairCreated":
		ev.Kind = KindPairCreated
		ev.Token0, ev.Token1, ev.Pair = v["token0"].(common.Address), v["token1"].(common.Address), v["pair"].(common.Address)
	case "Swap":
		ev.Kind = KindSwap
		ev.Sender, ev.To = v["sender"].(common.Address), v["to"].(common.Address)
		ev.Amount0In, ev.Amount1In = v["amount0In"].(*big.Int), v["amount1In"].(*big.Int)
		ev.Amount0Out, ev.Amount1Out = v["amount0Out"].(*big.Int), v["amount1Out"].(*big.Int)
	case "Mint", "Burn":
		ev.Kind = KindMint
		if event.Name == "Burn" {
			ev.Kind = KindBurn
		}
		ev.Sender, ev.To = v["sender"].(common.Address), v["to"].(common.Address)
		ev.Amount0, ev.Amount1, ev.Liquidity = v["amount0"].(*big.Int), v["amount1"].(*big.Int), v["liquidity"].(*big.Int)
	case "Sync":
		ev.Kind = KindSync
		ev.Reserve0, ev.Reserve1 = v["reserve0"].(*big.Int), v["reserve1"].(*big.Int)
	case "ArbitrageExecuted":
		ev.Kind = KindArbitrage
		ev.Caller, ev.Token = v["caller"].(common.Address), v["token"].(common.Address)
		ev.AmountIn, ev.Profit = v["amountIn"].(*big.Int), v["profit"].(*big.Int)
	default:
		return ev, false, nil
	}
	return ev, true, nil
}
