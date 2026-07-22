package pool

import (
	"context"
	"testing"
	"time"
)

func newInventoryFixture() *FakeBackend {
	backend := NewFakeBackend()
	backend.AddServer(Server{ID: "srv-1", Zone: "fr-par-2", Status: StatusStopped, Tags: []string{"pool=metal"}})
	return backend
}

func TestInventoryCachesWithinTTL(t *testing.T) {
	backend := newInventoryFixture()
	inv := NewInventory(backend, time.Hour)

	for range 3 {
		if _, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal"); err != nil {
			t.Fatalf("Snapshot returned error: %v", err)
		}
	}
	if backend.ListCalls != 1 {
		t.Fatalf("ListServers called %d times, want 1 (cached)", backend.ListCalls)
	}
}

func TestInventoryInvalidateForcesRefetch(t *testing.T) {
	backend := newInventoryFixture()
	inv := NewInventory(backend, time.Hour)

	if _, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal"); err != nil {
		t.Fatalf("Snapshot returned error: %v", err)
	}
	inv.Invalidate("fr-par-2", "pool=metal")
	if _, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal"); err != nil {
		t.Fatalf("Snapshot returned error: %v", err)
	}
	if backend.ListCalls != 2 {
		t.Fatalf("ListServers called %d times, want 2 (invalidated)", backend.ListCalls)
	}
}

func TestInventoryZeroTTLDisablesCache(t *testing.T) {
	backend := newInventoryFixture()
	inv := NewInventory(backend, 0)

	for range 2 {
		if _, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal"); err != nil {
			t.Fatalf("Snapshot returned error: %v", err)
		}
	}
	if backend.ListCalls != 2 {
		t.Fatalf("ListServers called %d times, want 2 (no cache)", backend.ListCalls)
	}
}

// blockingBackend wraps a Backend and parks ListServers calls between two
// channel rendezvous, letting a test order Snapshot(fetch starts) →
// Invalidate → Snapshot(fetch stores) deterministically.
type blockingBackend struct {
	Backend
	entered chan struct{}
	release chan struct{}
	block   bool
}

func (b *blockingBackend) ListServers(ctx context.Context, zone, tag string) ([]Server, error) {
	if b.block {
		b.entered <- struct{}{}
		<-b.release
	}
	return b.Backend.ListServers(ctx, zone, tag)
}

func TestInventoryInvalidateDuringInFlightFetchIsNotOverwritten(t *testing.T) {
	// Codex Major #4 proof: an Invalidate that lands while a fetch is in
	// flight must not be erased when that older fetch completes — the next
	// Snapshot must hit the backend again and observe the new state.
	fake := newInventoryFixture()
	blocking := &blockingBackend{Backend: fake, entered: make(chan struct{}), release: make(chan struct{}), block: true}
	inv := NewInventory(blocking, time.Hour)

	type result struct {
		servers []Server
		err     error
	}
	done := make(chan result, 1)
	go func() {
		servers, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal")
		done <- result{servers, err}
	}()

	<-blocking.entered // the in-flight fetch has started (pre-invalidation view)
	inv.Invalidate("fr-par-2", "pool=metal")
	// The pool state changes right after the invalidation (e.g. Create
	// consumed the last stopped server).
	fake.SetStatus("srv-1", StatusStarting)
	blocking.release <- struct{}{}
	if r := <-done; r.err != nil {
		t.Fatalf("in-flight Snapshot returned error: %v", r.err)
	}

	blocking.block = false
	servers, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal")
	if err != nil {
		t.Fatalf("post-invalidation Snapshot returned error: %v", err)
	}
	if fake.ListCalls != 2 {
		t.Fatalf("ListServers called %d times, want 2 (stale in-flight result must not repopulate the cache)", fake.ListCalls)
	}
	if len(servers) != 1 || servers[0].Status != StatusStarting {
		t.Fatalf("post-invalidation Snapshot = %+v, want the post-transition state (starting)", servers)
	}
}

func TestInventorySnapshotReturnsPrivateCopy(t *testing.T) {
	backend := newInventoryFixture()
	inv := NewInventory(backend, time.Hour)

	first, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal")
	if err != nil {
		t.Fatalf("Snapshot returned error: %v", err)
	}
	first[0].Status = StatusError // a hostile caller mutates its snapshot

	second, err := inv.Snapshot(context.Background(), "fr-par-2", "pool=metal")
	if err != nil {
		t.Fatalf("Snapshot returned error: %v", err)
	}
	if second[0].Status != StatusStopped {
		t.Fatalf("cache was corrupted through an aliased snapshot: %+v", second[0])
	}
}

func TestCountByStatus(t *testing.T) {
	servers := []Server{
		{ID: "a", Status: StatusStopped},
		{ID: "b", Status: StatusReady},
		{ID: "c", Status: StatusStopped},
	}
	if n := CountByStatus(servers, StatusStopped); n != 2 {
		t.Fatalf("CountByStatus(stopped) = %d, want 2", n)
	}
	if n := CountByStatus(servers, StatusStarting); n != 0 {
		t.Fatalf("CountByStatus(starting) = %d, want 0", n)
	}
}
