package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
)

// PushSender wraps APNs HTTP/2 client.
type PushSender struct {
	client *apns2.Client
	topic  string
}

// NewPushSender loads the APNs auth key and prepares the HTTP/2 client.
//
// Exactly one of `keyPath` or `keyPEM` must be non-empty. `keyPEM` is the raw
// `.p8` contents (already base64-decoded if it was wrapped for env transport).
func NewPushSender(keyPath string, keyPEM []byte, keyID, teamID, topic string, production bool) (*PushSender, error) {
	if keyID == "" || teamID == "" || topic == "" {
		return nil, fmt.Errorf("apns key id, team id, and topic are required")
	}
	var keyBytes []byte
	switch {
	case len(keyPEM) > 0:
		keyBytes = keyPEM
	case keyPath != "":
		b, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, fmt.Errorf("read apns key: %w", err)
		}
		keyBytes = b
	default:
		return nil, fmt.Errorf("apns key not provided (set APNS_KEY_B64 or -apns-key)")
	}
	authKey, err := token.AuthKeyFromBytes(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("parse apns key: %w", err)
	}
	tok := &token.Token{
		AuthKey: authKey,
		KeyID:   keyID,
		TeamID:  teamID,
	}
	client := apns2.NewTokenClient(tok)
	if production {
		client = client.Production()
	} else {
		client = client.Development()
	}
	return &PushSender{client: client, topic: topic}, nil
}

// PushRequest is the JSON body accepted by POST /push.
//
// `EncryptedAlertB64` is an opaque base64 blob produced by the desktop sender —
// the relay never decrypts it. The mobile Notification Service Extension
// decrypts it before iOS shows the banner.
type PushRequest struct {
	DeviceToken       string `json:"device_token"`
	EncryptedAlertB64 string `json:"encrypted_alert"`
	Category          string `json:"category,omitempty"`
	CollapseID        string `json:"collapse_id,omitempty"`
}

// pushHandler returns an http.HandlerFunc that signs and forwards APNs pushes.
//
// Auth is intentionally minimal in v1: any client may submit, since the
// payload itself is E2E-encrypted to the recipient device. A future hardening
// pass should require a signed sender token (see plan: risk areas).
func pushHandler(sender *PushSender) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if sender == nil {
			http.Error(w, "apns disabled on this relay", http.StatusServiceUnavailable)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 64*1024))
		if err != nil {
			http.Error(w, "read body", http.StatusBadRequest)
			return
		}
		var req PushRequest
		if err := json.Unmarshal(body, &req); err != nil {
			http.Error(w, "malformed body", http.StatusBadRequest)
			return
		}
		if req.DeviceToken == "" || req.EncryptedAlertB64 == "" {
			http.Error(w, "missing fields", http.StatusBadRequest)
			return
		}
		if _, err := base64.StdEncoding.DecodeString(req.EncryptedAlertB64); err != nil {
			http.Error(w, "encrypted_alert must be base64", http.StatusBadRequest)
			return
		}

		// Payload structure: mutable-content=1 triggers Notification Service
		// Extension on the device; the extension decrypts `enc` and rewrites
		// the visible alert before display.
		payload := map[string]any{
			"aps": map[string]any{
				"alert": map[string]string{
					"title": "RxCode",
					"body":  "Encrypted notification",
				},
				"mutable-content": 1,
				"sound":           "default",
			},
			"enc": req.EncryptedAlertB64,
		}
		raw, _ := json.Marshal(payload)

		notif := &apns2.Notification{
			DeviceToken: req.DeviceToken,
			Topic:       sender.topic,
			Payload:     raw,
		}
		if req.Category != "" {
			notif.PushType = apns2.PushTypeAlert
		}
		if req.CollapseID != "" {
			notif.CollapseID = req.CollapseID
		}

		res, err := sender.client.Push(notif)
		if err != nil {
			log.Printf(
				"apns push transport error: %v device=%s category=%q collapse_id=%q collapse_len=%d",
				err,
				short(req.DeviceToken),
				req.Category,
				req.CollapseID,
				len(req.CollapseID),
			)
			http.Error(w, "apns push failed", http.StatusBadGateway)
			return
		}
		if !res.Sent() {
			log.Printf(
				"apns push rejected: status=%d reason=%q apns_id=%s device=%s category=%q collapse_id=%q collapse_len=%d",
				res.StatusCode,
				res.Reason,
				res.ApnsID,
				short(req.DeviceToken),
				req.Category,
				req.CollapseID,
				len(req.CollapseID),
			)
		}
		resp := map[string]any{
			"status_code": res.StatusCode,
			"reason":      res.Reason,
			"apns_id":     res.ApnsID,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}
}
