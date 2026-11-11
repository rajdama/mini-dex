// Command indexer follows the Mini DEX contracts, stores their events in Postgres, serves
// them over an HTTP API, and optionally runs the arbitrage bot.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/rajdama/mini-dex/indexer/internal/api"
	"github.com/rajdama/mini-dex/indexer/internal/bot"
	"github.com/rajdama/mini-dex/indexer/internal/chain"
	"github.com/rajdama/mini-dex/indexer/internal/config"
	"github.com/rajdama/mini-dex/indexer/internal/indexer"
	"github.com/rajdama/mini-dex/indexer/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := store.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.Migrate(ctx); err != nil {
		return err
	}

	client, err := ethclient.DialContext(ctx, cfg.RPCURL)
	if err != nil {
		return err
	}
	defer client.Close()

	codec, err := chain.NewCodec()
	if err != nil {
		return err
	}

	ix := indexer.New(client, db, codec, indexer.Options{
		Factory:       cfg.Factory,
		Arbitrage:     cfg.Arbitrage,
		StartBlock:    cfg.StartBlock,
		BatchSize:     cfg.BatchSize,
		Confirmations: cfg.Confirmations,
		PollInterval:  cfg.PollInterval,
	}, log.With("component", "indexer"))

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           api.New(db, cfg.Arbitrage, log.With("component", "api")).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	errs := make(chan error, 3)
	go func() { errs <- ix.Run(ctx) }()
	go func() {
		log.Info("api listening", "port", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()
	if cfg.BotPrivateKey != "" {
		b, err := bot.New(client, db, codec.ABI(), cfg.Arbitrage, cfg.BotPrivateKey, cfg.BotMinProfitBps,
			cfg.BotInterval, log.With("component", "bot"))
		if err != nil {
			return err
		}
		log.Info("arbitrage bot enabled", "address", b.Address().Hex(), "minProfitBps", cfg.BotMinProfitBps)
		go func() { errs <- b.Run(ctx) }()
	}

	select {
	case <-ctx.Done():
	case err = <-errs:
	}
	stop()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	return err
}
