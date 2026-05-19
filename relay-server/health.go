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
		status := map[string]any{
			"ok":         true,
			"uptime_sec": int(time.Since(startedAt).Seconds()),
			"peers":      hub.ConnectedCount(),
			"apns":       sender != nil,
			"version":    "0.1.0",
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(status)
	}
}
