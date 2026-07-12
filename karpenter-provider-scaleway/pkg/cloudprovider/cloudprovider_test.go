package cloudprovider

import (
	"context"
	"errors"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	clocktesting "k8s.io/utils/clock/testing"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

const (
	testZone    = "fr-par-2"
	testPoolTag = "st4ck.io/karpenter-pool=metal"
	testOffer   = "EM-A116X-SSD"
	gib         = int64(1) << 30
)

func testNodeClass(ready bool) *v1alpha1.ScalewayEMNodeClass {
	nodeClass := &v1alpha1.ScalewayEMNodeClass{
		ObjectMeta: metav1.ObjectMeta{Name: "metal-pool"},
		Spec: v1alpha1.ScalewayEMNodeClassSpec{
			Zone:      testZone,
			PoolTag:   testPoolTag,
			OfferName: testOffer,
		},
	}
	if ready {
		nodeClass.StatusConditions().SetTrue(v1alpha1.ConditionTypePoolReady)
	} else {
		nodeClass.StatusConditions().SetFalse(v1alpha1.ConditionTypePoolReady, "PoolEmpty", "no server carries the pool tag")
	}
	return nodeClass
}

func testServer(id string, serverStatus pool.Status) pool.Server {
	return pool.Server{
		ID:        id,
		Name:      "em-" + id,
		Zone:      testZone,
		Status:    serverStatus,
		OfferName: testOffer,
		Tags:      []string{testPoolTag, "st4ck.io/karpenter-managed=true"},
	}
}

func testNodeClaim() *karpv1.NodeClaim {
	return namedNodeClaim("metal-claim")
}

func namedNodeClaim(name string) *karpv1.NodeClaim {
	return &karpv1.NodeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, UID: types.UID("uid-" + name)},
		Spec: karpv1.NodeClaimSpec{
			NodeClassRef: &karpv1.NodeClassReference{
				Group: v1alpha1.Group,
				Kind:  "ScalewayEMNodeClass",
				Name:  "metal-pool",
			},
		},
	}
}

// newTestProvider wires a CloudProvider on a fake backend and a fake kube
// client. The inventory TTL is zero so every call observes fresh pool state.
func newTestProvider(t *testing.T, backend *pool.FakeBackend, objs ...client.Object) *CloudProvider {
	t.Helper()
	kubeClient := fake.NewClientBuilder().
		WithScheme(scheme.Scheme).
		WithObjects(objs...).
		WithStatusSubresource(&v1alpha1.ScalewayEMNodeClass{}).
		Build()
	return New(kubeClient, backend, pool.NewInventory(backend, 0))
}

func newTestBackend() *pool.FakeBackend {
	backend := pool.NewFakeBackend()
	backend.AddOffer(pool.Offer{
		ID:           "offer-1",
		Name:         testOffer,
		CPUThreads:   32,
		MemoryBytes:  128 * gib,
		PricePerHour: 1.25,
	})
	return backend
}

func TestCreateNominal(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	created, err := provider.Create(context.Background(), testNodeClaim())
	if err != nil {
		t.Fatalf("Create returned error: %v", err)
	}

	wantProviderID := pool.FormatProviderID(testZone, "aaa")
	if created.Status.ProviderID != wantProviderID {
		t.Errorf("ProviderID = %q, want %q", created.Status.ProviderID, wantProviderID)
	}
	if got := created.Labels[corev1.LabelInstanceTypeStable]; got != testOffer {
		t.Errorf("instance-type label = %q, want %q", got, testOffer)
	}
	if got := created.Labels[corev1.LabelTopologyZone]; got != testZone {
		t.Errorf("zone label = %q, want %q", got, testZone)
	}
	if got := created.Labels[karpv1.CapacityTypeLabelKey]; got != karpv1.CapacityTypeOnDemand {
		t.Errorf("capacity-type label = %q, want %q", got, karpv1.CapacityTypeOnDemand)
	}
	if got := created.Status.Capacity.Cpu().Value(); got != 32 {
		t.Errorf("capacity cpu = %d, want 32", got)
	}
	if got := created.Status.Capacity.Memory().Value(); got != 128*gib {
		t.Errorf("capacity memory = %d, want %d", got, 128*gib)
	}
	if created.Status.Allocatable.Cpu().Value() == 0 {
		t.Errorf("allocatable cpu should be non-zero")
	}
	if backend.StartCalls != 1 {
		t.Errorf("StartServer called %d times, want 1", backend.StartCalls)
	}
	if got := backend.ServerStatus("aaa"); got != pool.StatusReady {
		t.Errorf("server status = %s, want ready", got)
	}
}

