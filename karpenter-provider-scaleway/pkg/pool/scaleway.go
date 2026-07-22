package pool

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	baremetal "github.com/scaleway/scaleway-sdk-go/api/baremetal/v1"
	"github.com/scaleway/scaleway-sdk-go/scw"
)

// negativeOfferTTL bounds how long a failed offer resolution
// (ErrOfferNotFound) is served from cache. Without it, a misconfigured
// spec.offerName would trigger a full-catalog ListOffers on every
// scheduling loop, every nodeclass poll and every GC pass, indefinitely
// (XRAY-001). Transient API errors are never cached. Recovery worst case:
// an offer added to the catalog is seen at most one TTL late; fixing the
// offerName in the spec changes the cache key, so it resolves immediately.
const negativeOfferTTL = time.Minute

// ScalewayBackend implements Backend against the Scaleway baremetal v1 API.
// Authentication comes from the standard SCW_* environment variables
// (scw.WithEnv); the controller IAM application needs ElasticMetalFullAccess.
type ScalewayBackend struct {
	api baremetalAPI

	// Offers are static: positive resolutions are cached forever, negative
	// ones (offer absent from the catalog) for negativeOfferTTL.
	offerMu    sync.Mutex
	offerCache map[string]offerEntry // key: zone/name
}

type offerEntry struct {
	offer     Offer
	err       error // non-nil ⇒ negative entry (ErrOfferNotFound only)
	fetchedAt time.Time
}

// baremetalAPI is the subset of *baremetal.API used, extracted for tests.
type baremetalAPI interface {
	ListServers(req *baremetal.ListServersRequest, opts ...scw.RequestOption) (*baremetal.ListServersResponse, error)
	GetServer(req *baremetal.GetServerRequest, opts ...scw.RequestOption) (*baremetal.Server, error)
	StartServer(req *baremetal.StartServerRequest, opts ...scw.RequestOption) (*baremetal.Server, error)
	StopServer(req *baremetal.StopServerRequest, opts ...scw.RequestOption) (*baremetal.Server, error)
	ListOffers(req *baremetal.ListOffersRequest, opts ...scw.RequestOption) (*baremetal.ListOffersResponse, error)
}

var _ Backend = (*ScalewayBackend)(nil)

// NewScalewayBackend builds the real backend from environment credentials.
func NewScalewayBackend() (*ScalewayBackend, error) {
	client, err := scw.NewClient(scw.WithEnv())
	if err != nil {
		return nil, fmt.Errorf("creating scaleway client from environment: %w", err)
	}
	return &ScalewayBackend{
		api:        baremetal.NewAPI(client),
		offerCache: map[string]offerEntry{},
	}, nil
}

func (b *ScalewayBackend) ListServers(ctx context.Context, zone, tag string) ([]Server, error) {
	resp, err := b.api.ListServers(&baremetal.ListServersRequest{
		Zone: scw.Zone(zone),
		Tags: []string{tag},
	}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		return nil, fmt.Errorf("listing servers in %s with tag %q: %w", zone, tag, err)
	}
	servers := make([]Server, 0, len(resp.Servers))
	for _, s := range resp.Servers {
		servers = append(servers, toServer(s))
	}
	return servers, nil
}

func (b *ScalewayBackend) GetServer(ctx context.Context, zone, serverID string) (Server, error) {
	s, err := b.api.GetServer(&baremetal.GetServerRequest{
		Zone:     scw.Zone(zone),
		ServerID: serverID,
	}, scw.WithContext(ctx))
	if err != nil {
		notFound := &scw.ResourceNotFoundError{}
		if errors.As(err, &notFound) {
			return Server{}, fmt.Errorf("server %s/%s: %w", zone, serverID, ErrServerNotFound)
		}
		return Server{}, fmt.Errorf("getting server %s/%s: %w", zone, serverID, err)
	}
	return toServer(s), nil
}

func (b *ScalewayBackend) StartServer(ctx context.Context, zone, serverID string) error {
	_, err := b.api.StartServer(&baremetal.StartServerRequest{
		Zone:     scw.Zone(zone),
		ServerID: serverID,
		BootType: baremetal.ServerBootTypeNormal,
	}, scw.WithContext(ctx))
	if err != nil {
		if isNotStartable(err) {
			return fmt.Errorf("starting server %s/%s: %w: %w", zone, serverID, ErrNotStartable, err)
		}
		return fmt.Errorf("starting server %s/%s: %w", zone, serverID, err)
	}
	return nil
}

// isNotStartable classifies SDK errors that mean "this server refuses to
// power on" (per-server conflict), as opposed to auth/API/config failures
// which must stay retryable and never become a capacity signal.
func isNotStartable(err error) bool {
	var precondition *scw.PreconditionFailedError
	var locked *scw.ResourceLockedError
	var outOfStock *scw.OutOfStockError
	var transient *scw.TransientStateError
	return errors.As(err, &precondition) ||
		errors.As(err, &locked) ||
		errors.As(err, &outOfStock) ||
		errors.As(err, &transient)
}

func (b *ScalewayBackend) StopServer(ctx context.Context, zone, serverID string) error {
	_, err := b.api.StopServer(&baremetal.StopServerRequest{
		Zone:     scw.Zone(zone),
		ServerID: serverID,
	}, scw.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("stopping server %s/%s: %w", zone, serverID, err)
	}
	return nil
}

func (b *ScalewayBackend) GetOfferByName(ctx context.Context, zone, name string) (Offer, error) {
	key := zone + "/" + name
	b.offerMu.Lock()
	if e, ok := b.offerCache[key]; ok {
		if e.err == nil {
			b.offerMu.Unlock()
			return e.offer, nil
		}
		if time.Since(e.fetchedAt) < negativeOfferTTL {
			b.offerMu.Unlock()
			return Offer{}, e.err
		}
	}
	b.offerMu.Unlock()

	resp, err := b.api.ListOffers(&baremetal.ListOffersRequest{
		Zone: scw.Zone(zone),
		Name: &name,
	}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		// Transient API failure: never cached, the next call retries.
		return Offer{}, fmt.Errorf("listing offers in %s: %w", zone, err)
	}
	for _, o := range resp.Offers {
		if o.Name != name {
			continue
		}
		offer := toOffer(o)
		b.offerMu.Lock()
		b.offerCache[key] = offerEntry{offer: offer}
		b.offerMu.Unlock()
		return offer, nil
	}
	notFound := fmt.Errorf("offer %q in %s: %w", name, zone, ErrOfferNotFound)
	b.offerMu.Lock()
	b.offerCache[key] = offerEntry{err: notFound, fetchedAt: time.Now()}
	b.offerMu.Unlock()
	return Offer{}, notFound
}

func toServer(s *baremetal.Server) Server {
	return Server{
		ID:        s.ID,
		Name:      s.Name,
		Zone:      string(s.Zone),
		Status:    Status(s.Status),
		OfferName: s.OfferName,
		Tags:      s.Tags,
	}
}

func toOffer(o *baremetal.Offer) Offer {
	var threads int64
	for _, cpu := range o.CPUs {
		threads += int64(cpu.ThreadCount)
	}
	var memory int64
	for _, m := range o.Memories {
		memory += int64(m.Capacity)
	}
	var price float64
	if o.PricePerHour != nil {
		price = o.PricePerHour.ToFloat()
	}
	return Offer{
		ID:           o.ID,
		Name:         o.Name,
		CPUThreads:   threads,
		MemoryBytes:  memory,
		PricePerHour: price,
	}
}
