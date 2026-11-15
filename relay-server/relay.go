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
	// Keep this aligned with RelayClient.maxWebSocketMessageSize. Mobile
	// thread snapshots are paged, but an encrypted envelope still carries
	// active messages, session summaries, briefings, and base64 overhead.
	maxEnvelopeBytes = 10 * 1024 * 1024
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
	// registeredAt orders connections for the same pubkey across replicas.
	registeredAt time.Time
}

// Hub maintains the set of live connections and routes envelopes.
//
// Every mutation of `conns` and every send on (or close of) a `Conn.send`
// channel happens on the hub goroutine (`Run`). Other goroutines — the Redis
// backplane subscriber and publisher — post work through channels instead, so
// a connection can never be closed while another goroutine is sending to it.
type Hub struct {
	mu    sync.RWMutex
	conns map[string]*Conn

	register   chan *Conn
	unregister chan *Conn
	route      chan *Envelope
	// remote carries envelopes received from other replicas via the backplane.
	remote chan *Envelope
	// evict carries pubkeys that just registered on another replica; any local
	// connection for them is stale and must be dropped.
	evict chan evictRequest
	// failed carries delivery_failed notices computed off the hub loop.
	failed chan deliveryFailure

	// backplane fans envelopes to other replicas over Redis. nil means the
	// relay runs single-node and routes purely from the in-memory map.
	backplane *Backplane
}

type evictRequest struct {
	pubkey       string
	registeredAt time.Time
}

type deliveryFailure struct {
	from string
	to   string
}

func NewHub() *Hub {
	return &Hub{
		conns:      make(map[string]*Conn),
		register:   make(chan *Conn, 64),
		unregister: make(chan *Conn, 64),
		route:      make(chan *Envelope, 256),
		remote:     make(chan *Envelope, 256),
		evict:      make(chan evictRequest, 64),
		failed:     make(chan deliveryFailure, 64),
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
			if h.backplane != nil {
				h.backplane.MarkPresent(c.pubkey)
				// A client that reconnects (network switch, app resume) can
				// land on a different replica than its previous socket. The
				// old replica keeps that half-open socket until pongWait
				// expires and would swallow every envelope sent by peers on
				// that replica. Tell the others to drop it now.
				h.backplane.AnnounceRegistered(c.pubkey, c.registeredAt)
			}
			log.Printf("registered %s", short(c.pubkey))
		case c := <-h.unregister:
			h.mu.Lock()
			removed := false
			if current, ok := h.conns[c.pubkey]; ok && current == c {
				delete(h.conns, c.pubkey)
				close(c.send)
				removed = true
			}
			h.mu.Unlock()
			// Only clear cluster presence when this exact connection was the
			// one removed — a reconnect that already replaced it must keep its
			// presence marker intact.
			if removed && h.backplane != nil {
				h.backplane.ClearPresence(c.pubkey)
			}
			log.Printf("unregistered %s", short(c.pubkey))
		case env := <-h.route:
			h.deliver(env)
		case env := <-h.remote:
			h.deliverLocal(env)
		case req := <-h.evict:
			h.evictLocal(req)
		case f := <-h.failed:
			h.notifyDeliveryFailed(f.from, f.to)
		}
	}
}

// deliver routes an envelope to its recipient. The recipient may be connected
// to this pod, to another pod (reached via the Redis backplane), or offline.
func (h *Hub) deliver(env *Envelope) {
	if h.deliverLocal(env) {
		return
	}
	// Not connected to this pod.
	if h.backplane != nil {
		// Another replica may hold the connection. The backplane round-trips
		// to Redis, so hand it to the backplane's single ordered publisher to
		// keep local routing fast without reordering a peer's envelopes.
		h.backplane.Enqueue(env)
		return
	}
	// Single-node: a missing local connection means the peer is offline.
	h.notifyDeliveryFailed(env.From, env.To)
}

// deliverLocal delivers an envelope to a recipient connected to this pod and
// reports whether such a connection existed. It never touches the backplane,
// so it is safe to call on envelopes arriving from the backplane without
// risking a re-publish loop. Must run on the hub goroutine.
func (h *Hub) deliverLocal(env *Envelope) bool {
	raw, err := json.Marshal(env)
	if err != nil {
		log.Printf("marshal envelope: %v", err)
		return false
	}
	h.mu.RLock()
	dest, ok := h.conns[env.To]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	select {
	case dest.send <- raw:
	default:
		// Slow consumer; drop and disconnect.
		log.Printf("send buffer full for %s — dropping", short(env.To))
	}
	return true
}

// evictLocal drops this pod's connection for a pubkey that registered on
// another replica. Closing `send` makes writePump send a close frame and shut
// the socket; the later unregister is a no-op because the entry is gone, so
// the presence key now owned by the other replica is left intact. Must run on
// the hub goroutine.
func (h *Hub) evictLocal(req evictRequest) {
	pubkey := req.pubkey
	h.mu.Lock()
	existing, ok := h.conns[pubkey]
	// A socket registered here after the other replica's registration is the
	// client's newest connection; keep it.
	ok = ok && existing.registeredAt.Before(req.registeredAt)
	if ok {
		delete(h.conns, pubkey)
		close(existing.send)
	}
	h.mu.Unlock()
	if ok {
		log.Printf("evicted %s — reconnected on another replica", short(pubkey))
	}
}

// notifyDeliveryFailed must run on the hub goroutine.
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

		registeredAt: time.Now(),
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
			// Refresh cluster presence before it can expire (TTL > pingPeriod).
			if c.hub.backplane != nil {
				c.hub.backplane.MarkPresent(c.pubkey)
			}
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