func TestCreatePoolExhaustedReturnsICE(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusReady))
	backend.AddServer(testServer("bbb", pool.StatusStarting))
	provider := newTestProvider(t, backend, testNodeClass(true))

	_, err := provider.Create(context.Background(), testNodeClaim())
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create = %v, want InsufficientCapacityError", err)
	}
	if backend.StartCalls != 0 {
		t.Errorf("StartServer called %d times, want 0", backend.StartCalls)
	}
}

func TestCreateLastServerRaceReturnsICE(t *testing.T) {
	// Two NodeClaims race on the last stopped server while the API still
	// reports it stopped: the claim guard must yield an ICE for the second,
	// not a double power-on.
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClass := testNodeClass(true)
	if _, err := provider.claimStoppedServer(context.Background(), nodeClass, namedNodeClaim("claim-a")); err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	_, err := provider.claimStoppedServer(context.Background(), nodeClass, namedNodeClaim("claim-b"))
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("second claim = %v, want InsufficientCapacityError", err)
	}
}

func TestStartedClaimSurvivesStaleStoppedBeyondTTL(t *testing.T) {
	// Codex Critical #1 proof: StartServer succeeds but Scaleway keeps
	// reporting `stopped` well past the pending-claim TTL. A later Create
	// for another NodeClaim must neither return the same providerID nor
	// call StartServer on the same server — it gets a clean ICE.
	backend := newTestBackend()
	backend.StartKeepsStopped = true
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))
	fakeClock := clocktesting.NewFakeClock(time.Now())
	provider.clock = fakeClock

	created, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if err != nil {
		t.Fatalf("Create(A) returned error: %v", err)
	}
	if backend.StartCalls != 1 {
		t.Fatalf("StartServer called %d times, want 1", backend.StartCalls)
	}

	fakeClock.Step(3 * pendingClaimTTL)
	if got := backend.ServerStatus("aaa"); got != pool.StatusStopped {
		t.Fatalf("precondition failed: server should still report stopped, got %s", got)
	}

	dup, err := provider.Create(context.Background(), namedNodeClaim("claim-b"))
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create(B) = %v, want InsufficientCapacityError", err)
	}
	if dup != nil && dup.Status.ProviderID == created.Status.ProviderID {
		t.Fatalf("Create(B) returned the same providerID %q as Create(A)", dup.Status.ProviderID)
	}
	if backend.StartCalls != 1 {
		t.Fatalf("StartServer called %d times after the race, want still 1", backend.StartCalls)
	}
}

