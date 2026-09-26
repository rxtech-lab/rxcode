package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// Notion OAuth for the RxCode desktop app.
//
// Notion's token exchange needs the integration's client secret, which can't
// ship inside the app, so the relay does the exchange:
//
//  1. The app opens GET /notion/oauth/start?pubkey=<X25519>&nonce=<id> in a
//     web auth session. The relay signs both into `state` and redirects to
//     Notion's consent page.
//  2. Notion redirects to GET /notion/oauth/callback. The relay exchanges the
//     code, encrypts the token response to the app's public key, and
//     redirects to rxcode://notion-callback with the ciphertext.
//  3. POST /notion/oauth/refresh swaps a refresh token for a new access token.
//
// Like the sync channel, the relay is stateless: everything it needs between
// steps 1 and 2 travels in the HMAC-signed state, so any replica can serve
// the callback. Tokens never appear in plaintext in a URL.

const (
	notionAuthorizeURL   = "https://api.notion.com/v1/oauth/authorize"
	notionTokenURL       = "https://api.notion.com/v1/oauth/token"
	notionAppCallbackURL = "rxcode://notion-callback"
	notionStateTTL       = 15 * time.Minute
	// notionEnvelopeInfo is the HKDF info string; the app derives the same
	// key with it. Bump the suffix if the envelope format ever changes.
	notionEnvelopeInfo = "rxcode-notion-oauth-v1"
)

var notionNoncePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

// NotionOAuth holds the public integration's credentials.
type NotionOAuth struct {
	clientID     string
	clientSecret string
	// redirectURI pins the callback URL. Empty derives it from the host the
	// start request reached, so a relay on localhost or a custom domain
	// works without extra config — Notion still only accepts redirect URIs
	// registered on the integration, so a spoofed Host goes nowhere.
	redirectURI string
	tokenURL    string
	httpClient  *http.Client
}

// NewNotionOAuth returns nil when the integration isn't configured; the
// endpoints then answer 503 so the app can tell the feature is unavailable.
// An empty redirectURI is derived per request; see `callbackURL`.
func NewNotionOAuth(clientID, clientSecret, redirectURI string) *NotionOAuth {
	if clientID == "" || clientSecret == "" {
		return nil
	}
	return &NotionOAuth{
		clientID:     clientID,
		clientSecret: clientSecret,
		redirectURI:  redirectURI,
		tokenURL:     notionTokenURL,
		httpClient:   &http.Client{Timeout: 20 * time.Second},
	}
}

// notionState is what the relay remembers between start and callback.
type notionState struct {
	PublicKey string `json:"pk"`
	Nonce     string `json:"n"`
	Expires   int64  `json:"exp"`
	// RedirectURI sent to Notion's consent page. The code exchange must send
	// the identical value, so it travels in the signed state.
	RedirectURI string `json:"ru"`
}

// callbackURL is the redirect URI for a flow started by `r`: the configured
// one, or this relay's own /notion/oauth/callback as reached by the client.
// Behind a TLS-terminating proxy, X-Forwarded-Proto supplies the scheme.
func (n *NotionOAuth) callbackURL(r *http.Request) string {
	if n.redirectURI != "" {
		return n.redirectURI
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		scheme = strings.ToLower(strings.TrimSpace(strings.Split(proto, ",")[0]))
	}
	return (&url.URL{Scheme: scheme, Host: r.Host, Path: "/notion/oauth/callback"}).String()
}

func (n *NotionOAuth) stateMAC(payload string) []byte {
	mac := hmac.New(sha256.New, []byte("notion-state:"+n.clientSecret))
	mac.Write([]byte(payload))
	return mac.Sum(nil)
}

func (n *NotionOAuth) signState(s notionState) (string, error) {
	raw, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	return payload + "." + base64.RawURLEncoding.EncodeToString(n.stateMAC(payload)), nil
}

func (n *NotionOAuth) verifyState(raw string, now time.Time) (notionState, error) {
	var s notionState
	payload, sig, ok := strings.Cut(raw, ".")
	if !ok {
		return s, errors.New("malformed state")
	}
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil || !hmac.Equal(got, n.stateMAC(payload)) {
		return s, errors.New("state signature mismatch")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return s, errors.New("malformed state")
	}
	if err := json.Unmarshal(decoded, &s); err != nil {
		return s, errors.New("malformed state")
	}
	if now.Unix() > s.Expires {
		return s, errors.New("sign-in link expired, please try again")
	}
	return s, nil
}

// handleStart redirects the web auth session to Notion's consent page.
func (n *NotionOAuth) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	q := r.URL.Query()
	pub, err := base64.RawURLEncoding.DecodeString(q.Get("pubkey"))
	if err != nil || len(pub) != 32 {
		http.Error(w, "pubkey must be a base64url X25519 public key", http.StatusBadRequest)
		return
	}
	nonce := q.Get("nonce")
	if !notionNoncePattern.MatchString(nonce) {
		http.Error(w, "nonce must be 16-128 base64url characters", http.StatusBadRequest)
		return
	}
	redirectURI := n.callbackURL(r)
	state, err := n.signState(notionState{
		PublicKey:   q.Get("pubkey"),
		Nonce:       nonce,
		Expires:     time.Now().Add(notionStateTTL).Unix(),
		RedirectURI: redirectURI,
	})
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	target := url.Values{
		"client_id":     {n.clientID},
		"response_type": {"code"},
		"owner":         {"user"},
		"redirect_uri":  {redirectURI},
		"state":         {state},
	}
	http.Redirect(w, r, notionAuthorizeURL+"?"+target.Encode(), http.StatusFound)
}

