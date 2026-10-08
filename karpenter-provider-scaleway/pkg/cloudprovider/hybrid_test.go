package cloudprovider

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/vm"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
)

func durableFixture(t *testing.T) (*Durable, *pool.FakeBackend) {
	t.Helper()
	b := newTestBackend()
	b.AddServer(testServer("aaa", pool.StatusStopped))
	return newTestProvider(t, b, testNodeClass(true)), b
}

func TestHybridRoutesBothBackendsAndRejectsMismatches(t *testing.T) {
	metal, metalBackend := durableFixture(t)
	virtual, vmBackend, vmClaim := vmFixture(t)
	hybrid := &Hybrid{Metal: metal, VM: virtual}
	ctx := context.Background()
	emClaim := namedNodeClaim("metal")
	for _, claim := range []*karpv1.NodeClaim{emClaim, vmClaim} {
		created, err := hybrid.Create(ctx, claim)
		if err != nil {
			t.Fatal(err)
		}
		claim.Status = created.Status
		got, err := hybrid.Get(ctx, claim.Status.ProviderID)
		if err != nil || got.Status.ProviderID != claim.Status.ProviderID {
			t.Fatal("incorrect Get routing", err)
		}
		np := testNodePool()
		np.Spec.Template.Spec.NodeClassRef = claim.Spec.NodeClassRef.DeepCopy()
		shapes, err := hybrid.GetInstanceTypes(ctx, np)
		if err != nil || len(shapes) == 0 {
			t.Fatal("incorrect catalogue routing", err)
		}
		if _, err := hybrid.IsDrifted(ctx, claim); err != nil {
			t.Fatal(err)
		}
	}
	all, err := hybrid.List(ctx)
	if err != nil || len(all) != 2 {
		t.Fatal("incomplete hybrid inventory", err)
	}
	mismatch := vmClaim.DeepCopy()
	mismatch.Status.ProviderID = emClaim.Status.ProviderID
	if err := hybrid.Delete(ctx, mismatch); err == nil || metalBackend.StopCalls != 0 || vmBackend.deletes != 0 {
		t.Fatal("mismatched class and providerID reached a destructive backend")
	}
	foreign := vmClaim.DeepCopy()
	foreign.Spec.NodeClassRef.Group = "another.provider"
	if _, err := hybrid.Create(ctx, foreign); err == nil {
		t.Fatal("foreign class accepted")
	}
	if _, err := hybrid.Get(ctx, "unknown://server"); err == nil {
		t.Fatal("unknown providerID accepted")
	}
	if hybrid.Name() != "scaleway" || len(hybrid.GetSupportedNodeClasses()) != 2 || len(hybrid.RepairPolicies()) != 0 {
		t.Fatal("unexpected hybrid capabilities")
	}
	for _, claim := range []*karpv1.NodeClaim{emClaim, vmClaim} {
		if err := hybrid.Delete(ctx, claim); err != nil {
			t.Fatal(err)
		}
		if err := hybrid.Delete(ctx, claim); !core.IsNodeClaimNotFoundError(err) {
			t.Fatal("termination not confirmed", err)
		}
	}
}