func TestCreateResumesOwnClaim(t *testing.T) {
	// A retried Create for the SAME NodeClaim must converge on the same
	// server and providerID instead of consuming a second pool member.
	backend := newTestBackend()
	backend.StartKeepsStopped = true
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	backend.AddServer(testServer("bbb", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	first, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if err != nil {
		t.Fatalf("first Create returned error: %v", err)
	}
	second, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if err != nil {
		t.Fatalf("retried Create returned error: %v", err)
	}
	if first.Status.ProviderID != second.Status.ProviderID {
		t.Fatalf("retried Create switched server: %q then %q", first.Status.ProviderID, second.Status.ProviderID)
	}
}

func TestCreateAmbiguousStartErrorSucceedsWhenStartTookEffect(t *testing.T) {
	// StartServer errors but the power-on actually took effect (e.g.
	// timeout after acceptance): the re-read disambiguates and Create
	// succeeds instead of leaking a started server.
	backend := newTestBackend()
	backend.StartErr = errors.New("gateway timeout")
	backend.StartErrButStarts = true
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	created, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if err != nil {
		t.Fatalf("Create = %v, want success (start took effect)", err)
	}
	if created.Status.ProviderID != pool.FormatProviderID(testZone, "aaa") {
		t.Fatalf("ProviderID = %q, want the started server", created.Status.ProviderID)
	}
}

func TestCreateStartRejectedLastServerReturnsICE(t *testing.T) {
	// Post-claim start rejection with no other startable candidate must be
	// a clean capacity signal (Codex Major #5), not a generic launch error.
	backend := newTestBackend()
	backend.StartErr = errors.New("409 conflict: cannot start")
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	_, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create = %v, want InsufficientCapacityError", err)
	}
}

func TestCreateStartRejectedWithOtherCandidateIsRetryable(t *testing.T) {
	backend := newTestBackend()
	backend.StartErr = errors.New("409 conflict: cannot start")
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	backend.AddServer(testServer("bbb", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	_, err := provider.Create(context.Background(), namedNodeClaim("claim-a"))
	if err == nil {
		t.Fatalf("Create should have failed")
	}
	if cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create = ICE, want a plain retryable error (another stopped server remains)")
	}
}

func TestCreateNodeClassNotReady(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(false))

	_, err := provider.Create(context.Background(), testNodeClaim())
	if !cloudprovider.IsNodeClassNotReadyError(err) {
		t.Fatalf("Create = %v, want NodeClassNotReadyError", err)
	}
}

func TestCreateMissingNodeClassIsNotCapacity(t *testing.T) {
	// A missing NodeClass is a configuration failure: NodeClassNotReady,
	// never InsufficientCapacity (Codex Major #6).
	backend := newTestBackend()
	provider := newTestProvider(t, backend) // no node class stored

	_, err := provider.Create(context.Background(), testNodeClaim())
	if cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create = ICE, want NodeClassNotReadyError")
	}
	if !cloudprovider.IsNodeClassNotReadyError(err) {
		t.Fatalf("Create = %v, want NodeClassNotReadyError", err)
	}
}

func TestDeleteNominalThenIdempotent(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusReady))
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaim := testNodeClaim()
	nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "aaa")

	if err := provider.Delete(context.Background(), nodeClaim); err != nil {
		t.Fatalf("first Delete returned error: %v", err)
	}
	if backend.StopCalls != 1 {
		t.Errorf("StopServer called %d times, want 1", backend.StopCalls)
	}
	if got := backend.ServerStatus("aaa"); got != pool.StatusStopped {
		t.Errorf("server status = %s, want stopped", got)
	}

	// Retried Delete on the now-stopped server: NodeClaimNotFoundError so
	// karpenter-core removes the finalizer.
	err := provider.Delete(context.Background(), nodeClaim)
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("second Delete = %v, want NodeClaimNotFoundError", err)
	}
	if backend.StopCalls != 1 {
		t.Errorf("StopServer called %d times after retry, want still 1", backend.StopCalls)
	}
}

