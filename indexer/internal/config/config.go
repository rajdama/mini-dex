// Package config loads settings from environment variables.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

type Config struct {
	RPCURL        string
	DatabaseURL   string
	Factory       common.Address
	Arbitrage     common.Address
	StartBlock    uint64
	Port          string
	PollInterval  time.Duration
	BatchSize     uint64
	Confirmations uint64

	// Optional arbitrage bot. Runs when BotPrivateKey is set.
	BotPrivateKey   string
	BotInterval     time.Duration
	BotMinProfitBps uint64 // minimum profit as basis points of the trade size
}

// Load reads the configuration. Required: RPC_URL, DATABASE_URL, FACTORY_ADDRESS, ARBITRAGE_ADDRESS.
func Load() (Config, error) {
	c := Config{
		RPCURL:        os.Getenv("RPC_URL"),
		DatabaseURL:   os.Getenv("DATABASE_URL"),
		Port:          getenv("PORT", "8080"),
		BotPrivateKey: os.Getenv("BOT_PRIVATE_KEY"),
	}
	if c.RPCURL == "" {
		return c, fmt.Errorf("RPC_URL is required")
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	var err error
	if c.Factory, err = getAddress("FACTORY_ADDRESS"); err != nil {
		return c, err
	}
	if c.Arbitrage, err = getAddress("ARBITRAGE_ADDRESS"); err != nil {
		return c, err
	}
	if c.StartBlock, err = getUint("START_BLOCK", 0); err != nil {
		return c, err
	}
	if c.BatchSize, err = getUint("BATCH_SIZE", 2000); err != nil {
		return c, err
	}
	if c.Confirmations, err = getUint("CONFIRMATIONS", 3); err != nil {
		return c, err
	}
	if c.BotMinProfitBps, err = getUint("BOT_MIN_PROFIT_BPS", 10); err != nil {
		return c, err
	}
	if c.PollInterval, err = getDuration("POLL_INTERVAL", 6*time.Second); err != nil {
		return c, err
	}
	if c.BotInterval, err = getDuration("BOT_INTERVAL", 15*time.Second); err != nil {
		return c, err
	}
	if c.BatchSize == 0 {
		return c, fmt.Errorf("BATCH_SIZE must be greater than 0")
	}
	return c, nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getAddress(key string) (common.Address, error) {
	v := os.Getenv(key)
	if !common.IsHexAddress(v) {
		return common.Address{}, fmt.Errorf("%s must be a valid address, got %q", key, v)
	}
	return common.HexToAddress(v), nil
}

func getUint(key string, fallback uint64) (uint64, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a non-negative integer: %w", key, err)
	}
	return n, nil
}

func getDuration(key string, fallback time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return 0, fmt.Errorf("%s must be a duration like 10s or 5m: %w", key, err)
	}
	return d, nil
}
