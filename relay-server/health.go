package main

import (
	"encoding/json"
	"net/http"
	"time"
)

var startedAt = time.Now()

// healthHandler returns a JSON liveness probe with current connection count
// and APNs availability. Used by orchestrators and by the desktop "Mobile"
// settings tab to verify the configured relay is reachable.
func healthHandler(hub *Hub, sender *PushSender) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		mode := "single-node"
		if hub.backplane != nil {
			mode = "multi-node"
		}
		status := map[string]any{
			"ok":         true,
			"uptime_sec": int(time.Since(startedAt).Seconds()),
			"peers":      hub.ConnectedCount(),
			"apns":       sender != nil,
			"mode":       mode,
			"version":    "0.2.0",
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(status)
	}
}