func TestDeleteWhileStoppingRetriesUntilStopped(t *testing.T) {
	// Karpenter contract: NodeClaimNotFoundError means "already terminated".
	// `stopping` is transitional — Delete must return nil so the core keeps
	// retrying, and NotFound only once the server reaches `stopped`.
	backend := newTestBackend()
	backend.Transitional = true
	backend.AddServer(testServer("aaa", pool.StatusReady))
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaim := testNodeClaim()
	nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "aaa")

	if err := provider.Delete(context.Background(), nodeClaim); err != nil {
		t.Fatalf("first Delete returned error: %v", err)
	}
	if got := backend.ServerStatus("aaa"); got != pool.StatusStopping {
		t.Fatalf("server status = %s, want stopping", got)
	}
	if err := provider.Delete(context.Background(), nodeClaim); err != nil {
		t.Fatalf("Delete during stopping = %v, want nil (retry until stopped)", err)
	}
	if backend.StopCalls != 1 {
		t.Fatalf("StopServer called %d times, want 1 (no double stop while stopping)", backend.StopCalls)
	}

	backend.SetStatus("aaa", pool.StatusStopped)
	err := provider.Delete(context.Background(), nodeClaim)
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Delete once stopped = %v, want NodeClaimNotFoundError", err)
	}
}

func TestDeleteBlockedOrFailedServerErrors(t *testing.T) {
	// Fail closed: locked/out_of_stock/error/unknown must return neither
	// nil nor NodeClaimNotFoundError — the finalizer stays until an
	// operator intervenes, and no power action is attempted.
	for _, st := range []pool.Status{pool.StatusLocked, pool.StatusOutOfStock, pool.StatusError, pool.Status("brand-new-sdk-status")} {
		backend := newTestBackend()
		server := testServer("aaa", st)
		backend.AddServer(server)
		provider := newTestProvider(t, backend, testNodeClass(true))

		nodeClaim := testNodeClaim()
		nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "aaa")
		err := provider.Delete(context.Background(), nodeClaim)
		if err == nil || cloudprovider.IsNodeClaimNotFoundError(err) {
			t.Errorf("Delete(%s) = %v, want explicit non-NotFound error", st, err)
		}
		if backend.StopCalls != 0 {
			t.Errorf("Delete(%s) called StopServer %d times, want 0", st, backend.StopCalls)
		}
	}
}

func TestDeleteTransientServerReturnsNil(t *testing.T) {
	for _, st := range []pool.Status{pool.StatusResetting, pool.StatusMigrating, pool.StatusDelivering, pool.StatusDeleting} {
		backend := newTestBackend()
		backend.AddServer(testServer("aaa", st))
		provider := newTestProvider(t, backend, testNodeClass(true))

		nodeClaim := testNodeClaim()
		nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "aaa")
		if err := provider.Delete(context.Background(), nodeClaim); err != nil {
			t.Errorf("Delete(%s) = %v, want nil (provider-side operation in progress)", st, err)
		}
		if backend.StopCalls != 0 {
			t.Errorf("Delete(%s) called StopServer %d times, want 0", st, backend.StopCalls)
		}
	}
}

func TestDeleteRefusesServerOutsideEveryPool(t *testing.T) {
	// Membership guard (pre-mortem S1): a provider ID pointing at an EM
	// server that carries no declared pool tag must never reach StopServer.
	backend := newTestBackend()
	outsider := testServer("prod-server", pool.StatusReady)
	outsider.Tags = []string{"env=prod", "critical=true"}
	backend.AddServer(outsider)
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaim := testNodeClaim()
	nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "prod-server")
	err := provider.Delete(context.Background(), nodeClaim)
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Delete = %v, want NodeClaimNotFoundError (refused, no action)", err)
	}
	if backend.StopCalls != 0 {
		t.Fatalf("StopServer called %d times on a non-member server, want 0", backend.StopCalls)
	}
	if got := backend.ServerStatus("prod-server"); got != pool.StatusReady {
		t.Fatalf("non-member server status = %s, want untouched ready", got)
	}
}

func TestGetRefusesServerOutsideEveryPool(t *testing.T) {
	backend := newTestBackend()
	outsider := testServer("prod-server", pool.StatusReady)
	outsider.Tags = []string{"env=prod"}
	backend.AddServer(outsider)
	provider := newTestProvider(t, backend, testNodeClass(true))

	_, err := provider.Get(context.Background(), pool.FormatProviderID(testZone, "prod-server"))
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Get = %v, want NodeClaimNotFoundError", err)
	}
}

