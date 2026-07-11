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
