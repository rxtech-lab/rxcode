package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	// redisRouteChannel is the pub/sub channel every relay replica subscribes
	// to. An envelope whose recipient is not connected to the publishing pod
	// is fanned out here so whichever pod holds that connection delivers it.
	redisRouteChannel = "relay:route"

	// redisPresencePrefix namespaces the per-pubkey presence keys that let any
	// pod answer "is this peer connected anywhere in the cluster?" — needed to
	// keep the delivery_failed notice accurate once routing spans pods.
	redisPresencePrefix = "relay:presence:"

	// presenceTTL outlives pongWait so a key never expires under a healthy
	// connection; writePump refreshes it every pingPeriod.
	presenceTTL = pongWait + 60*time.Second
)

// presenceRelease deletes a presence key only when it still belongs to the
// releasing pod. Without the compare, a peer that migrated to another replica
// (the new pod re-SET the key) would have its presence wiped by the old pod's
// disconnect cleanup, briefly looking offline cluster-wide.
var presenceRelease = redis.NewScript(`
if redis.call("get", KEYS[1]) == ARGV[1] then
	return redis.call("del", KEYS[1])
end
return 0
`)

// Backplane fans envelopes across relay replicas over Redis pub/sub and tracks
// cluster-wide connection presence. It is constructed only when REDIS_URL is
// set; otherwise the relay runs single-node and the hub keeps its purely
// in-memory behavior with no Redis dependency at runtime.
type Backplane struct {
	rdb        *redis.Client
	hub        *Hub
	ctx        context.Context
	instanceID string
}

// NewBackplane connects to Redis from a redis:// or rediss:// URL. A failed
// connection is fatal: if the operator asked for multi-node mode, silently
// degrading to single-node would drop every cross-pod message.
func NewBackplane(ctx context.Context, redisURL string, hub *Hub) (*Backplane, error) {
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opt)
	if err := rdb.Ping(ctx).Err(); err != nil {
		_ = rdb.Close()
		return nil, err
	}
	return &Backplane{
		rdb:        rdb,
		hub:        hub,
		ctx:        ctx,
		instanceID: randomInstanceID(),
	}, nil
}

// Run subscribes to the route channel and hands every envelope to the local
// hub. An envelope for a peer connected to another replica finds no local
// connection and is dropped without re-publishing, so there is no fan-out loop
// — the pod that received it from a client is the only one that publishes.
func (b *Backplane) Run() {
	sub := b.rdb.Subscribe(b.ctx, redisRouteChannel)
	defer func() { _ = sub.Close() }()
	log.Printf("backplane: subscribed to %s (instance %s)", redisRouteChannel, b.instanceID)
	for msg := range sub.Channel() {
		var env Envelope
		if err := json.Unmarshal([]byte(msg.Payload), &env); err != nil {
			log.Printf("backplane: malformed envelope: %v", err)
			continue
		}
		b.hub.deliverLocal(&env)
	}
}

// Publish fans an envelope out to every other relay replica.
func (b *Backplane) Publish(env *Envelope) {
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	if err := b.rdb.Publish(b.ctx, redisRouteChannel, raw).Err(); err != nil {
		log.Printf("backplane: publish to %s: %v", short(env.To), err)
	}
}

// MarkPresent records (or refreshes) a pubkey as connected to this pod. Called
// on register and on every ping so the key never expires while the socket is
// live.
func (b *Backplane) MarkPresent(pubkey string) {
	if err := b.rdb.Set(b.ctx, redisPresencePrefix+pubkey, b.instanceID, presenceTTL).Err(); err != nil {
		log.Printf("backplane: presence set %s: %v", short(pubkey), err)
	}
}

// ClearPresence removes a pubkey's presence marker on disconnect, but only if
// this pod still owns it (see presenceRelease).
func (b *Backplane) ClearPresence(pubkey string) {
	if err := presenceRelease.Run(b.ctx, b.rdb, []string{redisPresencePrefix + pubkey}, b.instanceID).Err(); err != nil && err != redis.Nil {
		log.Printf("backplane: presence clear %s: %v", short(pubkey), err)
	}
}

// ConnectedAnywhere reports whether a pubkey is connected to any relay
// replica. On a Redis error it returns true so the relay errs toward
// publishing rather than emitting a false delivery_failed.
func (b *Backplane) ConnectedAnywhere(pubkey string) bool {
	n, err := b.rdb.Exists(b.ctx, redisPresencePrefix+pubkey).Result()
	if err != nil {
		log.Printf("backplane: presence check %s: %v", short(pubkey), err)
		return true
	}
	return n > 0
}

// randomInstanceID returns a short per-process identifier used to scope
// presence ownership so one replica cannot clear another's keys.
func randomInstanceID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "relay"
	}
	return hex.EncodeToString(b[:])
}
