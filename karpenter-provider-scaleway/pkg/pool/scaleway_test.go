package pool

import (
	"context"
	"errors"
	"testing"
	"time"

	baremetal "github.com/scaleway/scaleway-sdk-go/api/baremetal/v1"
	"github.com/scaleway/scaleway-sdk-go/scw"
)

// stubBaremetalAPI implements baremetalAPI in memory; only ListOffers is
// meaningful for the offer-cache tests. No network.
type stubBaremetalAPI struct {
	listOffersCalls int
	offers          []*baremetal.Offer
	listOffersErr   error
}

func (s *stubBaremetalAPI) ListServers(*baremetal.ListServersRequest, ...scw.RequestOption) (*baremetal.ListServersResponse, error) {
	return &baremetal.ListServersResponse{}, nil
}

func (s *stubBaremetalAPI) GetServer(*baremetal.GetServerRequest, ...scw.RequestOption) (*baremetal.Server, error) {
	return nil, errors.New("not implemented")
}

func (s *stubBaremetalAPI) StartServer(*baremetal.StartServerRequest, ...scw.RequestOption) (*baremetal.Server, error) {
	return nil, errors.New("not implemented")
}

func (s *stubBaremetalAPI) StopServer(*baremetal.StopServerRequest, ...scw.RequestOption) (*baremetal.Server, error) {
	return nil, errors.New("not implemented")
}

func (s *stubBaremetalAPI) ListOffers(*baremetal.ListOffersRequest, ...scw.RequestOption) (*baremetal.ListOffersResponse, error) {
	s.listOffersCalls++
	if s.listOffersErr != nil {
		return nil, s.listOffersErr
	}
	return &baremetal.ListOffersResponse{Offers: s.offers}, nil
}

func newStubbedBackend(stub *stubBaremetalAPI) *ScalewayBackend {
	return &ScalewayBackend{api: stub, offerCache: map[string]offerEntry{}}
}

func TestGetOfferByNamePositiveCachedForever(t *testing.T) {
	stub := &stubBaremetalAPI{offers: []*baremetal.Offer{{ID: "o1", Name: "EM-A116X-SSD"}}}
	backend := newStubbedBackend(stub)

	for range 3 {
		offer, err := backend.GetOfferByName(context.Background(), "fr-par-2", "EM-A116X-SSD")
		if err != nil {
			t.Fatalf("GetOfferByName returned error: %v", err)
		}
		if offer.Name != "EM-A116X-SSD" {
			t.Fatalf("offer = %+v, want EM-A116X-SSD", offer)
		}
	}
	if stub.listOffersCalls != 1 {
		t.Fatalf("ListOffers called %d times, want 1 (positive cache)", stub.listOffersCalls)
	}
}

func TestGetOfferByNameNegativeCachedWithTTL(t *testing.T) {
	// XRAY-001 proof: a misconfigured offerName must not trigger a
	// full-catalog ListOffers on every call.
	stub := &stubBaremetalAPI{}
	backend := newStubbedBackend(stub)

	for range 5 {
		_, err := backend.GetOfferByName(context.Background(), "fr-par-2", "TYPO-OFFER")
		if !errors.Is(err, ErrOfferNotFound) {
			t.Fatalf("GetOfferByName = %v, want ErrOfferNotFound", err)
		}
	}
	if stub.listOffersCalls != 1 {
		t.Fatalf("ListOffers called %d times, want 1 (negative cache within TTL)", stub.listOffersCalls)
	}

	// Expire the negative entry and add the offer to the catalog: the next
	// call must refetch and recover.
	backend.offerMu.Lock()
	backend.offerCache["fr-par-2/TYPO-OFFER"] = offerEntry{
		err:       backend.offerCache["fr-par-2/TYPO-OFFER"].err,
		fetchedAt: time.Now().Add(-2 * negativeOfferTTL),
	}
	backend.offerMu.Unlock()
	stub.offers = []*baremetal.Offer{{ID: "o1", Name: "TYPO-OFFER"}}

	offer, err := backend.GetOfferByName(context.Background(), "fr-par-2", "TYPO-OFFER")
	if err != nil {
		t.Fatalf("GetOfferByName after TTL = %v, want recovery", err)
	}
	if offer.ID != "o1" {
		t.Fatalf("offer = %+v, want o1", offer)
	}
	if stub.listOffersCalls != 2 {
		t.Fatalf("ListOffers called %d times, want 2 (refetch after TTL)", stub.listOffersCalls)
	}
}

func TestGetOfferByNameTransientErrorNotCached(t *testing.T) {
	stub := &stubBaremetalAPI{listOffersErr: errors.New("503 service unavailable")}
	backend := newStubbedBackend(stub)

	if _, err := backend.GetOfferByName(context.Background(), "fr-par-2", "EM-A116X-SSD"); err == nil {
		t.Fatalf("GetOfferByName should have failed")
	}

	stub.listOffersErr = nil
	stub.offers = []*baremetal.Offer{{ID: "o1", Name: "EM-A116X-SSD"}}
	offer, err := backend.GetOfferByName(context.Background(), "fr-par-2", "EM-A116X-SSD")
	if err != nil {
		t.Fatalf("GetOfferByName after transient error = %v, want immediate recovery (no negative cache)", err)
	}
	if offer.ID != "o1" || stub.listOffersCalls != 2 {
		t.Fatalf("offer = %+v after %d calls, want o1 after 2 calls", offer, stub.listOffersCalls)
	}
}
