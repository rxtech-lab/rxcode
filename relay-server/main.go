package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/joho/godotenv"
)

// version is the relay's reported build version, surfaced at /healthz. It
// defaults to "dev" for local/`go run` builds and is overridden at release
// build time via -ldflags "-X main.version=<tag>" (see Dockerfile + the
// relay-deploy workflow, which passes the git release tag).
var version = "dev"

func main() {
	// Load .env before reading any env vars so flag defaults see them.
	// Path overridable via RELAY_ENV_FILE; default ".env" in CWD. Missing
	// file is non-fatal — env may be supplied entirely by the host.
	envFile := envOr("RELAY_ENV_FILE", ".env")
	if err := godotenv.Load(envFile); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			log.Printf("no env file at %s (ok, using process env only)", envFile)
		} else {
			log.Fatalf("load env file %s: %v", envFile, err)
		}
	} else {
		log.Printf("loaded env from %s", envFile)
	}

	addr := flag.String("addr", envOr("RELAY_ADDR", ":8787"), "listen address (env: RELAY_ADDR)")
	apnsKeyPath := flag.String("apns-key", os.Getenv("APNS_KEY_PATH"), "path to APNs .p8 auth key (env: APNS_KEY_PATH)")
	apnsKeyID := flag.String("apns-key-id", os.Getenv("APNS_KEY_ID"), "APNs Key ID (env: APNS_KEY_ID)")
	apnsTeamID := flag.String("apns-team-id", os.Getenv("APNS_TEAM_ID"), "APNs Team ID (env: APNS_TEAM_ID)")
	apnsTopic := flag.String("apns-topic", os.Getenv("APNS_TOPIC"), "APNs topic / iOS bundle ID (env: APNS_TOPIC)")
	apnsProduction := flag.Bool("apns-production", envBool("APNS_PRODUCTION", false), "use production APNs endpoint instead of sandbox (env: APNS_PRODUCTION)")
	fcmProjectID := flag.String("fcm-project-id", os.Getenv("FCM_PROJECT_ID"), "Firebase project ID (env: FCM_PROJECT_ID)")
	fcmServiceAccountPath := flag.String("fcm-service-account", os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"), "path to Firebase service-account JSON (env: GOOGLE_APPLICATION_CREDENTIALS)")
	redisURL := flag.String("redis-url", os.Getenv("REDIS_URL"), "Redis URL for the multi-node pub/sub backplane; empty runs single-node (env: REDIS_URL)")
	flag.Parse()

	// APNs .p8 key can come from a base64-encoded env var (preferred for
	// containerized deployment — no key file on disk) or a path on disk.
	keyPEM, err := decodeAPNsKeyB64(os.Getenv("APNS_KEY_B64"))
	if err != nil {
		log.Fatalf("APNS_KEY_B64: %v", err)
	}

	hub := NewHub()

	// Optional Redis backplane. With REDIS_URL set the relay can run multiple
	// replicas behind a load balancer; without it the relay runs single-node
	// with purely in-memory routing and no Redis dependency at runtime.
	if *redisURL != "" {
		bp, err := NewBackplane(context.Background(), *redisURL, hub)
		if err != nil {
			log.Fatalf("init redis backplane: %v", err)
		}
		hub.backplane = bp
		go bp.Run()
		log.Printf("redis backplane enabled — multi-node mode")
	} else {
		log.Printf("no REDIS_URL set — single-node mode (in-memory routing only)")
	}

	go hub.Run()

	var pushSender *PushSender
	if *apnsKeyPath != "" || len(keyPEM) > 0 {
		p, err := NewPushSender(*apnsKeyPath, keyPEM, *apnsKeyID, *apnsTeamID, *apnsTopic, *apnsProduction)
		if err != nil {
			log.Fatalf("init APNs sender: %v", err)
		}
		pushSender = p
		source := "file"
		if len(keyPEM) > 0 && *apnsKeyPath == "" {
			source = "env(APNS_KEY_B64)"
		}
		log.Printf("APNs sender enabled (topic=%s default_production=%v key=%s)", *apnsTopic, *apnsProduction, source)
	} else {
		log.Printf("APNs sender disabled (set APNS_KEY_B64 or -apns-key to enable)")
	}

	var fcmSender *FCMSender
	fcmJSON, fcmSource, err := loadFCMServiceAccount(
		*fcmServiceAccountPath,
		os.Getenv("FCM_SERVICE_ACCOUNT_JSON"),
		os.Getenv("FCM_SERVICE_ACCOUNT_B64"),
	)
	if err != nil {
		log.Fatalf("load FCM service account: %v", err)
	}
	if len(fcmJSON) > 0 {
		p, err := NewFCMSender(*fcmProjectID, fcmJSON)
		if err != nil {
			log.Fatalf("init FCM sender: %v", err)
		}
		fcmSender = p
		log.Printf("FCM sender enabled (project=%s key=%s)", p.projectID, fcmSource)
	} else {
		log.Printf("FCM sender disabled (set FCM_SERVICE_ACCOUNT_B64, FCM_SERVICE_ACCOUNT_JSON, or GOOGLE_APPLICATION_CREDENTIALS to enable)")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeWS)
	mux.HandleFunc("/push", pushHandler(pushSender, fcmSender))
	mux.HandleFunc("/healthz", healthHandler(hub, pushSender, fcmSender))

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

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		log.Printf("env %s: not a bool (%q), using %v", key, v, fallback)
		return fallback
	}
	return b
}

// decodeAPNsKeyB64 accepts either standard or URL-safe base64. Whitespace
// (newlines from shell heredocs, etc.) is stripped before decoding.
func decodeAPNsKeyB64(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	cleaned := strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, s)
	if b, err := base64.StdEncoding.DecodeString(cleaned); err == nil {
		return b, nil
	}
	b, err := base64.URLEncoding.DecodeString(cleaned)
	if err != nil {
		return nil, err
	}
	return b, nil
}
