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
// the 13 baremetal.ServerStatus values. The operational "running" state is
// `ready`.
type Status string

const (
	StatusUnknown    Status = "unknown"
	StatusDelivering Status = "delivering"
	StatusReady      Status = "ready"
	StatusStopping   Status = "stopping"
	StatusStopped    Status = "stopped"
	StatusStarting   Status = "starting"
	StatusError      Status = "error"
	StatusDeleting   Status = "deleting"
	StatusLocked     Status = "locked"
	StatusOutOfStock Status = "out_of_stock"
	StatusOrdered    Status = "ordered"
	StatusResetting  Status = "resetting"
	StatusMigrating  Status = "migrating"
)

// Class buckets server statuses by how the provider must react to them.
// Anything the provider does not explicitly know is ClassFailed: fail
// closed — a weird status must never be mistaken for "the instance is
// gone" (NodeClaimNotFound) nor for startable capacity.
type Class string

const (
	// ClassStartable — `stopped`: the only status Create() may power on,
	// and the only status that makes a server invisible to Get/List
	// (deliberate power-off = the instance is gone from Karpenter's view).
	ClassStartable Class = "startable"
	// ClassLive — `ready`, `starting`: a (future) node backing a NodeClaim.
	ClassLive Class = "live"
	// ClassTerminating — `stopping`: power-off in progress. Delete returns
	// nil so karpenter-core keeps retrying until `stopped`.
	ClassTerminating Class = "terminating"
	// ClassTransient — `delivering`, `ordered`, `resetting`, `migrating`,
	// `deleting`: provider-side operation in progress; wait it out.
	ClassTransient Class = "transient"
	// ClassBlocked — `locked`, `out_of_stock`: the server exists but is not
	// actionable; requires operator intervention. Never NotFound.
	ClassBlocked Class = "blocked"
	// ClassFailed — `error`, `unknown` and any status introduced by the SDK
	// after this code was written. Never NotFound.
	ClassFailed Class = "failed"
)

// Class maps a status to its behavior class (fail closed by default).
func (s Status) Class() Class {
	switch s {
	case StatusStopped:
		return ClassStartable
	case StatusReady, StatusStarting:
		return ClassLive
	case StatusStopping:
		return ClassTerminating
	case StatusDelivering, StatusOrdered, StatusResetting, StatusMigrating, StatusDeleting:
		return ClassTransient
	case StatusLocked, StatusOutOfStock:
		return ClassBlocked
	default:
		return ClassFailed
	}
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
	// whatever its status. On success the returned slice is never nil —
	// an empty pool yields an empty slice (contract shared by every
	// implementation, audit F1).
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
