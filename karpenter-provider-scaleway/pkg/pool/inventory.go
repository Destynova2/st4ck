package pool

import (
	"context"
	"sync"
	"time"
)

// Inventory caches ListServers snapshots per (zone, tag) for a short TTL.
// GetInstanceTypes is called on every scheduling loop; without a cache the
// provider would hammer the Scaleway API (no published rate limit, budget
// ≤ 1 req/10 s per the LLD). Create() bypasses the cache on purpose: picking
// a server to power on needs fresh data.
type Inventory struct {
	backend Backend
	ttl     time.Duration

	mu      sync.Mutex
	entries map[string]inventoryEntry
}

type inventoryEntry struct {
	servers   []Server
	fetchedAt time.Time
}

func NewInventory(backend Backend, ttl time.Duration) *Inventory {
	return &Inventory{
		backend: backend,
		ttl:     ttl,
		entries: map[string]inventoryEntry{},
	}
}

// Snapshot returns the pool servers, served from cache when fresh.
func (i *Inventory) Snapshot(ctx context.Context, zone, tag string) ([]Server, error) {
	key := zone + "/" + tag
	i.mu.Lock()
	if e, ok := i.entries[key]; ok && time.Since(e.fetchedAt) < i.ttl {
		servers := e.servers
		i.mu.Unlock()
		return servers, nil
	}
	i.mu.Unlock()

	servers, err := i.backend.ListServers(ctx, zone, tag)
	if err != nil {
		return nil, err
	}
	i.mu.Lock()
	i.entries[key] = inventoryEntry{servers: servers, fetchedAt: time.Now()}
	i.mu.Unlock()
	return servers, nil
}

// Invalidate drops the cached snapshot, e.g. right after a power state
// change so that Offering.Available flips on the next scheduling loop.
func (i *Inventory) Invalidate(zone, tag string) {
	i.mu.Lock()
	delete(i.entries, zone+"/"+tag)
	i.mu.Unlock()
}
