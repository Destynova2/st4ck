package pool

import (
	"context"
	"fmt"
	"slices"
	"sync"
)

// FakeBackend is an in-memory Backend for unit tests. No network access.
// Start/Stop transition servers to their final status immediately unless a
// test freezes intermediate states with SetStatus.
type FakeBackend struct {
	mu      sync.Mutex
	servers map[string]*Server
	offers  map[string]Offer

	// Transitional keeps servers in starting/stopping instead of jumping to
	// the final status, letting tests observe intermediate states.
	Transitional bool

	// StartKeepsStopped simulates Scaleway eventual consistency: StartServer
	// succeeds but the server keeps reporting `stopped` until a test flips
	// it with SetStatus.
	StartKeepsStopped bool

	// StartErrButStarts simulates an ambiguous StartServer failure: the
	// power-on takes effect (status transitions) but the call returns
	// StartErr anyway (e.g. timeout after the action was accepted).
	StartErrButStarts bool

	// Error injection: when set, the matching call returns the error.
	ListErr  error
	GetErr   error
	StartErr error
	StopErr  error
	OfferErr error

	ListCalls  int
	StartCalls int
	StopCalls  int
	OfferCalls int
}

var _ Backend = (*FakeBackend)(nil)

func NewFakeBackend() *FakeBackend {
	return &FakeBackend{
		servers: map[string]*Server{},
		offers:  map[string]Offer{},
	}
}

// AddServer registers a pool member. The server is stored by ID.
func (f *FakeBackend) AddServer(s Server) {
	f.mu.Lock()
	defer f.mu.Unlock()
	cp := s
	f.servers[s.ID] = &cp
}

// AddOffer registers an offer resolvable by name.
func (f *FakeBackend) AddOffer(o Offer) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.offers[o.Name] = o
}

// SetStatus force-sets a server status, e.g. to simulate the end of an
// asynchronous transition or an out-of-band power-off from the console.
func (f *FakeBackend) SetStatus(serverID string, status Status) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if s, ok := f.servers[serverID]; ok {
		s.Status = status
	}
}

// ServerStatus returns the current status of a server for assertions.
func (f *FakeBackend) ServerStatus(serverID string) Status {
	f.mu.Lock()
	defer f.mu.Unlock()
	if s, ok := f.servers[serverID]; ok {
		return s.Status
	}
	return StatusUnknown
}

func (f *FakeBackend) ListServers(_ context.Context, zone, tag string) ([]Server, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ListCalls++
	if f.ListErr != nil {
		return nil, f.ListErr
	}
	// Empty pool → empty non-nil slice, like the real backend (audit F1):
	// both Backend implementations honor the "never nil on success"
	// contract documented on Backend.ListServers.
	out := make([]Server, 0, len(f.servers))
	for _, s := range f.servers {
		if s.Zone == zone && slices.Contains(s.Tags, tag) {
			out = append(out, *s)
		}
	}
	slices.SortFunc(out, func(a, b Server) int {
		if a.ID < b.ID {
			return -1
		}
		if a.ID > b.ID {
			return 1
		}
		return 0
	})
	return out, nil
}

func (f *FakeBackend) GetServer(_ context.Context, zone, serverID string) (Server, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.GetErr != nil {
		return Server{}, f.GetErr
	}
	s, ok := f.servers[serverID]
	if !ok || s.Zone != zone {
		return Server{}, fmt.Errorf("server %s/%s: %w", zone, serverID, ErrServerNotFound)
	}
	return *s, nil
}

func (f *FakeBackend) StartServer(_ context.Context, zone, serverID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.StartCalls++
	s, ok := f.servers[serverID]
	if !ok || s.Zone != zone {
		return fmt.Errorf("server %s/%s: %w", zone, serverID, ErrServerNotFound)
	}
	if s.Status != StatusStopped {
		return fmt.Errorf("server %s is %s, cannot start", serverID, s.Status)
	}
	transition := func() {
		if f.Transitional {
			s.Status = StatusStarting
		} else {
			s.Status = StatusReady
		}
	}
	if f.StartErrButStarts {
		transition()
		return f.StartErr
	}
	if f.StartErr != nil {
		return f.StartErr
	}
	if !f.StartKeepsStopped {
		transition()
	}
	return nil
}

func (f *FakeBackend) StopServer(_ context.Context, zone, serverID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.StopCalls++
	if f.StopErr != nil {
		return f.StopErr
	}
	s, ok := f.servers[serverID]
	if !ok || s.Zone != zone {
		return fmt.Errorf("server %s/%s: %w", zone, serverID, ErrServerNotFound)
	}
	if s.Status.Class() != ClassLive {
		return fmt.Errorf("server %s is %s, cannot stop", serverID, s.Status)
	}
	if f.Transitional {
		s.Status = StatusStopping
	} else {
		s.Status = StatusStopped
	}
	return nil
}

func (f *FakeBackend) GetOfferByName(_ context.Context, _ string, name string) (Offer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.OfferCalls++
	if f.OfferErr != nil {
		return Offer{}, f.OfferErr
	}
	o, ok := f.offers[name]
	if !ok {
		return Offer{}, fmt.Errorf("offer %q: %w", name, ErrOfferNotFound)
	}
	return o, nil
}
