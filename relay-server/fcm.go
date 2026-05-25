package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

const firebaseMessagingScope = "https://www.googleapis.com/auth/firebase.messaging"

type FCMSender struct {
	projectID   string
	clientEmail string
	privateKey  any
	tokenURI    string
	httpClient  *http.Client

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
}

type fcmServiceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

func NewFCMSender(projectID string, serviceAccountJSON []byte) (*FCMSender, error) {
	var account fcmServiceAccount
	if err := json.Unmarshal(serviceAccountJSON, &account); err != nil {
		return nil, fmt.Errorf("parse fcm service account: %w", err)
	}
	if projectID == "" {
		projectID = account.ProjectID
	}
	if projectID == "" || account.ClientEmail == "" || account.PrivateKey == "" {
		return nil, fmt.Errorf("fcm project id, client email, and private key are required")
	}
	tokenURI := account.TokenURI
	if tokenURI == "" {
		tokenURI = "https://oauth2.googleapis.com/token"
	}
	privateKey, err := jwt.ParseRSAPrivateKeyFromPEM([]byte(account.PrivateKey))
	if err != nil {
		return nil, fmt.Errorf("parse fcm private key: %w", err)
	}
	return &FCMSender{
		projectID:   projectID,
		clientEmail: account.ClientEmail,
		privateKey:  privateKey,
		tokenURI:    tokenURI,
		httpClient:  &http.Client{Timeout: 10 * time.Second},
	}, nil
}

func loadFCMServiceAccount(path, raw, rawB64 string) ([]byte, string, error) {
	switch {
	case strings.TrimSpace(raw) != "":
		return []byte(raw), "env(FCM_SERVICE_ACCOUNT_JSON)", nil
	case strings.TrimSpace(rawB64) != "":
		cleaned := strings.Map(func(r rune) rune {
			if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
				return -1
			}
			return r
		}, rawB64)
		if b, err := base64.StdEncoding.DecodeString(cleaned); err == nil {
			return b, "env(FCM_SERVICE_ACCOUNT_B64)", nil
		}
		b, err := base64.URLEncoding.DecodeString(cleaned)
		if err != nil {
			return nil, "", err
		}
		return b, "env(FCM_SERVICE_ACCOUNT_B64)", nil
	case strings.TrimSpace(path) != "":
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, "", err
		}
		return b, "file", nil
	default:
		return nil, "", nil
	}
}

func (s *FCMSender) Send(ctx context.Context, req *PushRequest) (*FCMPushResponse, error) {
	if req.EncryptedAlertB64 == "" {
		return nil, fmt.Errorf("encrypted_alert is required for fcm")
	}
	token, err := s.bearerToken(ctx)
	if err != nil {
		return nil, err
	}

	data := map[string]string{
		"enc":             req.EncryptedAlertB64,
		"encrypted_alert": req.EncryptedAlertB64,
	}
	if req.Category != "" {
		data["category"] = req.Category
	}
	if req.CollapseID != "" {
		data["collapse_id"] = req.CollapseID
	}

	android := map[string]any{"priority": "HIGH"}
	if req.CollapseID != "" {
		android["collapse_key"] = req.CollapseID
	}
	body := map[string]any{
		"message": map[string]any{
			"token":   req.DeviceToken,
			"data":    data,
			"android": android,
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	endpoint := fmt.Sprintf("https://fcm.googleapis.com/v1/projects/%s/messages:send", url.PathEscape(s.projectID))
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+token)
	httpReq.Header.Set("Content-Type", "application/json")

	res, err := s.httpClient.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(res.Body, 64*1024))
	out := &FCMPushResponse{StatusCode: res.StatusCode}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		var success struct {
			Name string `json:"name"`
		}
		_ = json.Unmarshal(responseBody, &success)
		out.MessageID = success.Name
		return out, nil
	}

	var failure struct {
		Error struct {
			Message string `json:"message"`
			Status  string `json:"status"`
		} `json:"error"`
	}
	_ = json.Unmarshal(responseBody, &failure)
	out.Reason = failure.Error.Message
	if out.Reason == "" {
		out.Reason = strings.TrimSpace(string(responseBody))
	}
	return out, nil
}

func (s *FCMSender) bearerToken(ctx context.Context) (string, error) {
	s.mu.Lock()
	if s.accessToken != "" && time.Now().Before(s.tokenExpiry.Add(-1*time.Minute)) {
		token := s.accessToken
		s.mu.Unlock()
		return token, nil
	}
	s.mu.Unlock()

	now := time.Now()
	claims := jwt.MapClaims{
		"iss":   s.clientEmail,
		"scope": firebaseMessagingScope,
		"aud":   s.tokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(s.privateKey)
	if err != nil {
		return "", err
	}
	values := url.Values{}
	values.Set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
	values.Set("assertion", assertion)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.tokenURI, strings.NewReader(values.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	res, err := s.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 64*1024))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return "", fmt.Errorf("fcm token exchange failed (%d): %s", res.StatusCode, strings.TrimSpace(string(body)))
	}
	var tokenResponse struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tokenResponse); err != nil {
		return "", err
	}
	if tokenResponse.AccessToken == "" {
		return "", fmt.Errorf("fcm token exchange returned empty access token")
	}
	expiresIn := tokenResponse.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = 3600
	}

	s.mu.Lock()
	s.accessToken = tokenResponse.AccessToken
	s.tokenExpiry = time.Now().Add(time.Duration(expiresIn) * time.Second)
	s.mu.Unlock()
	return tokenResponse.AccessToken, nil
}

type FCMPushResponse struct {
	StatusCode int    `json:"status_code"`
	Reason     string `json:"reason,omitempty"`
	MessageID  string `json:"message_id,omitempty"`
}

func sendFCMResponse(w http.ResponseWriter, sender *FCMSender, req *PushRequest) {
	log.Printf(
		"fcm push send: device=%s category=%q collapse_id=%q encrypted_bytes=%d",
		short(req.DeviceToken), req.Category, req.CollapseID, len(req.EncryptedAlertB64),
	)
	res, err := sender.Send(context.Background(), req)
	if err != nil {
		log.Printf("fcm push transport error: %v device=%s category=%q", err, short(req.DeviceToken), req.Category)
		http.Error(w, "fcm push failed", http.StatusBadGateway)
		return
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		log.Printf("fcm push sent: status=%d message_id=%s device=%s", res.StatusCode, res.MessageID, short(req.DeviceToken))
	} else {
		log.Printf("fcm push rejected: status=%d reason=%q device=%s", res.StatusCode, res.Reason, short(req.DeviceToken))
	}
	resp := map[string]any{
		"provider":    pushProviderFCM,
		"status_code": res.StatusCode,
		"reason":      res.Reason,
		"message_id":  res.MessageID,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}