// handleCallback exchanges Notion's code and hands the encrypted token to
// the app.
func (n *NotionOAuth) handleCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	state, err := n.verifyState(q.Get("state"), time.Now())
	if err != nil {
		// Without a trusted state there's no app session to return to.
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	fail := func(message string) {
		redirectToApp(w, r, url.Values{"n": {state.Nonce}, "error": {message}})
	}
	if denied := q.Get("error"); denied != "" {
		fail(denied)
		return
	}
	code := q.Get("code")
	if code == "" {
		fail("missing authorization code")
		return
	}

	tokens, status, err := n.requestToken(r, map[string]string{
		"grant_type":   "authorization_code",
		"code":         code,
		"redirect_uri": state.RedirectURI,
	})
	if err != nil {
		log.Printf("notion: code exchange failed (%d): %v", status, err)
		fail("token exchange failed: " + err.Error())
		return
	}

	pub, _ := base64.RawURLEncoding.DecodeString(state.PublicKey)
	epk, nonce, ct, err := sealNotionEnvelope(pub, tokens)
	if err != nil {
		log.Printf("notion: seal failed: %v", err)
		fail("could not encrypt the token")
		return
	}
	redirectToApp(w, r, url.Values{
		"n":   {state.Nonce},
		"epk": {base64.RawURLEncoding.EncodeToString(epk)},
		"iv":  {base64.RawURLEncoding.EncodeToString(nonce)},
		"ct":  {base64.RawURLEncoding.EncodeToString(ct)},
		"v":   {"1"},
	})
}

// handleRefresh swaps a refresh token for new tokens. The body and response
// travel over TLS, never in a URL.
func (n *NotionOAuth) handleRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 16<<10)).Decode(&body); err != nil || body.RefreshToken == "" {
		writeJSONError(w, http.StatusBadRequest, "refresh_token is required")
		return
	}
	tokens, status, err := n.requestToken(r, map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": body.RefreshToken,
	})
	if err != nil {
		if status < 400 {
			status = http.StatusBadGateway
		}
		writeJSONError(w, status, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(tokens)
}

// requestToken calls Notion's token endpoint and returns the response with
// only the fields the app needs, so identity details aren't passed along.
func (n *NotionOAuth) requestToken(r *http.Request, body map[string]string) ([]byte, int, error) {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, n.tokenURL, bytes.NewReader(raw))
	if err != nil {
		return nil, 0, err
	}
	req.SetBasicAuth(n.clientID, n.clientSecret)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := n.httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return nil, resp.StatusCode, err
	}

	var parsed struct {
		AccessToken      string  `json:"access_token"`
		RefreshToken     *string `json:"refresh_token"`
		WorkspaceID      string  `json:"workspace_id"`
		WorkspaceName    *string `json:"workspace_name"`
		WorkspaceIcon    *string `json:"workspace_icon"`
		BotID            string  `json:"bot_id"`
		ErrorCode        string  `json:"error"`
		ErrorDescription string  `json:"error_description"`
		Message          string  `json:"message"`
	}
	_ = json.Unmarshal(data, &parsed)
	if resp.StatusCode/100 != 2 || parsed.AccessToken == "" {
		msg := parsed.ErrorDescription
		if msg == "" {
			msg = parsed.Message
		}
		if msg == "" {
			msg = parsed.ErrorCode
		}
		if msg == "" {
			msg = fmt.Sprintf("notion returned HTTP %d", resp.StatusCode)
		}
		return nil, resp.StatusCode, errors.New(msg)
	}

	out, err := json.Marshal(map[string]any{
		"access_token":   parsed.AccessToken,
		"refresh_token":  parsed.RefreshToken,
		"workspace_id":   parsed.WorkspaceID,
		"workspace_name": parsed.WorkspaceName,
		"workspace_icon": parsed.WorkspaceIcon,
		"bot_id":         parsed.BotID,
	})
	return out, resp.StatusCode, err
}

// sealNotionEnvelope encrypts `plaintext` to the app's X25519 public key:
// an ephemeral X25519 key agreement, HKDF-SHA256 (salt = ephemeral public
// key ‖ app public key) and AES-256-GCM. The returned ciphertext has the GCM
// tag appended, as CryptoKit's `AES.GCM.SealedBox` expects to split it.
func sealNotionEnvelope(appPublicKey, plaintext []byte) (epk, nonce, ciphertext []byte, err error) {
	curve := ecdh.X25519()
	peer, err := curve.NewPublicKey(appPublicKey)
	if err != nil {
		return nil, nil, nil, err
	}
	ephemeral, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}
	shared, err := ephemeral.ECDH(peer)
	if err != nil {
		return nil, nil, nil, err
	}
	epk = ephemeral.PublicKey().Bytes()
	salt := append(append([]byte{}, epk...), appPublicKey...)
	key, err := hkdf.Key(sha256.New, shared, salt, notionEnvelopeInfo, 32)
	if err != nil {
		return nil, nil, nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, nil, err
	}
	nonce = make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, nil, err
	}
	return epk, nonce, gcm.Seal(nil, nonce, plaintext, nil), nil
}

func redirectToApp(w http.ResponseWriter, r *http.Request, values url.Values) {
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, notionAppCallbackURL+"?"+values.Encode(), http.StatusFound)
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

// notionHandler wraps an endpoint so an unconfigured relay answers 503.
func notionHandler(n *NotionOAuth, handle func(*NotionOAuth, http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if n == nil {
			writeJSONError(w, http.StatusServiceUnavailable, "Notion sign-in is not configured on this relay")
			return
		}
		handle(n, w, r)
	}
}
