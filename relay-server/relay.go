package main

import (
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	maxEnvelopeBytes = 256 * 1024
	pongWait         = 90 * time.Second
	pingPeriod       = 25 * time.Second
	writeWait        = 10 * time.Second
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// Envelope is the relay's wire format. The relay never decrypts `ct`.
type Envelope struct {
	V     int    `json:"v"`
	To    string `json:"to"`
	From  string `json:"from"`
	Nonce string `json:"nonce"`
	Ct    string `json:"ct"`
}

// Conn wraps a websocket connection identified by a hex pubkey.
type Conn struct {
	pubkey string
	ws     *websocket.Conn
	send   chan []byte
	hub    *Hub
}

// Hub maintains the set of live connections and routes envelopes.
type Hub struct {
	mu    sync.RWMutex
	conns map[string]*Conn

	register   chan *Conn
	unregister chan *Conn
	route      chan *Envelope
}

func NewHub() *Hub {
	return &Hub{
		conns:      make(map[string]*Conn),
		register:   make(chan *Conn, 64),
		unregister: make(chan *Conn, 64),
		route:      make(chan *Envelope, 256),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case c := <-h.register:
			h.mu.Lock()
			if existing, ok := h.conns[c.pubkey]; ok {
				close(existing.send)
			}
			h.conns[c.pubkey] = c
			h.mu.Unlock()
			log.Printf("registered %s", short(c.pubkey))
		case c := <-h.unregister:
			h.mu.Lock()
			if current, ok := h.conns[c.pubkey]; ok && current == c {
				delete(h.conns, c.pubkey)
				close(c.send)
			}
			h.mu.Unlock()
			log.Printf("unregistered %s", short(c.pubkey))
		case env := <-h.route:
			h.deliver(env)
		}
	}
}

func (h *Hub) deliver(env *Envelope) {
	raw, err := json.Marshal(env)
	if err != nil {
		log.Printf("marshal envelope: %v", err)
		return
	}
	h.mu.RLock()
	dest, ok := h.conns[env.To]
	h.mu.RUnlock()
	if !ok {
		// Drop on offline. Optionally notify sender.
		h.notifyDeliveryFailed(env.From, env.To)
		return
	}
	select {
	case dest.send <- raw:
	default:
		// Slow consumer; drop and disconnect.
		log.Printf("send buffer full for %s — dropping", short(env.To))
	}
}

func (h *Hub) notifyDeliveryFailed(from, to string) {
	h.mu.RLock()
	src, ok := h.conns[from]
	h.mu.RUnlock()
	if !ok {
		return
	}
	notice := map[string]any{
		"v":    1,
		"type": "delivery_failed",
		"to":   to,
	}
	raw, _ := json.Marshal(notice)
	select {
	case src.send <- raw:
	default:
	}
}

// ConnectedCount returns the number of currently connected WebSocket peers.
func (h *Hub) ConnectedCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.conns)
}

func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request) {
	pubkey := r.URL.Query().Get("pubkey")
	if !isValidPubkeyHex(pubkey) {
		http.Error(w, "invalid pubkey", http.StatusBadRequest)
		return
	}
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade: %v", err)
		return
	}
	ws.SetReadLimit(maxEnvelopeBytes)
	c := &Conn{
		pubkey: pubkey,
		ws:     ws,
		send:   make(chan []byte, 32),
		hub:    h,
	}
	h.register <- c
	go c.writePump()
	c.readPump()
}

func (c *Conn) readPump() {
	defer func() {
		c.hub.unregister <- c
		_ = c.ws.Close()
	}()
	_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))
	c.ws.SetPongHandler(func(string) error {
		_ = c.ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, raw, err := c.ws.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("read error %s: %v", short(c.pubkey), err)
			}
			return
		}
		var env Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			log.Printf("malformed envelope from %s: %v", short(c.pubkey), err)
			continue
		}
		if env.From != c.pubkey {
			// Reject impersonation attempts even though E2E protects the payload.
			log.Printf("from mismatch: header=%s socket=%s", short(env.From), short(c.pubkey))
			continue
		}
		if !isValidPubkeyHex(env.To) {
			continue
		}
		c.hub.route <- &env
	}
}

func (c *Conn) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		_ = c.ws.Close()
	}()
	for {
		select {
		case msg, ok := <-c.send:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				_ = c.ws.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.ws.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			_ = c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func isValidPubkeyHex(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

func short(pubkey string) string {
	if len(pubkey) < 8 {
		return pubkey
	}
	return pubkey[:8]
}
