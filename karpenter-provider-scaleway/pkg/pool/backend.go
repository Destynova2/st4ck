// Package pool models the finite inventory of pre-imaged Scaleway Elastic
// Metal servers that the provider powers on and off. The Backend interface
// abstracts the Scaleway baremetal v1 API surface so tests run against an
// in-memory fake without any network access.
package pool

import (
	"context"
	"errors"
)

// Status is the operational status of an Elastic Metal server, mirroring
// baremetal.ServerStatus. The operational "running" state is `ready`.
type Status string

const (
	StatusReady    Status = "ready"
	StatusStarting Status = "starting"
	StatusStopping Status = "stopping"
	StatusStopped  Status = "stopped"
	StatusError    Status = "error"
	StatusUnknown  Status = "unknown"
)

// PoweredOn reports whether the server counts as a live pool member from
// Karpenter's perspective: List() only returns powered-on servers so that an
// out-of-band power-off makes the NodeClaim disappear and get GC'd.
func (s Status) PoweredOn() bool {
	return s == StatusReady || s == StatusStarting
}

// Server is the subset of the Elastic Metal server the provider needs.
type Server struct {
	ID        string
	Name      string
	Zone      string
	Status    Status
	OfferName string
	Tags      []string
}

// Offer is the resolved shape of an Elastic Metal commercial offer.
type Offer struct {
	ID           string
	Name         string
	CPUThreads   int64
	MemoryBytes  int64
	PricePerHour float64
}

var (
	ErrServerNotFound = errors.New("server not found")
	ErrOfferNotFound  = errors.New("offer not found")
)

// Backend abstracts the Scaleway Elastic Metal API calls used by the
// provider. Implementations: ScalewayBackend (real API) and FakeBackend
// (in-memory, tests only).
type Backend interface {
	// ListServers returns every server in the zone carrying the given tag,
	// whatever its status.
	ListServers(ctx context.Context, zone, tag string) ([]Server, error)
	// GetServer returns a single server or ErrServerNotFound.
	GetServer(ctx context.Context, zone, serverID string) (Server, error)
	// StartServer requests a normal boot power-on. Asynchronous: the caller
	// observes progress through the server status (stopped→starting→ready).
	StartServer(ctx context.Context, zone, serverID string) error
	// StopServer requests a power-off. Asynchronous (ready→stopping→stopped).
	StopServer(ctx context.Context, zone, serverID string) error
	// GetOfferByName resolves an offer shape by commercial name or returns
	// ErrOfferNotFound. Offers are static; implementations may cache forever.
	GetOfferByName(ctx context.Context, zone, name string) (Offer, error)
}

// CountByStatus returns the number of servers in the given status.
func CountByStatus(servers []Server, status Status) int {
	n := 0
	for _, s := range servers {
		if s.Status == status {
			n++
		}
	}
	return n
}
