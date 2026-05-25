package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
)

// PushSender wraps APNs HTTP/2 client.
type PushSender struct {
	developmentClient  *apns2.Client
	productionClient   *apns2.Client
	topic              string
	defaultEnvironment APNSEnvironment
}

type APNSEnvironment string

const (
	apnsEnvironmentSandbox    APNSEnvironment = "sandbox"
	apnsEnvironmentProduction APNSEnvironment = "production"
)

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
	defaultEnvironment := apnsEnvironmentSandbox
	if production {
		defaultEnvironment = apnsEnvironmentProduction
	}
	return &PushSender{
		developmentClient:  apns2.NewTokenClient(tok).Development(),
		productionClient:   apns2.NewTokenClient(tok).Production(),
		topic:              topic,
		defaultEnvironment: defaultEnvironment,
	}, nil
}

// Push delivery modes accepted by POST /push.
const (
	pushProviderAPNs = "apns"
	pushProviderFCM  = "fcm"

	// pushModeAlert is the legacy encrypted-banner path: the desktop ships an
	// opaque E2E-encrypted blob and the iOS Notification Service Extension
	// decrypts it before the banner is shown. This is the default when
	// `push_type` is empty.
	pushModeAlert = "alert"
	// pushModeLiveActivity carries an ActivityKit start/update/end payload.
	// Live Activity content-state cannot be E2E encrypted because ActivityKit
	// consumes it directly, so `apns_payload` is forwarded verbatim.
	pushModeLiveActivity = "liveactivity"
	// pushModeBackground is a silent content-available push used to refresh
	// the home-screen widget. The widget snapshot inside `apns_payload` is
	// E2E-encrypted to the recipient device (under `encWidget`); the relay
	// forwards `apns_payload` verbatim and never decrypts it.
	pushModeBackground = "background"
)

// PushRequest is the JSON body accepted by POST /push.
//
// For the legacy alert path, `encrypted_alert` is an opaque base64 blob
// produced by the desktop sender — the relay never decrypts it. For the
// `liveactivity` and `background` paths, `apns_payload` is the complete APNs
// JSON payload (`{"aps": {…}, …}`) built by the desktop and forwarded verbatim.
type PushRequest struct {
	Provider          string `json:"provider,omitempty"`
	DeviceToken       string `json:"device_token"`
	EncryptedAlertB64 string `json:"encrypted_alert,omitempty"`
	Category          string `json:"category,omitempty"`
	CollapseID        string `json:"collapse_id,omitempty"`
	// APNSEnvironment selects the APNs endpoint for this device token. Accepted
	// values are "sandbox" and "production". Empty falls back to the relay's
	// APNS_PRODUCTION default for compatibility with older desktop builds.
	APNSEnvironment string `json:"apns_environment,omitempty"`
	// Environment is accepted as a compatibility alias for APNSEnvironment.
	Environment string `json:"environment,omitempty"`
	// PushType selects the delivery mode: "" / "alert", "liveactivity", or
	// "background". Unknown values are rejected.
	PushType string `json:"push_type,omitempty"`
	// APNSPayload is the raw APNs JSON, required for "liveactivity" and
	// "background". Ignored for the alert path.
	APNSPayload json.RawMessage `json:"apns_payload,omitempty"`
}

