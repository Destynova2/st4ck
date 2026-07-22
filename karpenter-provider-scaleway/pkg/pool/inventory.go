package pool

import (
	"context"
	"slices"
	"sync"
	"time"
)

// Inventory caches ListServers snapshots per (zone, tag) for a short TTL.
// GetInstanceTypes is called on every scheduling loop; without a cache the
// provider would hammer the Scaleway API (no published rate limit, budget
// ≤ 1 req/10 s per the LLD). Create() bypasses the cache on purpose: picking
// a server to power on needs fresh data.
//
// Invalidation is generation-aware (Codex Major #4): a fetch that started
// before an Invalidate() must not repopulate the cache with its (possibly
// pre-transition) result — otherwise Offering.Available could stay stale a
// full TTL right after the last stopped server was consumed.
type Inventory struct {
	backend Backend
	ttl     time.Duration

	mu          sync.Mutex
	entries     map[string]inventoryEntry
	generations map[string]uint64 // bumped by Invalidate
}

type inventoryEntry struct {
	servers   []Server
	fetchedAt time.Time
}

func NewInventory(backend Backend, ttl time.Duration) *Inventory {
	return &Inventory{
		backend:     backend,
		ttl:         ttl,
		entries:     map[string]inventoryEntry{},
		generations: map[string]uint64{},
	}
}

// Snapshot returns the pool servers, served from cache when fresh. The
// returned slice is always a private copy: cached data is never aliased to
// callers, so no future sort/filter-in-place can corrupt the cache or race
// another reader (XRAY-005).
func (i *Inventory) Snapshot(ctx context.Context, zone, tag string) ([]Server, error) {
	key := zone + "/" + tag
	i.mu.Lock()
	if e, ok := i.entries[key]; ok && time.Since(e.fetchedAt) < i.ttl {
		servers := slices.Clone(e.servers)
		i.mu.Unlock()
		return servers, nil
	}
	gen := i.generations[key]
	i.mu.Unlock()

	servers, err := i.backend.ListServers(ctx, zone, tag)
	if err != nil {
		return nil, err
	}

	i.mu.Lock()
	if i.generations[key] == gen {
		i.entries[key] = inventoryEntry{servers: slices.Clone(servers), fetchedAt: time.Now()}
	}
	// else: an Invalidate raced this fetch — the state change it signals
	// may postdate our read. Serve the result to our caller (it is as
	// fresh as any direct read started at the same time) but do not
	// repopulate the cache with it; the next Snapshot refetches.
	i.mu.Unlock()
	return servers, nil
}

// Invalidate drops the cached snapshot and marks any in-flight fetch stale,
// e.g. right after a power state change so that Offering.Available flips on
// the next scheduling loop.
func (i *Inventory) Invalidate(zone, tag string) {
	key := zone + "/" + tag
	i.mu.Lock()
	delete(i.entries, key)
	i.generations[key]++
	i.mu.Unlock()
}
