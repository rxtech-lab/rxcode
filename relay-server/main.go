package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", ":8787", "listen address")
	apnsKeyPath := flag.String("apns-key", "", "path to APNs .p8 auth key")
	apnsKeyID := flag.String("apns-key-id", "", "APNs Key ID")
	apnsTeamID := flag.String("apns-team-id", "", "APNs Team ID")
	apnsTopic := flag.String("apns-topic", "", "APNs topic (mobile app bundle ID)")
	apnsProduction := flag.Bool("apns-production", false, "use production APNs endpoint instead of sandbox")
	flag.Parse()

	hub := NewHub()
	go hub.Run()

	var pushSender *PushSender
	if *apnsKeyPath != "" {
		p, err := NewPushSender(*apnsKeyPath, *apnsKeyID, *apnsTeamID, *apnsTopic, *apnsProduction)
		if err != nil {
			log.Fatalf("init APNs sender: %v", err)
		}
		pushSender = p
		log.Printf("APNs sender enabled (topic=%s production=%v)", *apnsTopic, *apnsProduction)
	} else {
		log.Printf("APNs sender disabled (no -apns-key provided)")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeWS)
	mux.HandleFunc("/push", pushHandler(pushSender))
	mux.HandleFunc("/healthz", healthHandler(hub, pushSender))

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("relay listening on %s", *addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig

	log.Printf("shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