func TestDurableRestartKeepsReservationAndResumes(t *testing.T) {
	c, b := durableFixture(t)
	b.StartKeepsStopped = true
	ctx := context.Background()
	a := namedNodeClaim("a")
	one, err := c.Create(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	restarted := New(c.kubeClient, b, pool.NewInventory(b, 0), c.store.Namespace)
	two, err := restarted.Create(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	if one.Status.ProviderID != two.Status.ProviderID || b.StartCalls != 1 {
		t.Fatal("retry duplicated power-on")
	}
	if _, err = restarted.Create(ctx, namedNodeClaim("b")); !core.IsInsufficientCapacityError(err) {
		t.Fatalf("reservation stolen: %v", err)
	}
	if _, err = restarted.Get(ctx, one.Status.ProviderID); err != nil {
		t.Fatal("pending instance hidden from GC", err)
	}
	list, err := restarted.List(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("pending inventory: %v %v", list, err)
	}
	a.Status = one.Status
	if err = restarted.Delete(ctx, a); err == nil || core.IsNodeClaimNotFoundError(err) {
		t.Fatal("ambiguous start finalized")
	}
}

func TestDurableDeleteAndStaleOwner(t *testing.T) {
	c, b := durableFixture(t)
	ctx := context.Background()
	a := namedNodeClaim("a")
	one, err := c.Create(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	a.Status = one.Status
	if err = c.Delete(ctx, a); err != nil {
		t.Fatal(err)
	}
	if err = c.Delete(ctx, a); !core.IsNodeClaimNotFoundError(err) {
		t.Fatal(err)
	}
	if err = c.Delete(ctx, a); !core.IsNodeClaimNotFoundError(err) {
		t.Fatal("delete not idempotent", err)
	}
	if _, err = c.Create(ctx, namedNodeClaim("b")); err != nil {
		t.Fatal(err)
	}
	stops := b.StopCalls
	if err = c.Delete(ctx, a); err == nil || b.StopCalls != stops {
		t.Fatal("stale owner stopped newly allocated server")
	}
}

func TestDurableConcurrentControllersSingleServer(t *testing.T) {
	c, b := durableFixture(t)
	b.StartKeepsStopped = true
	other := New(c.kubeClient, b, pool.NewInventory(b, 0), c.store.Namespace)
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for i, p := range []*Durable{c, other} {
		wg.Add(1)
		go func(i int, p *Durable) {
			defer wg.Done()
			_, err := p.Create(context.Background(), namedNodeClaim([]string{"a", "b"}[i]))
			errs <- err
		}(i, p)
	}
	wg.Wait()
	close(errs)
	success := 0
	for err := range errs {
		if err == nil {
			success++
		}
	}
	if success != 1 || b.StartCalls != 1 {
		t.Fatalf("success=%d starts=%d", success, b.StartCalls)
	}
}

func TestDurableMissingPoolDoesNotFinalizeLiveServer(t *testing.T) {
	c, b := durableFixture(t)
	ctx := context.Background()
	a := namedNodeClaim("a")
	n, err := c.Create(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	a.Status = n.Status
	s := testServer("aaa", pool.StatusReady)
	s.Tags = nil
	b.AddServer(s)
	if err = c.Delete(ctx, a); err == nil || core.IsNodeClaimNotFoundError(err) {
		t.Fatalf("lost ownership treated as termination: %v", err)
	}
}

func TestDurableRejectsUnknownArchitectureOrPrice(t *testing.T) {
	for _, offer := range []pool.Offer{
		{Name: testOffer, Architecture: "arm64", CPUThreads: 32, MemoryBytes: 128 * gib, PricePerHour: 1},
		{Name: testOffer, Architecture: "amd64", CPUThreads: 32, MemoryBytes: 128 * gib},
	} {
		c, b := durableFixture(t)
		b.AddOffer(offer)
		if _, err := c.Create(context.Background(), namedNodeClaim("a")); err == nil || b.StartCalls != 0 {
			t.Fatalf("unsafe offer accepted: %+v", offer)
		}
	}
}

type fakeVM struct {
	servers                     []vm.Server
	shapes                      []vm.Shape
	creates, starts, deletes    int
	createErr, errorAfterCreate error
	config                      []byte
}

func (b *fakeVM) Validate(context.Context, *v1alpha1.ScalewayVMNodeClass) error { return nil }

func (b *fakeVM) Shapes(context.Context, string) ([]vm.Shape, error) { return b.shapes, nil }
func (b *fakeVM) List(_ context.Context, z, p string, tags []string) ([]vm.Server, error) {
	var result []vm.Server
	for _, s := range b.servers {
		if s.Zone != z || s.Project != p {
			continue
		}
		match := true
		for _, tag := range tags {
			if !slices.Contains(s.Tags, tag) {
				match = false
			}
		}
		if match {
			result = append(result, s)
		}
	}
	return result, nil
}
func (b *fakeVM) Get(_ context.Context, z, id string) (vm.Server, error) {
	for _, s := range b.servers {
		if s.Zone == z && s.ID == id {
			return s, nil
		}
	}
	return vm.Server{}, vm.ErrNotFound
}
func (b *fakeVM) Create(_ context.Context, nc *v1alpha1.ScalewayVMNodeClass, name, shape string, tags []string) (vm.Server, error) {
	b.creates++
	if b.createErr != nil {
		return vm.Server{}, b.createErr
	}
	s := vm.Server{ID: "vm-1", Zone: nc.Spec.Zone, Project: nc.Spec.ProjectID, Type: shape, State: "stopped", Tags: tags}
	b.servers = append(b.servers, s)
	return s, b.errorAfterCreate
}
func (b *fakeVM) Configure(_ context.Context, _ *v1alpha1.ScalewayVMNodeClass, _ vm.Server, data []byte) error {
	b.config = data
	return nil
}
func (b *fakeVM) Start(_ context.Context, s vm.Server) error {
	b.starts++
	for i := range b.servers {
		if b.servers[i].ID == s.ID {
			b.servers[i].State = "running"
		}
	}
	return nil
}
func (b *fakeVM) Delete(_ context.Context, s vm.Server) error {
	b.deletes++
	b.servers = slices.DeleteFunc(b.servers, func(v vm.Server) bool { return v.ID == s.ID })
	return nil
}

func vmFixture(t *testing.T) (*VM, *fakeVM, *karpv1.NodeClaim) {
	t.Helper()
	id := "11111111-1111-4111-8111-111111111111"
	nc := &v1alpha1.ScalewayVMNodeClass{ObjectMeta: metav1.ObjectMeta{Name: "vm"}, Spec: v1alpha1.ScalewayVMNodeClassSpec{Zone: testZone, ProjectID: id, ImageID: id, PrivateNetworkID: id, SecurityGroupID: id, BootstrapSecret: "worker", Architecture: "amd64", InstanceTypes: []string{"small", "large"}, EphemeralDiskGiB: 20}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "worker", Namespace: "autoscaling"}, Data: map[string][]byte{"machineconfig": []byte("machine:\n  type: worker\ncluster:\n  clusterName: test\n")}}
	kube := fake.NewClientBuilder().WithScheme(scheme.Scheme).WithObjects(nc, secret).
		WithStatusSubresource(&karpv1.NodeClaim{}).Build()
	b := &fakeVM{shapes: []vm.Shape{{Name: "large", Architecture: "amd64", CPU: 8, Memory: 16 * gib, Price: 0.4, Available: true}, {Name: "small", Architecture: "amd64", CPU: 2, Memory: 4 * gib, Price: 0.1, Available: true}}}
	c := &VM{Client: kube, Backend: b, Store: reservation.Store{Client: kube, Namespace: "autoscaling"}, ClusterID: "test-id", ClusterName: "test"}
	claim := namedNodeClaim("vm")
	claim.Spec.NodeClassRef = &karpv1.NodeClassReference{Group: v1alpha1.Group, Kind: "ScalewayVMNodeClass", Name: "vm"}
	claim.Spec.Resources.Requests = corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("1"), corev1.ResourceMemory: resource.MustParse("2Gi")}
	return c, b, claim
}

func TestVMCheapestFitAndBootstrap(t *testing.T) {
	c, b, n := vmFixture(t)
	n.Spec.Requirements = []karpv1.NodeSelectorRequirementWithMinValues{{Key: "workload", Operator: corev1.NodeSelectorOpIn, Values: []string{"elastic"}}}
	created, err := c.Create(context.Background(), n)
	if err != nil {
		t.Fatal(err)
	}
	if created.Labels[corev1.LabelInstanceTypeStable] != "small" {
		t.Fatal("not cheapest fitting VM")
	}
	if !strings.Contains(string(b.config), "provider-id: scaleway://fr-par-2/vm-1") || !strings.Contains(string(b.config), "kubeReserved:") {
		t.Fatal("missing Talos bootstrap settings")
	}
	if _, err = c.Create(context.Background(), n); err != nil {
		t.Fatal(err)
	}
	if b.creates != 1 || b.starts != 1 {
		t.Fatal("retry duplicated VM or power-on")
	}
}

func TestVMLargerRequestsChooseLargerType(t *testing.T) {
	c, _, n := vmFixture(t)
	n.Spec.Resources.Requests[corev1.ResourceCPU] = resource.MustParse("3")
	r, err := c.Create(context.Background(), n)
	if err != nil {
		t.Fatal(err)
	}
	if r.Labels[corev1.LabelInstanceTypeStable] != "large" {
		t.Fatal("size did not follow requests")
	}
}

func TestVMUnavailableCapacityDoesNotCreate(t *testing.T) {
	c, b, n := vmFixture(t)
	for i := range b.shapes {
		b.shapes[i].Available = false
	}
	if _, err := c.Create(context.Background(), n); !core.IsInsufficientCapacityError(err) || b.creates != 0 {
		t.Fatalf("unexpected launch: %v", err)
	}
}

func TestVMTimeoutRecoveryAndNoDuplicate(t *testing.T) {
	for _, created := range []bool{true, false} {
		t.Run(map[bool]string{true: "accepted", false: "unknown"}[created], func(t *testing.T) {
			c, b, n := vmFixture(t)
			timeout := errors.New("timeout")
			if created {
				b.errorAfterCreate = timeout
			} else {
				b.createErr = timeout
			}
			if _, err := c.Create(context.Background(), n); err == nil {
				t.Fatal("missing API error")
			}
			restarted := *c
			_, err := restarted.Create(context.Background(), n)
			if created && err != nil {
				t.Fatal(err)
			}
			if !created && err == nil {
				t.Fatal("ambiguous create reported success")
			}
			if b.creates != 1 {
				t.Fatal("duplicate POST after timeout")
			}
		})
	}
}

func TestVMDeleteProtectsForeignTagsAndIsIdempotent(t *testing.T) {
	c, b, n := vmFixture(t)
	ctx := context.Background()
	r, err := c.Create(ctx, n)
	if err != nil {
		t.Fatal(err)
	}
	n.Status = r.Status
	tags := b.servers[0].Tags
	b.servers[0].Tags = nil
	if err = c.Delete(ctx, n); err == nil || b.deletes != 0 {
		t.Fatal("foreign VM deleted")
	}
	b.servers[0].Tags = tags
	if err = c.Delete(ctx, n); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err = c.Delete(ctx, n); !core.IsNodeClaimNotFoundError(err) {
			t.Fatal("delete not idempotent", err)
		}
	}
}

func TestVMRejectsControlPlaneBootstrap(t *testing.T) {
	c, b, n := vmFixture(t)
	ctx := context.Background()
	s := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "worker", Namespace: "autoscaling"}}
	if err := c.Client.Get(ctx, client.ObjectKeyFromObject(s), s); err != nil {
		t.Fatal(err)
	}
	s.Data["machineconfig"] = []byte("machine:\n  type: controlplane\ncluster:\n  clusterName: test\n")
	if err := c.Client.Update(ctx, s); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Create(ctx, n); err == nil || b.creates != 0 {
		t.Fatal("control plane launched")
	}
}

func TestVMBootstrapPreservesTalosExtraDocuments(t *testing.T) {
	c, b, n := vmFixture(t)
	ctx := context.Background()
	s := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "worker", Namespace: "autoscaling"}}
	if err := c.Client.Get(ctx, client.ObjectKeyFromObject(s), s); err != nil {
		t.Fatal(err)
	}
	s.Data["machineconfig"] = append(s.Data["machineconfig"], []byte("---\napiVersion: v1alpha1\nkind: VolumeConfig\nname: EPHEMERAL\nprovisioning:\n  diskSelector:\n    match: '!system_disk'\n")...)
	if err := c.Client.Update(ctx, s); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Create(ctx, n); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b.config), "kind: VolumeConfig") || !strings.Contains(string(b.config), "!system_disk") {
		t.Fatal("extra Talos config document lost")
	}
}
