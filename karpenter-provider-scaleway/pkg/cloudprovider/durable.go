package cloudprovider

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"

	"github.com/awslabs/operatorpkg/status"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
	"sigs.k8s.io/karpenter/pkg/scheduling"
	"sigs.k8s.io/karpenter/pkg/utils/resources"
)

// Durable manages Elastic Metal power transitions with persistent ownership.
// The embedded helpers supply inventory and shape resolution only.
type Durable struct {
	*CloudProvider
	store    reservation.Store
	createMu sync.Mutex
}

func NewDurable(base *CloudProvider, store reservation.Store) *Durable {
	return &Durable{CloudProvider: base, store: store}
}

// New requires an uncached Kubernetes client and a persistent reservation namespace.
func New(kubeClient client.Client, backend pool.Backend, inventory *pool.Inventory, namespace string) *Durable {
	if namespace == "" {
		panic("reservation namespace is required")
	}
	return NewDurable(newBase(kubeClient, backend, inventory), reservation.Store{Client: kubeClient, Namespace: namespace})
}

func (c *Durable) Create(ctx context.Context, claim *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	c.createMu.Lock()
	defer c.createMu.Unlock()
	nc, err := c.resolveNodeClassFromNodeClaim(ctx, claim)
	if err != nil {
		return nil, core.NewNodeClassNotReadyError(err)
	}
	if !nc.StatusConditions().Get(status.ConditionReady).IsTrue() {
		return nil, core.NewNodeClassNotReadyError(fmt.Errorf("node class %q is not ready", nc.Name))
	}
	it, err := c.buildInstanceType(ctx, nc, nil, false)
	if err != nil {
		return nil, err
	}
	reqs := scheduling.NewNodeSelectorRequirementsWithMinValues(claim.Spec.Requirements...)
	if !reqs.IsCompatible(it.Requirements, scheduling.AllowUndefinedWellKnownLabels) || !resources.Fits(claim.Spec.Resources.Requests, it.Allocatable()) {
		return nil, core.NewInsufficientCapacityError(fmt.Errorf("metal offer does not fit NodeClaim requirements"))
	}
	servers, err := c.backend.ListServers(ctx, nc.Spec.Zone, nc.Spec.PoolTag)
	if err != nil {
		return nil, err
	}
	slices.SortFunc(servers, func(a, b pool.Server) int { return strings.Compare(a.ID, b.ID) })
	// The UID binding makes concurrent/retried Create choose the same server,
	// even during leader failover. It is updated before reserving the server.
	binding, _, err := c.store.Acquire(ctx, "em-claim/"+string(claim.UID), claim.UID, nil)
	if err != nil {
		return nil, err
	}
	bound := binding.Annotations[reservation.Prefix+"server"]
	for _, server := range servers {
		key := pool.FormatProviderID(nc.Spec.Zone, server.ID)
		if bound != "" && bound != key {
			continue
		}
		if server.OfferName != nc.Spec.OfferName {
			continue
		}
		if bound == "" {
			if server.Status != pool.StatusStopped {
				continue
			}
			l, e := c.store.Get(ctx, key)
			if e == nil && reservation.Owner(l) != string(claim.UID) {
				continue
			}
			if e != nil && !apierrors.IsNotFound(e) {
				return nil, e
			}
			if err = c.store.Set(ctx, binding, "server", key); err != nil {
				return nil, err
			}
			bound = key
		}
		l, owned, e := c.store.Acquire(ctx, key, claim.UID, map[string]string{"node-class": nc.Name})
		if e != nil {
			return nil, e
		}
		if !owned {
			if err = c.store.Set(ctx, binding, "server", ""); err != nil {
				return nil, err
			}
			bound = ""
			continue
		}
		phase := l.Annotations[reservation.Prefix+"phase"]
		if phase == "stopping" {
			return nil, fmt.Errorf("reservation is terminating")
		}
		if phase == "" {
			if server.Status != pool.StatusStopped {
				return nil, fmt.Errorf("reserved server changed state before power-on")
			}
			// Persist intent BEFORE power-on. A timeout or crash keeps the
			// reservation and never allows another UID to take this hardware.
			if err = c.store.Set(ctx, l, "phase", "starting"); err != nil {
				return nil, err
			}
			if err = c.backend.StartServer(ctx, nc.Spec.Zone, server.ID); err != nil {
				if !errors.Is(err, pool.ErrNotStartable) {
					return nil, fmt.Errorf("power-on outcome requires reconciliation (reservation retained): %w", err)
				}
				if err = c.store.Set(ctx, l, "phase", "rejected"); err != nil {
					return nil, err
				}
				phase = "rejected"
			}
		}
		if phase == "rejected" {
			current, e := c.backend.GetServer(ctx, nc.Spec.Zone, server.ID)
			if e != nil || current.Status != pool.StatusStopped {
				return nil, fmt.Errorf("rejected power-on needs reconciliation: state=%s, error=%v", current.Status, e)
			}
			if err = c.store.Release(ctx, l, claim.UID); err != nil {
				return nil, err
			}
			if err = c.store.Set(ctx, binding, "server", ""); err != nil {
				return nil, err
			}
			bound = ""
			continue
		}
		if server.Status == pool.StatusReady && phase != "running" {
			if err = c.store.Set(ctx, l, "phase", "running"); err != nil {
				return nil, err
			}
		}
		c.inventory.Invalidate(nc.Spec.Zone, nc.Spec.PoolTag)
		return c.toNodeClaim(server, nc.Spec.Zone, it, claim.Labels, claim.Annotations), nil
	}
	if bound != "" {
		return nil, fmt.Errorf("reserved server no longer matches the node class; manual reconciliation required")
	}
	return nil, core.NewInsufficientCapacityError(fmt.Errorf("no unreserved stopped server in %q", nc.Spec.PoolTag))
}