// pushHandler returns an http.HandlerFunc that signs and forwards APNs pushes.
//
// Auth is intentionally minimal in v1: any client may submit, since both the
// alert and the widget payloads are themselves E2E-encrypted to the recipient
// device. Only Live Activity content-state is unencrypted (ActivityKit
// consumes it directly); a future hardening pass should require a signed
// sender token.
func pushHandler(apnsSender *PushSender, fcmSender *FCMSender) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
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
		if req.DeviceToken == "" {
			http.Error(w, "missing device_token", http.StatusBadRequest)
			return
		}

		provider := strings.ToLower(strings.TrimSpace(req.Provider))
		if provider == "" {
			provider = pushProviderAPNs
		}
		if provider == pushProviderFCM {
			if fcmSender == nil {
				http.Error(w, "fcm disabled on this relay", http.StatusServiceUnavailable)
				return
			}
			sendFCMResponse(w, fcmSender, &req)
			return
		}
		if provider != pushProviderAPNs {
			http.Error(w, "unknown push provider", http.StatusBadRequest)
			return
		}
		if apnsSender == nil {
			http.Error(w, "apns disabled on this relay", http.StatusServiceUnavailable)
			return
		}

		mode := req.PushType
		if mode == "" {
			mode = pushModeAlert
		}
		environment, err := apnsSender.environmentForRequest(&req)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		var notif *apns2.Notification
		switch mode {
		case pushModeAlert:
			notif, err = buildAlertNotification(apnsSender, &req)
		case pushModeLiveActivity:
			notif, err = buildRawNotification(apnsSender, &req, apns2.PushTypeLiveActivity, apns2.PriorityHigh, true)
		case pushModeBackground:
			notif, err = buildRawNotification(apnsSender, &req, apns2.PushTypeBackground, apns2.PriorityLow, false)
		default:
			http.Error(w, "unknown push_type", http.StatusBadRequest)
			return
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		payloadBytes, _ := notif.Payload.([]byte)
		log.Printf(
			"apns push send: mode=%s environment=%s device=%s category=%q collapse_id=%q payload_bytes=%d",
			mode, environment, short(req.DeviceToken), req.Category, req.CollapseID, len(payloadBytes),
		)

		res, err := apnsSender.clientForEnvironment(environment).Push(notif)
		if err != nil {
			log.Printf(
				"apns push transport error: %v mode=%s environment=%s device=%s category=%q",
				err, mode, environment, short(req.DeviceToken), req.Category,
			)
			http.Error(w, "apns push failed", http.StatusBadGateway)
			return
		}
		if res.Sent() {
			log.Printf(
				"apns push sent: mode=%s environment=%s status=%d apns_id=%s device=%s",
				mode, environment, res.StatusCode, res.ApnsID, short(req.DeviceToken),
			)
		} else {
			log.Printf(
				"apns push rejected: mode=%s environment=%s status=%d reason=%q apns_id=%s device=%s",
				mode, environment, res.StatusCode, res.Reason, res.ApnsID, short(req.DeviceToken),
			)
		}
		resp := map[string]any{
			"provider":         pushProviderAPNs,
			"status_code":      res.StatusCode,
			"reason":           res.Reason,
			"apns_id":          res.ApnsID,
			"apns_environment": string(environment),
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}
}

func (s *PushSender) environmentForRequest(req *PushRequest) (APNSEnvironment, error) {
	raw := req.APNSEnvironment
	if raw == "" {
		raw = req.Environment
	}
	return parseAPNSEnvironment(raw, s.defaultEnvironment)
}

func (s *PushSender) clientForEnvironment(environment APNSEnvironment) *apns2.Client {
	if environment == apnsEnvironmentProduction {
		return s.productionClient
	}
	return s.developmentClient
}

func parseAPNSEnvironment(raw string, fallback APNSEnvironment) (APNSEnvironment, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "":
		return fallback, nil
	case "sandbox", "development", "dev":
		return apnsEnvironmentSandbox, nil
	case "production", "prod", "release":
		return apnsEnvironmentProduction, nil
	default:
		return "", fmt.Errorf("unknown apns_environment")
	}
}

// buildAlertNotification wraps the desktop's E2E-encrypted blob in the static
// envelope the iOS Notification Service Extension expects. `mutable-content=1`
// triggers the extension, which decrypts `enc` and rewrites the visible alert.
func buildAlertNotification(sender *PushSender, req *PushRequest) (*apns2.Notification, error) {
	if req.EncryptedAlertB64 == "" {
		return nil, fmt.Errorf("missing encrypted_alert")
	}
	if _, err := base64.StdEncoding.DecodeString(req.EncryptedAlertB64); err != nil {
		return nil, fmt.Errorf("encrypted_alert must be base64")
	}
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
	return notif, nil
}

// buildRawNotification forwards the desktop-built APNs payload verbatim. Used
// for Live Activity and background (widget) pushes. Live Activity content-state
// cannot be E2E encrypted (ActivityKit consumes it directly); the widget
// background push carries an E2E-encrypted blob the app decrypts itself. Either
// way the relay forwards `apns_payload` untouched. When `liveActivityTopic` is
// set, the APNs topic is suffixed with `.push-type.liveactivity` as Apple
// requires for Live Activity pushes.
func buildRawNotification(
	sender *PushSender,
	req *PushRequest,
	pushType apns2.EPushType,
	priority int,
	liveActivityTopic bool,
) (*apns2.Notification, error) {
	if len(req.APNSPayload) == 0 {
		return nil, fmt.Errorf("missing apns_payload")
	}
	if !json.Valid(req.APNSPayload) {
		return nil, fmt.Errorf("apns_payload must be valid JSON")
	}
	topic := sender.topic
	if liveActivityTopic {
		topic = sender.topic + ".push-type.liveactivity"
	}
	notif := &apns2.Notification{
		DeviceToken: req.DeviceToken,
		Topic:       topic,
		Payload:     []byte(req.APNSPayload),
		PushType:    pushType,
		Priority:    priority,
	}
	if req.CollapseID != "" {
		notif.CollapseID = req.CollapseID
	}
	return notif, nil
}