func TestDeleteUnknownServerIsNotFound(t *testing.T) {
	backend := newTestBackend()
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaim := testNodeClaim()
	nodeClaim.Status.ProviderID = pool.FormatProviderID(testZone, "never-existed")
	err := provider.Delete(context.Background(), nodeClaim)
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Delete = %v, want NodeClaimNotFoundError", err)
	}
}

func TestDeleteWithoutProviderIDIsNotFound(t *testing.T) {
	backend := newTestBackend()
	provider := newTestProvider(t, backend, testNodeClass(true))

	err := provider.Delete(context.Background(), testNodeClaim())
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Delete = %v, want NodeClaimNotFoundError", err)
	}
}

func TestGetPoweredOnServer(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStarting))
	provider := newTestProvider(t, backend, testNodeClass(true))

	providerID := pool.FormatProviderID(testZone, "aaa")
	nodeClaim, err := provider.Get(context.Background(), providerID)
	if err != nil {
		t.Fatalf("Get returned error: %v", err)
	}
	if nodeClaim.Status.ProviderID != providerID {
		t.Errorf("ProviderID = %q, want %q", nodeClaim.Status.ProviderID, providerID)
	}
	if got := nodeClaim.Labels[corev1.LabelInstanceTypeStable]; got != testOffer {
		t.Errorf("instance-type label = %q, want %q", got, testOffer)
	}
}

func TestGetStoppedServerIsNotFound(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	_, err := provider.Get(context.Background(), pool.FormatProviderID(testZone, "aaa"))
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Get = %v, want NodeClaimNotFoundError", err)
	}
}

func TestListVisibilityOnlyStoppedIsGone(t *testing.T) {
	// Fail closed: only a deliberately powered-off server (`stopped`)
	// leaves List(). Terminating, blocked, failed and transient statuses
	// stay visible so the GC never mistakes a maintenance/error state for
	// a terminated instance.
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusReady))
	backend.AddServer(testServer("bbb", pool.StatusStarting))
	backend.AddServer(testServer("ccc", pool.StatusStopping))
	backend.AddServer(testServer("ddd", pool.StatusStopped))
	backend.AddServer(testServer("eee", pool.StatusLocked))
	backend.AddServer(testServer("fff", pool.StatusError))
	outsider := testServer("ggg", pool.StatusReady)
	outsider.Tags = []string{"unrelated=tag"}
	backend.AddServer(outsider)
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaims, err := provider.List(context.Background())
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}
	got := map[string]bool{}
	for _, nodeClaim := range nodeClaims {
		got[nodeClaim.Status.ProviderID] = true
	}
	want := []string{
		pool.FormatProviderID(testZone, "aaa"),
		pool.FormatProviderID(testZone, "bbb"),
		pool.FormatProviderID(testZone, "ccc"),
		pool.FormatProviderID(testZone, "eee"),
		pool.FormatProviderID(testZone, "fff"),
	}
	if len(nodeClaims) != len(want) {
		t.Fatalf("List returned %d claims (%v), want %d", len(nodeClaims), got, len(want))
	}
	for _, providerID := range want {
		if !got[providerID] {
			t.Errorf("List is missing %q", providerID)
		}
	}
}

