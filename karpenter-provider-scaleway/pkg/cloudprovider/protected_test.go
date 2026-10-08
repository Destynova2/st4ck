package cloudprovider

import (
	"context"
	"errors"
	"testing"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/controllers/termination"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/utils/clock"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
	"sigs.k8s.io/karpenter/pkg/controllers/nodeclaim/lifecycle"
)

func TestPartialVMLaunchRemainsProtectedUntilCloudCleanup(t *testing.T) {
	for _, accepted := range []bool{true, false} {
		t.Run(map[bool]string{true: "accepted", false: "unknown"}[accepted], func(t *testing.T) {
			vmProvider, backend, claim := vmFixture(t)
			ctx := context.Background()
			claim.Finalizers = []string{karpv1.TerminationFinalizer}
			if err := vmProvider.Client.Create(ctx, claim); err != nil {
				t.Fatal(err)
			}
			metal, _ := durableFixture(t)
			hybrid := &Hybrid{Metal: metal, VM: vmProvider}
			provider := &Protected{CloudProvider: hybrid, Client: vmProvider.Client}
			if accepted {
				backend.errorAfterCreate = errors.New("lost response")
			} else {
				backend.createErr = errors.New("unknown outcome")
			}
			if _, err := provider.Create(ctx, claim); err == nil {
				t.Fatal("expected launch error")
			}
			if err := vmProvider.Client.Delete(ctx, claim); err != nil {
				t.Fatal(err)
			}
			if err := vmProvider.Client.Get(ctx, client.ObjectKeyFromObject(claim), claim); err != nil {
				t.Fatal(err)
			}
			coreController := lifecycle.NewController(clock.RealClock{}, vmProvider.Client, provider, nil, nil, nil)
			if _, err := coreController.Reconcile(ctx, claim); err != nil {
				t.Fatal(err)
			}
			if err := vmProvider.Client.Get(ctx, client.ObjectKeyFromObject(claim), claim); err != nil {
				t.Fatal("core lost protected claim", err)
			}
			if !controllerutil.ContainsFinalizer(claim, reservation.Finalizer) {
				t.Fatal("missing partial-launch protection")
			}
			controller := &termination.Controller{Provider: provider}
			// A new wrapper after restart must recover using only API state.
			controller.Provider = &Protected{CloudProvider: hybrid, Client: vmProvider.Client}
			_, err := controller.Reconcile(ctx, claim)
			if !accepted {
				if err == nil {
					t.Fatal("ambiguous creation finalized")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err := controller.Reconcile(ctx, claim); err != nil {
				t.Fatal(err)
			}
			if err := vmProvider.Client.Get(ctx, client.ObjectKeyFromObject(claim), claim); !apierrors.IsNotFound(err) {
				t.Fatalf("claim not finalized: %v", err)
			}
			leases, err := vmProvider.Store.All(ctx)
			if err != nil || len(leases) != 0 || len(backend.servers) != 0 {
				t.Fatalf("leaked capacity: leases=%d servers=%d error=%v", len(leases), len(backend.servers), err)
			}
		})
	}
}

func TestProtectedFinalizerWriteFailurePreventsCloudCalls(t *testing.T) {
	c, backend, claim := vmFixture(t)
	ctx := context.Background()
	if err := c.Client.Create(ctx, claim); err != nil {
		t.Fatal(err)
	}
	p := &Protected{CloudProvider: c, Client: interceptor.NewClient(c.Client.(client.WithWatch), interceptor.Funcs{
		Patch: func(context.Context, client.WithWatch, client.Object, client.Patch, ...client.PatchOption) error {
			return errors.New("API unavailable")
		},
	})}
	if _, err := p.Create(ctx, claim); err == nil || backend.creates != 0 {
		t.Fatal("cloud call attempted before durable finalizer")
	}
}

func TestProtectedNominalCoreTermination(t *testing.T) {
	c, backend, claim := vmFixture(t)
	ctx := context.Background()
	claim.Finalizers = []string{karpv1.TerminationFinalizer}
	if err := c.Client.Create(ctx, claim); err != nil {
		t.Fatal(err)
	}
	p := &Protected{CloudProvider: c, Client: c.Client}
	created, err := p.Create(ctx, claim)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Client.Get(ctx, client.ObjectKeyFromObject(claim), claim); err != nil {
		t.Fatal(err)
	}
	claim.Status = created.Status
	if err = c.Client.Status().Update(ctx, claim); err != nil {
		t.Fatal(err)
	}
	if err = c.Client.Delete(ctx, claim); err != nil {
		t.Fatal(err)
	}
	controller := lifecycle.NewController(clock.RealClock{}, c.Client, p, nil, nil, nil)
	for attempt := 0; attempt < 6; attempt++ {
		if err = c.Client.Get(ctx, client.ObjectKeyFromObject(claim), claim); apierrors.IsNotFound(err) {
			leases, listErr := c.Store.All(ctx)
			if listErr != nil || len(leases) != 0 || len(backend.servers) != 0 {
				t.Fatal("finalized before cleanup", listErr)
			}
			return
		} else if err != nil {
			t.Fatal(err)
		}
		if _, err = controller.Reconcile(ctx, claim); err != nil {
			t.Fatal(err)
		}
	}
	t.Fatal("finalizers never completed")
}

func TestProtectedCreateRefusesMissingOrDeletingClaim(t *testing.T) {
	c, backend, claim := vmFixture(t)
	p := &Protected{CloudProvider: c, Client: c.Client}
	ctx := context.Background()
	if _, err := p.Create(ctx, claim); err == nil {
		t.Fatal("missing claim accepted")
	}
	claim.Finalizers = []string{karpv1.TerminationFinalizer}
	if err := c.Client.Create(ctx, claim); err != nil {
		t.Fatal(err)
	}
	if err := c.Client.Delete(ctx, claim); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Create(ctx, claim); err == nil || backend.creates != 0 {
		t.Fatal("deleting claim launched")
	}
}

func TestDurableSkipsDefinitivelyRejectedServer(t *testing.T) {
	c, backend := durableFixture(t)
	backend.AddServer(testServer("bbb", pool.StatusStopped))
	backend.StartErrFor = map[string]error{"aaa": pool.ErrNotStartable}
	created, err := c.Create(context.Background(), namedNodeClaim("a"))
	if err != nil {
		t.Fatal(err)
	}
	if created.Status.ProviderID != pool.FormatProviderID(testZone, "bbb") || backend.StartCalls != 2 {
		t.Fatal("did not try next server")
	}
	if _, err := c.store.Get(context.Background(), pool.FormatProviderID(testZone, "aaa")); !apierrors.IsNotFound(err) {
		t.Fatal("rejected reservation leaked")
	}
}

func TestDurableDefinitiveRejectionReturnsCapacityError(t *testing.T) {
	c, backend := durableFixture(t)
	backend.StartErr = pool.ErrNotStartable
	_, err := c.Create(context.Background(), namedNodeClaim("a"))
	if !core.IsInsufficientCapacityError(err) {
		t.Fatalf("expected capacity error: %v", err)
	}
}

type countingVM struct {
	*fakeVM
	validations int
}

func (b *countingVM) Validate(context.Context, *v1alpha1.ScalewayVMNodeClass) error {
	b.validations++
	return nil
}
func TestVMCreationValidatesOnce(t *testing.T) {
	c, backend, claim := vmFixture(t)
	counter := &countingVM{fakeVM: backend}
	c.Backend = counter
	if _, err := c.Create(context.Background(), claim); err != nil {
		t.Fatal(err)
	}
	if counter.validations != 1 {
		t.Fatalf("validation calls=%d", counter.validations)
	}
}
