package cloudprovider

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
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
	return &karpv1.NodeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "metal-claim"},
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
	// Two Create calls race on the last stopped server while the API still
	// reports it stopped: the in-flight claim guard must yield an ICE, not a
	// double power-on.
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusStopped))
	provider := newTestProvider(t, backend, testNodeClass(true))

	nodeClass := testNodeClass(true)
	if _, err := provider.claimStoppedServer(context.Background(), nodeClass); err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	_, err := provider.claimStoppedServer(context.Background(), nodeClass)
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("second claim = %v, want InsufficientCapacityError", err)
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

func TestCreateMissingNodeClassReturnsICE(t *testing.T) {
	backend := newTestBackend()
	provider := newTestProvider(t, backend) // no node class stored

	_, err := provider.Create(context.Background(), testNodeClaim())
	if !cloudprovider.IsInsufficientCapacityError(err) {
		t.Fatalf("Create = %v, want InsufficientCapacityError", err)
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

func TestDeleteStoppingServerIsNotFound(t *testing.T) {
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
	err := provider.Delete(context.Background(), nodeClaim)
	if !cloudprovider.IsNodeClaimNotFoundError(err) {
		t.Fatalf("Delete during stopping = %v, want NodeClaimNotFoundError", err)
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

func TestListOnlyPoweredOnPoolMembers(t *testing.T) {
	backend := newTestBackend()
	backend.AddServer(testServer("aaa", pool.StatusReady))
	backend.AddServer(testServer("bbb", pool.StatusStarting))
	backend.AddServer(testServer("ccc", pool.StatusStopping))
	backend.AddServer(testServer("ddd", pool.StatusStopped))
	outsider := testServer("eee", pool.StatusReady)
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
