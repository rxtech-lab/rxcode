package main

import (
	"strings"
	"testing"
	"time"
)

func testPubkey(c byte) string { return strings.Repeat(string(c), 64) }

func TestEvictLocalDropsOlderSocket(t *testing.T) {
	hub := NewHub()
	pk := testPubkey('a')
	conn := &Conn{pubkey: pk, send: make(chan []byte, 1), hub: hub, registeredAt: time.Now().Add(-time.Minute)}
	hub.conns[pk] = conn

	hub.evictLocal(evictRequest{pubkey: pk, registeredAt: time.Now()})

	if _, ok := hub.conns[pk]; ok {
		t.Fatal("stale connection should have been evicted")
	}
	if _, open := <-conn.send; open {
		t.Fatal("evicted connection's send channel should be closed")
	}
}

func TestEvictLocalKeepsNewerSocket(t *testing.T) {
	hub := NewHub()
	pk := testPubkey('b')
	conn := &Conn{pubkey: pk, send: make(chan []byte, 1), hub: hub, registeredAt: time.Now()}
	hub.conns[pk] = conn

	// A late notice about an older registration on another replica.
	hub.evictLocal(evictRequest{pubkey: pk, registeredAt: time.Now().Add(-time.Minute)})

	if hub.conns[pk] != conn {
		t.Fatal("a socket registered after the notice must be kept")
	}
}