func (c *Durable) Delete(ctx context.Context, claim *karpv1.NodeClaim) error {
	providerID := claim.Status.ProviderID
	binding, berr := c.store.Get(ctx, "em-claim/"+string(claim.UID))
	if berr != nil && !apierrors.IsNotFound(berr) {
		return berr
	}
	if providerID == "" && berr == nil {
		providerID = binding.Annotations[reservation.Prefix+"server"]
	}
	if providerID == "" {
		if berr == nil {
			if err := c.store.Release(ctx, binding, claim.UID); err != nil {
				return err
			}
		}
		return core.NewNodeClaimNotFoundError(fmt.Errorf("no reserved server"))
	}
	l, err := c.store.Get(ctx, providerID)
	if apierrors.IsNotFound(err) {
		zone, id, e := pool.ParseProviderID(providerID)
		if e != nil {
			return e
		}
		s, e := c.backend.GetServer(ctx, zone, id)
		if e == nil && s.Status == pool.StatusStopped {
			if berr == nil {
				if e = c.store.Release(ctx, binding, claim.UID); e != nil {
					return e
				}
			}
			return core.NewNodeClaimNotFoundError(fmt.Errorf("server already stopped and reservation released"))
		}
		return fmt.Errorf("no ownership record for %s; explicit adoption required", providerID)
	}
	if err != nil {
		return err
	}
	if reservation.Owner(l) != string(claim.UID) {
		return fmt.Errorf("refusing to stop another NodeClaim's server")
	}
	server, zone, err := c.serverFromProviderID(ctx, providerID)
	// De-tagging is not proof of termination. Keep both reservations and
	// finalizer if the pool was edited underneath a running NodeClaim.
	if err != nil {
		return fmt.Errorf("cannot verify reserved hardware: %v", err)
	}
	phase := l.Annotations[reservation.Prefix+"phase"]
	if server.Status == pool.StatusStopped {
		if phase == "starting" {
			return fmt.Errorf("power-on not yet observed; refusing to release an ambiguous reservation")
		}
		if err = c.store.Release(ctx, l, claim.UID); err != nil {
			return err
		}
		if berr == nil {
			if err = c.store.Release(ctx, binding, claim.UID); err != nil {
				return err
			}
		}
		c.invalidateInventoryFor(ctx, zone, server)
		return core.NewNodeClaimNotFoundError(fmt.Errorf("reserved server is stopped"))
	}
	if server.Status.Class() == pool.ClassLive {
		if err = c.store.Set(ctx, l, "phase", "stopping"); err != nil {
			return err
		}
		if err = c.backend.StopServer(ctx, zone, server.ID); err != nil {
			return err
		}
		return nil
	}
	if server.Status.Class() == pool.ClassTerminating || server.Status.Class() == pool.ClassTransient {
		return nil
	}
	return fmt.Errorf("reserved server is %s; manual reconciliation required", server.Status)
}

func (c *Durable) Get(ctx context.Context, id string) (*karpv1.NodeClaim, error) {
	l, err := c.store.Get(ctx, id)
	if apierrors.IsNotFound(err) {
		return c.CloudProvider.Get(ctx, id)
	}
	if err != nil {
		return nil, err
	}
	s, zone, err := c.serverFromProviderID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("reserved server unavailable: %v", err)
	}
	phase := l.Annotations[reservation.Prefix+"phase"]
	if s.Status == pool.StatusReady && phase == "starting" {
		if err = c.store.Set(ctx, l, "phase", "running"); err != nil {
			return nil, err
		}
	}
	if s.Status == pool.StatusStopped && phase != "starting" {
		return nil, core.NewNodeClaimNotFoundError(fmt.Errorf("server is stopped"))
	}
	it, err := c.instanceTypeForServer(ctx, zone, s)
	if err != nil {
		return nil, err
	}
	return c.toNodeClaim(s, zone, it, nil, nil), nil
}

func (c *Durable) List(ctx context.Context) ([]*karpv1.NodeClaim, error) {
	result, err := c.CloudProvider.List(ctx)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, n := range result {
		seen[n.Status.ProviderID] = true
	}
	leases, err := c.store.All(ctx)
	if err != nil {
		return nil, err
	}
	for _, l := range leases {
		id := l.Annotations[reservation.Prefix+"resource"]
		if !strings.HasPrefix(id, "scaleway-em://") || seen[id] {
			continue
		}
		n, e := c.Get(ctx, id)
		if core.IsNodeClaimNotFoundError(e) {
			continue
		}
		if e != nil {
			return nil, e
		}
		result = append(result, n)
	}
	return result, nil
}

func (c *Durable) GetInstanceTypes(ctx context.Context, np *karpv1.NodePool) ([]*core.InstanceType, error) {
	nc, err := c.resolveNodeClassFromNodePool(ctx, np)
	if err != nil {
		return nil, err
	}
	servers, err := c.inventory.Snapshot(ctx, nc.Spec.Zone, nc.Spec.PoolTag)
	if err != nil {
		return nil, err
	}
	var free []pool.Server
	for _, server := range servers {
		if server.OfferName != nc.Spec.OfferName || server.Status != pool.StatusStopped {
			continue
		}
		_, err = c.store.Get(ctx, pool.FormatProviderID(nc.Spec.Zone, server.ID))
		if apierrors.IsNotFound(err) {
			free = append(free, server)
		} else if err != nil {
			return nil, err
		}
	}
	it, err := c.buildInstanceType(ctx, nc, free, true)
	if err != nil {
		return nil, err
	}
	return []*core.InstanceType{it}, nil
}
