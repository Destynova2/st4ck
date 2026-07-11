package nodeclass

import (
	"context"
	"errors"
	"testing"

	"github.com/awslabs/operatorpkg/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

const (
	testZone    = "fr-par-2"
	testPoolTag = "st4ck.io/karpenter-pool=metal"
	testOffer   = "EM-A116X-SSD"
)

func testNodeClass() *v1alpha1.ScalewayEMNodeClass {
	return &v1alpha1.ScalewayEMNodeClass{
		ObjectMeta: metav1.ObjectMeta{Name: "metal-pool"},
		Spec: v1alpha1.ScalewayEMNodeClassSpec{
			Zone:      testZone,
			PoolTag:   testPoolTag,
			OfferName: testOffer,
		},
	}
}

func reconcileOnce(t *testing.T, backend pool.Backend) *v1alpha1.ScalewayEMNodeClass {
	t.Helper()
	nodeClass := testNodeClass()
	kubeClient := fake.NewClientBuilder().
		WithScheme(scheme.Scheme).
		WithObjects(nodeClass).
		WithStatusSubresource(&v1alpha1.ScalewayEMNodeClass{}).
		Build()
	controller := NewController(kubeClient, backend)

	if _, err := controller.Reconcile(context.Background(), nodeClass); err != nil {
		t.Fatalf("Reconcile returned error: %v", err)
	}
	persisted := &v1alpha1.ScalewayEMNodeClass{}
	if err := kubeClient.Get(context.Background(), types.NamespacedName{Name: "metal-pool"}, persisted); err != nil {
		t.Fatalf("getting persisted node class: %v", err)
	}
	return persisted
}

func TestReconcileNominal(t *testing.T) {
	backend := pool.NewFakeBackend()
	backend.AddOffer(pool.Offer{Name: testOffer, CPUThreads: 32, MemoryBytes: 1 << 37, PricePerHour: 1.25})
	for id, st := range map[string]pool.Status{"aaa": pool.StatusStopped, "bbb": pool.StatusStopped, "ccc": pool.StatusReady} {
		backend.AddServer(pool.Server{ID: id, Zone: testZone, Status: st, OfferName: testOffer, Tags: []string{testPoolTag}})
	}

	nodeClass := reconcileOnce(t, backend)
	if !nodeClass.StatusConditions().Get(status.ConditionReady).IsTrue() {
		t.Errorf("Ready condition should be true, conditions: %+v", nodeClass.Status.Conditions)
	}
	if nodeClass.Status.PoolSize != 3 {
		t.Errorf("PoolSize = %d, want 3", nodeClass.Status.PoolSize)
	}
	if nodeClass.Status.Available != 2 {
		t.Errorf("Available = %d, want 2", nodeClass.Status.Available)
	}
}

func TestReconcileEmptyPool(t *testing.T) {
	backend := pool.NewFakeBackend()
	backend.AddOffer(pool.Offer{Name: testOffer})

	nodeClass := reconcileOnce(t, backend)
	if !nodeClass.StatusConditions().Get(status.ConditionReady).IsFalse() {
		t.Errorf("Ready condition should be false for an empty pool")
	}
	if got := nodeClass.StatusConditions().Get(v1alpha1.ConditionTypePoolReady).Reason; got != "PoolEmpty" {
		t.Errorf("PoolReady reason = %q, want PoolEmpty", got)
	}
}

func TestReconcileAPIError(t *testing.T) {
	backend := pool.NewFakeBackend()
	backend.ListErr = errors.New("401 invalid credentials")

	nodeClass := reconcileOnce(t, backend)
	if !nodeClass.StatusConditions().Get(status.ConditionReady).IsFalse() {
		t.Errorf("Ready condition should be false on API error")
	}
	if got := nodeClass.StatusConditions().Get(v1alpha1.ConditionTypePoolReady).Reason; got != "APIError" {
		t.Errorf("PoolReady reason = %q, want APIError", got)
	}
}

func TestReconcileOfferNotFound(t *testing.T) {
	backend := pool.NewFakeBackend()
	backend.AddServer(pool.Server{ID: "aaa", Zone: testZone, Status: pool.StatusStopped, OfferName: testOffer, Tags: []string{testPoolTag}})

	nodeClass := reconcileOnce(t, backend)
	if !nodeClass.StatusConditions().Get(status.ConditionReady).IsFalse() {
		t.Errorf("Ready condition should be false when the offer is unresolvable")
	}
	if got := nodeClass.StatusConditions().Get(v1alpha1.ConditionTypePoolReady).Reason; got != "OfferNotFound" {
		t.Errorf("PoolReady reason = %q, want OfferNotFound", got)
	}
	if nodeClass.Status.PoolSize != 1 {
		t.Errorf("PoolSize = %d, want 1 (inventory still observed)", nodeClass.Status.PoolSize)
	}
}