// TestStatusMatrix pins the behavior of every SDK status class across the
// CloudProvider surface (Codex Major #3 proof).
func TestStatusMatrix(t *testing.T) {
	type expectation struct {
		visibleInList bool
		getNotFound   bool
		deleteOutcome string // "notfound", "nil-noop", "stopped", "error"
		available     bool   // GetInstanceTypes Offering.Available with only this server
	}
	matrix := map[pool.Status]expectation{
		pool.StatusStopped:               {visibleInList: false, getNotFound: true, deleteOutcome: "notfound", available: true},
		pool.StatusReady:                 {visibleInList: true, getNotFound: false, deleteOutcome: "stopped", available: false},
		pool.StatusStarting:              {visibleInList: true, getNotFound: false, deleteOutcome: "stopped", available: false},
		pool.StatusStopping:              {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusDelivering:            {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusOrdered:               {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusResetting:             {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusMigrating:             {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusDeleting:              {visibleInList: true, getNotFound: false, deleteOutcome: "nil-noop", available: false},
		pool.StatusLocked:                {visibleInList: true, getNotFound: false, deleteOutcome: "error", available: false},
		pool.StatusOutOfStock:            {visibleInList: true, getNotFound: false, deleteOutcome: "error", available: false},
		pool.StatusError:                 {visibleInList: true, getNotFound: false, deleteOutcome: "error", available: false},
		pool.Status("future-sdk-status"): {visibleInList: true, getNotFound: false, deleteOutcome: "error", available: false},
	}
	for st, want := range matrix {
		t.Run(string(st), func(t *testing.T) {
			backend := newTestBackend()
			backend.AddServer(testServer("aaa", st))
			provider := newTestProvider(t, backend, testNodeClass(true))
			providerID := pool.FormatProviderID(testZone, "aaa")

			// List
			nodeClaims, err := provider.List(context.Background())
			if err != nil {
				t.Fatalf("List returned error: %v", err)
			}
			if got := len(nodeClaims) == 1; got != want.visibleInList {
				t.Errorf("List visibility = %v, want %v", got, want.visibleInList)
			}

			// Get
			_, err = provider.Get(context.Background(), providerID)
			if got := cloudprovider.IsNodeClaimNotFoundError(err); got != want.getNotFound {
				t.Errorf("Get NotFound = %v (err=%v), want %v", got, err, want.getNotFound)
			}
			if !want.getNotFound && err != nil {
				t.Errorf("Get returned unexpected error: %v", err)
			}

			// GetInstanceTypes availability
			its, err := provider.GetInstanceTypes(context.Background(), testNodePool())
			if err != nil {
				t.Fatalf("GetInstanceTypes returned error: %v", err)
			}
			if got := its[0].Offerings[0].Available; got != want.available {
				t.Errorf("Offering.Available = %v, want %v", got, want.available)
			}

			// Create: only `stopped` is claimable capacity.
			_, err = provider.Create(context.Background(), testNodeClaim())
			if st == pool.StatusStopped {
				if err != nil {
					t.Errorf("Create = %v, want success on a stopped server", err)
				}
				// Restore for the Delete leg below.
				backend.SetStatus("aaa", pool.StatusStopped)
			} else if !cloudprovider.IsInsufficientCapacityError(err) {
				t.Errorf("Create = %v, want InsufficientCapacityError (no startable server)", err)
			}

			// Delete
			nodeClaim := testNodeClaim()
			nodeClaim.Status.ProviderID = providerID
			err = provider.Delete(context.Background(), nodeClaim)
			switch want.deleteOutcome {
			case "notfound":
				if !cloudprovider.IsNodeClaimNotFoundError(err) {
					t.Errorf("Delete = %v, want NodeClaimNotFoundError", err)
				}
			case "nil-noop":
				if err != nil {
					t.Errorf("Delete = %v, want nil (retry later)", err)
				}
				if backend.StopCalls != 0 {
					t.Errorf("Delete called StopServer %d times, want 0", backend.StopCalls)
				}
			case "stopped":
				if err != nil {
					t.Errorf("Delete = %v, want nil (power-off issued)", err)
				}
				if backend.StopCalls != 1 {
					t.Errorf("Delete called StopServer %d times, want 1", backend.StopCalls)
				}
			case "error":
				if err == nil || cloudprovider.IsNodeClaimNotFoundError(err) {
					t.Errorf("Delete = %v, want explicit non-NotFound error", err)
				}
				if backend.StopCalls != 0 {
					t.Errorf("Delete called StopServer %d times, want 0", backend.StopCalls)
				}
			}
		})
	}
}

func TestListReflectsOutOfBandPowerOff(t *testing.T) {
	// GC semantics: a console power-off removes the server from List() so
	// the ~2 min garbage collector deletes the NodeClaim.
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusReady))
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClaims, err := provider.List(context.Background())
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}
	if len(nodeClaims) != 1 {
		t.Fatalf("List returned %d claims, want 1", len(nodeClaims))
	}

	backend.SetStatus("aaa", pool.StatusStopped)
	nodeClaims, err = provider.List(context.Background())
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}
	if len(nodeClaims) != 0 {
		t.Fatalf("List returned %d claims after out-of-band power-off, want 0", len(nodeClaims))
	}
}

func testNodePool() *karpv1.NodePool {
	return &karpv1.NodePool{
		ObjectMeta: metav1.ObjectMeta{Name: "metal"},
		Spec: karpv1.NodePoolSpec{
			Template: karpv1.NodeClaimTemplate{
				Spec: karpv1.NodeClaimTemplateSpec{
					NodeClassRef: &karpv1.NodeClassReference{
						Group: v1alpha1.Group,
						Kind:  "ScalewayEMNodeClass",
						Name:  "metal-pool",
					},
				},
			},
		},
	}
}

func TestGetInstanceTypesAvailableFlip(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	backend.AddServer(testServer("bbb", pool.StatusReady))
	provider := newTestProvider(t, backend, testNodeClass(true))

	instanceTypes, err := provider.GetInstanceTypes(context.Background(), testNodePool())
	if err != nil {
		t.Fatalf("GetInstanceTypes returned error: %v", err)
	}
	if len(instanceTypes) != 1 {
		t.Fatalf("GetInstanceTypes returned %d types, want 1", len(instanceTypes))
	}
	it := instanceTypes[0]
	if it.Name != testOffer {
		t.Errorf("instance type name = %q, want %q", it.Name, testOffer)
	}
	if len(it.Offerings) != 1 || !it.Offerings[0].Available {
		t.Fatalf("offering should be available while a stopped server remains")
	}
	if got := it.Offerings[0].Price; got != 1.25 {
		t.Errorf("offering price = %v, want 1.25", got)
	}

	// Pool exhausted: the type must still be returned (a type used by a live
	// NodeClaim never disappears), only Available flips to false.
	backend.SetStatus("aaa", pool.StatusReady)
	instanceTypes, err = provider.GetInstanceTypes(context.Background(), testNodePool())
	if err != nil {
		t.Fatalf("GetInstanceTypes returned error: %v", err)
	}
	if len(instanceTypes) != 1 {
		t.Fatalf("GetInstanceTypes returned %d types after exhaustion, want 1", len(instanceTypes))
	}
	if instanceTypes[0].Offerings[0].Available {
		t.Fatalf("offering should be unavailable once no stopped server remains")
	}
}

func TestStaticInterfaceAnswers(t *testing.T) {
	backend := newTestBackend()
	provider := newTestProvider(t, backend)

	if got := provider.Name(); got != "scaleway-em" {
		t.Errorf("Name = %q, want scaleway-em", got)
	}
	if reason, err := provider.IsDrifted(context.Background(), testNodeClaim()); reason != "" || err != nil {
		t.Errorf("IsDrifted = (%q, %v), want (\"\", nil)", reason, err)
	}
	if policies := provider.RepairPolicies(); len(policies) != 0 {
		t.Errorf("RepairPolicies = %d entries, want 0", len(policies))
	}
	classes := provider.GetSupportedNodeClasses()
	if len(classes) != 1 {
		t.Fatalf("GetSupportedNodeClasses = %d entries, want 1", len(classes))
	}
	if _, ok := classes[0].(*v1alpha1.ScalewayEMNodeClass); !ok {
		t.Errorf("GetSupportedNodeClasses[0] is %T, want *v1alpha1.ScalewayEMNodeClass", classes[0])
	}
}
