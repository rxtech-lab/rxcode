package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// openNotionEnvelope mirrors the app's decryption.
func openNotionEnvelope(t *testing.T, priv *ecdh.PrivateKey, epk, nonce, ct []byte) []byte {
	t.Helper()
	peer, err := ecdh.X25519().NewPublicKey(epk)
	if err != nil {
		t.Fatal(err)
	}
	shared, err := priv.ECDH(peer)
	if err != nil {
		t.Fatal(err)
	}
	salt := append(append([]byte{}, epk...), priv.PublicKey().Bytes()...)
	key, err := hkdf.Key(sha256.New, shared, salt, notionEnvelopeInfo, 32)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(key)
	gcm, _ := cipher.NewGCM(block)
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		t.Fatalf("open envelope: %v", err)
	}
	return plain
}

func newTestNotion(t *testing.T, tokenHandler http.HandlerFunc) *NotionOAuth {
	t.Helper()
	server := httptest.NewServer(tokenHandler)
	t.Cleanup(server.Close)
	n := NewNotionOAuth("client-id", "client-secret", "https://relay.test/notion/oauth/callback")
	n.tokenURL = server.URL
	return n
}

func TestNotionStateRejectsTamperingAndExpiry(t *testing.T) {
	n := NewNotionOAuth("id", "secret", "https://relay.test/cb")
	now := time.Now()
	raw, err := n.signState(notionState{PublicKey: "pk", Nonce: "nonce", Expires: now.Add(time.Minute).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	if s, err := n.verifyState(raw, now); err != nil || s.Nonce != "nonce" {
		t.Fatalf("valid state rejected: %v", err)
	}
	if _, err := n.verifyState(raw, now.Add(2*time.Minute)); err == nil {
		t.Fatal("expired state accepted")
	}
	payload, sig, _ := strings.Cut(raw, ".")
	forged := base64.RawURLEncoding.EncodeToString([]byte(`{"pk":"evil","n":"nonce","exp":9999999999}`))
	if _, err := n.verifyState(forged+"."+sig, now); err == nil {
		t.Fatal("forged state accepted")
	}
	other := NewNotionOAuth("id", "other-secret", "https://relay.test/cb")
	if _, err := other.verifyState(payload+"."+sig, now); err == nil {
		t.Fatal("state signed with another secret accepted")
	}
}

func TestNotionStartRedirectsToConsent(t *testing.T) {
	n := NewNotionOAuth("client-id", "secret", "https://relay.test/cb")
	priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pk := base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes())

	rec := httptest.NewRecorder()
	n.handleStart(rec, httptest.NewRequest(http.MethodGet, "/notion/oauth/start?pubkey="+pk+"&nonce=abcdefghijklmnop", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	loc, _ := url.Parse(rec.Header().Get("Location"))
	if !strings.HasPrefix(loc.String(), notionAuthorizeURL) {
		t.Fatalf("unexpected redirect %s", loc)
	}
	q := loc.Query()
	if q.Get("client_id") != "client-id" || q.Get("redirect_uri") != "https://relay.test/cb" || q.Get("owner") != "user" {
		t.Fatalf("bad authorize query %v", q)
	}

	bad := httptest.NewRecorder()
	n.handleStart(bad, httptest.NewRequest(http.MethodGet, "/notion/oauth/start?pubkey=short&nonce=abcdefghijklmnop", nil))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("bad pubkey status %d", bad.Code)
	}
}

func TestNotionCallbackEncryptsTokensForTheApp(t *testing.T) {
	var gotBody map[string]string
	n := newTestNotion(t, func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		if user != "client-id" || pass != "client-secret" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		_, _ = io.WriteString(w, `{"access_token":"ntn_access","refresh_token":"nrt_refresh","workspace_id":"ws","workspace_name":"Acme","bot_id":"bot","owner":{"type":"user"}}`)
	})

	priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
	state, _ := n.signState(notionState{
		PublicKey: base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes()),
		Nonce:     "session-nonce-123456",
		Expires:   time.Now().Add(time.Minute).Unix(),
	})

	rec := httptest.NewRecorder()
	n.handleCallback(rec, httptest.NewRequest(http.MethodGet, "/notion/oauth/callback?code=the-code&state="+url.QueryEscape(state), nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if gotBody["grant_type"] != "authorization_code" || gotBody["code"] != "the-code" {
		t.Fatalf("unexpected token request %v", gotBody)
	}

	loc, _ := url.Parse(rec.Header().Get("Location"))
	if loc.Scheme != "rxcode" || loc.Host != "notion-callback" {
		t.Fatalf("unexpected redirect %s", loc)
	}
	if strings.Contains(loc.String(), "ntn_access") {
		t.Fatal("access token leaked into the redirect URL")
	}
	q := loc.Query()
	if q.Get("n") != "session-nonce-123456" {
		t.Fatalf("nonce not echoed: %v", q)
	}
	decode := func(key string) []byte {
		b, err := base64.RawURLEncoding.DecodeString(q.Get(key))
		if err != nil {
			t.Fatalf("decode %s: %v", key, err)
		}
		return b
	}
	plain := openNotionEnvelope(t, priv, decode("epk"), decode("iv"), decode("ct"))
	var tokens map[string]any
	_ = json.Unmarshal(plain, &tokens)
	if tokens["access_token"] != "ntn_access" || tokens["refresh_token"] != "nrt_refresh" || tokens["workspace_name"] != "Acme" {
		t.Fatalf("unexpected tokens %v", tokens)
	}
	if _, ok := tokens["owner"]; ok {
		t.Fatal("owner details should be stripped")
	}
}

func TestNotionCallbackReturnsDenialToTheApp(t *testing.T) {
	n := NewNotionOAuth("id", "secret", "https://relay.test/cb")
	priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
	state, _ := n.signState(notionState{
		PublicKey: base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes()),
		Nonce:     "session-nonce-123456",
		Expires:   time.Now().Add(time.Minute).Unix(),
	})
	rec := httptest.NewRecorder()
	n.handleCallback(rec, httptest.NewRequest(http.MethodGet, "/cb?error=access_denied&state="+url.QueryEscape(state), nil))
	loc, _ := url.Parse(rec.Header().Get("Location"))
	if loc.Query().Get("error") != "access_denied" || loc.Query().Get("n") != "session-nonce-123456" {
		t.Fatalf("unexpected redirect %s", loc)
	}
}

func TestNotionRefresh(t *testing.T) {
	n := newTestNotion(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["grant_type"] != "refresh_token" || body["refresh_token"] != "nrt_old" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"invalid_grant","error_description":"bad refresh token"}`)
			return
		}
		_, _ = io.WriteString(w, `{"access_token":"ntn_new","refresh_token":"nrt_new"}`)
	})

	rec := httptest.NewRecorder()
	n.handleRefresh(rec, httptest.NewRequest(http.MethodPost, "/refresh", strings.NewReader(`{"refresh_token":"nrt_old"}`)))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "ntn_new") {
		t.Fatalf("refresh failed %d: %s", rec.Code, rec.Body.String())
	}

	bad := httptest.NewRecorder()
	n.handleRefresh(bad, httptest.NewRequest(http.MethodPost, "/refresh", strings.NewReader(`{"refresh_token":"nrt_wrong"}`)))
	if bad.Code != http.StatusBadRequest || !strings.Contains(bad.Body.String(), "bad refresh token") {
		t.Fatalf("expected invalid_grant passthrough, got %d: %s", bad.Code, bad.Body.String())
	}
}

func TestNotionEndpointsUnavailableWithoutCredentials(t *testing.T) {
	if NewNotionOAuth("", "secret", "https://relay.test/cb") != nil {
		t.Fatal("expected nil without client id")
	}
	rec := httptest.NewRecorder()
	notionHandler(nil, (*NotionOAuth).handleStart)(rec, httptest.NewRequest(http.MethodGet, "/notion/oauth/start", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestNotionRedirectURIFollowsTheRelayHost(t *testing.T) {
	var exchanged map[string]string
	n := newTestNotion(t, func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&exchanged)
		_, _ = io.WriteString(w, `{"access_token":"ntn","workspace_id":"ws"}`)
	})
	n.redirectURI = "" // derive from the request, as with no NOTION_REDIRECT_URI

	priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pk := base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes())
	start := func(host, forwardedProto string) *url.URL {
		req := httptest.NewRequest(http.MethodGet, "http://"+host+"/notion/oauth/start?pubkey="+pk+"&nonce=abcdefghijklmnop", nil)
		if forwardedProto != "" {
			req.Header.Set("X-Forwarded-Proto", forwardedProto)
		}
		rec := httptest.NewRecorder()
		n.handleStart(rec, req)
		loc, _ := url.Parse(rec.Header().Get("Location"))
		return loc
	}

	local := start("localhost:8787", "")
	if got := local.Query().Get("redirect_uri"); got != "http://localhost:8787/notion/oauth/callback" {
		t.Fatalf("local redirect_uri = %q", got)
	}
	if got := start("relay.example.com", "https").Query().Get("redirect_uri"); got != "https://relay.example.com/notion/oauth/callback" {
		t.Fatalf("proxied redirect_uri = %q", got)
	}

	// The exchange reuses the redirect URI the flow started with.
	rec := httptest.NewRecorder()
	n.handleCallback(rec, httptest.NewRequest(http.MethodGet, "/notion/oauth/callback?code=c&state="+url.QueryEscape(local.Query().Get("state")), nil))
	if exchanged["redirect_uri"] != "http://localhost:8787/notion/oauth/callback" {
		t.Fatalf("exchange redirect_uri = %q", exchanged["redirect_uri"])
	}

	// A configured redirect URI wins.
	n.redirectURI = "https://pinned.example.com/cb"
	if got := start("localhost:8787", "").Query().Get("redirect_uri"); got != "https://pinned.example.com/cb" {
		t.Fatalf("pinned redirect_uri = %q", got)
	}
}
