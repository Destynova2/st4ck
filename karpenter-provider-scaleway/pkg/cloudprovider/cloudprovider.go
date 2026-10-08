// Package cloudprovider implements the karpenter-core CloudProvider contract
// on top of a finite pool of pre-imaged Scaleway Elastic Metal servers:
// Create = power-on, Delete = power-off. Servers are never ordered nor
// destroyed (LLD-002 §3).
package cloudprovider

import (
	"context"
	stderrors "errors"
	"fmt"
	"slices"

	"github.com/awslabs/operatorpkg/status"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

const (
	// ProviderName identifies this CloudProvider implementation.
	ProviderName = "scaleway-em"

	// AnnotationServerName records the Elastic Metal server name on
	// NodeClaims for operator debuggability.
	AnnotationServerName = v1alpha1.Group + "/server-name"
)

// CloudProvider contains read-only Elastic Metal inventory helpers.
// Lifecycle operations exist only on Durable.
type CloudProvider struct {
	kubeClient client.Client
	backend    pool.Backend
	inventory  *pool.Inventory
}

var _ cloudprovider.CloudProvider = (*Durable)(nil)

func newBase(kubeClient client.Client, backend pool.Backend, inventory *pool.Inventory) *CloudProvider {
	return &CloudProvider{
		kubeClient: kubeClient,
		backend:    backend,
		inventory:  inventory,
	}
}

// Get maps a provider ID back to a NodeClaim. Only a `stopped` (or absent)
// server is reported as not found; every other status — including blocked
// and failed ones — keeps the NodeClaim visible (fail closed).
func (c *CloudProvider) Get(ctx context.Context, providerID string) (*karpv1.NodeClaim, error) {
	server, zone, err := c.serverFromProviderID(ctx, providerID)
	if err != nil {
		return nil, err
	}
	if server.Status.Class() == pool.ClassStartable {
		return nil, cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("server %q is %s", server.ID, server.Status))
	}
	it, err := c.instanceTypeForServer(ctx, zone, server)
	if err != nil {
		return nil, fmt.Errorf("resolving instance type for server %q, %w", server.ID, err)
	}
	return c.toNodeClaim(server, zone, it, nil, nil), nil
}

// serverFromProviderID parses a provider ID, fetches the server and enforces
// pool membership. An absent server maps to NodeClaimNotFoundError; a server
// that carries no declared pool tag is refused (also NotFound, without any
// power action): the single Scaleway project is shared across envs and the
// controller IAM is ElasticMetalFullAccess, so a forged or stale provider ID
// must never reach StopServer (pre-mortem S1). NotFound (rather than an
// error) describes inventory only. Durable wraps this as an error when a
// reservation exists: de-tagging must never release its owner or finalizer.
func (c *CloudProvider) serverFromProviderID(ctx context.Context, providerID string) (pool.Server, string, error) {
	zone, serverID, err := pool.ParseProviderID(providerID)
	if err != nil {
		return pool.Server{}, "", fmt.Errorf("parsing provider ID, %w", err)
	}
	server, err := c.backend.GetServer(ctx, zone, serverID)
	if err != nil {
		if stderrors.Is(err, pool.ErrServerNotFound) {
			return pool.Server{}, "", cloudprovider.NewNodeClaimNotFoundError(err)
		}
		return pool.Server{}, "", fmt.Errorf("getting server %q, %w", serverID, err)
	}
	member, err := c.isPoolMember(ctx, zone, server)
	if err != nil {
		// Cannot verify membership: fail closed, do not act on the server.
		return pool.Server{}, "", fmt.Errorf("verifying pool membership of server %q, %w", serverID, err)
	}
	if !member {
		log.FromContext(ctx).Info("refusing to manage server outside every declared pool",
			"server", serverID, "zone", zone, "tags", server.Tags)
		return pool.Server{}, "", cloudprovider.NewNodeClaimNotFoundError(
			fmt.Errorf("server %q carries no declared pool tag", serverID))
	}
	return server, zone, nil
}

// isPoolMember reports whether the server carries the pool tag of at least
// one declared ScalewayEMNodeClass of its zone.
func (c *CloudProvider) isPoolMember(ctx context.Context, zone string, server pool.Server) (bool, error) {
	nodeClassList := &v1alpha1.ScalewayEMNodeClassList{}
	if err := c.kubeClient.List(ctx, nodeClassList); err != nil {
		return false, fmt.Errorf("listing node classes, %w", err)
	}
	for i := range nodeClassList.Items {
		nc := &nodeClassList.Items[i]
		if nc.Spec.Zone == zone && slices.Contains(server.Tags, nc.Spec.PoolTag) {
			return true, nil
		}
	}
	return false, nil
}

// List returns every pool server except the deliberately powered-off ones
// (`stopped`). Assumed gotcha (LLD §3): an out-of-band power-off makes the
// server disappear from List(), so the ~2 min GC deletes the NodeClaim —
// wanted, it reflects reality. Everything else — including blocked, failed
// or transient statuses — stays visible (fail closed): a maintenance or
// error state must never make the GC believe a live node's instance is
// gone. Servers that never hosted a node (e.g. `delivering`) are harmless
// here: the core GC only removes NodeClaims absent from this list, it never
// acts on unmatched instances.
func (c *CloudProvider) List(ctx context.Context) ([]*karpv1.NodeClaim, error) {
	nodeClassList := &v1alpha1.ScalewayEMNodeClassList{}
	if err := c.kubeClient.List(ctx, nodeClassList); err != nil {
		return nil, fmt.Errorf("listing node classes, %w", err)
	}
	var nodeClaims []*karpv1.NodeClaim
	seen := map[string]struct{}{}
	for i := range nodeClassList.Items {
		nodeClass := &nodeClassList.Items[i]
		// Direct ListServers on purpose (audit F12): List() feeds the core
		// GC, whose tolerance to a ≤10 s stale view is an invariant nobody
		// has written down (XRAY-003 "needs_invariant"). Until that
		// staleness contract is promoted and tested, the GC keeps reading
		// the API directly — ~1 call/2 min/nodeclass, within budget.
		servers, err := c.backend.ListServers(ctx, nodeClass.Spec.Zone, nodeClass.Spec.PoolTag)
		if err != nil {
			return nil, fmt.Errorf("listing pool servers for node class %q, %w", nodeClass.Name, err)
		}
		it, itErr := c.buildInstanceType(ctx, nodeClass, servers, true)
		for _, server := range servers {
			if server.Status.Class() == pool.ClassStartable {
				continue
			}
			providerID := pool.FormatProviderID(nodeClass.Spec.Zone, server.ID)
			if _, ok := seen[providerID]; ok {
				continue
			}
			seen[providerID] = struct{}{}
			if itErr != nil {
				// Shape resolution failing must not hide live capacity from
				// the GC: return a minimally hydrated NodeClaim.
				nodeClaims = append(nodeClaims, c.toNodeClaim(server, nodeClass.Spec.Zone, nil, nil, nil))
				continue
			}
			nodeClaims = append(nodeClaims, c.toNodeClaim(server, nodeClass.Spec.Zone, it, nil, nil))
		}
	}
	return nodeClaims, nil
}

// IsDrifted opts out of provider-side drift; core-side drift reasons remain.
func (c *CloudProvider) IsDrifted(_ context.Context, _ *karpv1.NodeClaim) (cloudprovider.DriftReason, error) {
	return "", nil
}

// RepairPolicies is empty in M0 (no auto-repair).
func (c *CloudProvider) RepairPolicies() []cloudprovider.RepairPolicy {
	return []cloudprovider.RepairPolicy{}
}

func (c *CloudProvider) Name() string {
	return ProviderName
}

func (c *CloudProvider) GetSupportedNodeClasses() []status.Object {
	return []status.Object{&v1alpha1.ScalewayEMNodeClass{}}
}

// invalidateInventoryFor drops the cached snapshot of every declared pool
// the server belongs to (zone and tag match), so availability counts
// recover promptly after a power-off. Pools of the same zone the server is
// not tagged into keep their cache (audit F2 / XRAY-004).
func (c *CloudProvider) invalidateInventoryFor(ctx context.Context, zone string, server pool.Server) {
	nodeClassList := &v1alpha1.ScalewayEMNodeClassList{}
	if err := c.kubeClient.List(ctx, nodeClassList); err != nil {
		// Non-fatal: stale availability self-heals at TTL expiry, but leave
		// a trace instead of swallowing the failure (audit F2).
		log.FromContext(ctx).V(1).Info("failed listing node classes for inventory invalidation", "error", err)
		return
	}
	for i := range nodeClassList.Items {
		nc := &nodeClassList.Items[i]
		if nc.Spec.Zone == zone && slices.Contains(server.Tags, nc.Spec.PoolTag) {
			c.inventory.Invalidate(nc.Spec.Zone, nc.Spec.PoolTag)
		}
	}
}

func (c *CloudProvider) resolveNodeClassFromNodeClaim(ctx context.Context, nodeClaim *karpv1.NodeClaim) (*v1alpha1.ScalewayEMNodeClass, error) {
	if nodeClaim == nil || nodeClaim.Spec.NodeClassRef == nil || nodeClaim.Spec.NodeClassRef.Name == "" {
		return nil, fmt.Errorf("nodeclaim has no node class reference")
	}
	nodeClass := &v1alpha1.ScalewayEMNodeClass{}
	// Wrapping is safe for callers checking apierrors.IsNotFound: it
	// unwraps through %w (audit F6 — both resolvers wrap uniformly).
	if err := c.kubeClient.Get(ctx, types.NamespacedName{Name: nodeClaim.Spec.NodeClassRef.Name}, nodeClass); err != nil {
		return nil, fmt.Errorf("getting node class %q for nodeclaim %q, %w", nodeClaim.Spec.NodeClassRef.Name, nodeClaim.Name, err)
	}
	return nodeClass, nil
}

func (c *CloudProvider) resolveNodeClassFromNodePool(ctx context.Context, nodePool *karpv1.NodePool) (*v1alpha1.ScalewayEMNodeClass, error) {
	if nodePool == nil || nodePool.Spec.Template.Spec.NodeClassRef == nil || nodePool.Spec.Template.Spec.NodeClassRef.Name == "" {
		return nil, fmt.Errorf("nodepool has no node class reference")
	}
	nodeClass := &v1alpha1.ScalewayEMNodeClass{}
	if err := c.kubeClient.Get(ctx, types.NamespacedName{Name: nodePool.Spec.Template.Spec.NodeClassRef.Name}, nodeClass); err != nil {
		return nil, fmt.Errorf("getting node class %q, %w", nodePool.Spec.Template.Spec.NodeClassRef.Name, err)
	}
	return nodeClass, nil
}

// instanceTypeForServer resolves the shape from the server's own offer name,
// used by Get() where no NodeClass is at hand.
func (c *CloudProvider) instanceTypeForServer(ctx context.Context, zone string, server pool.Server) (*cloudprovider.InstanceType, error) {
	offer, err := c.backend.GetOfferByName(ctx, zone, server.OfferName)
	if err != nil {
		return nil, err
	}
	return newInstanceType(offer, zone, true), nil
}

// toNodeClaim hydrates a NodeClaim from a pool server. instanceType may be
// nil (degraded List() path): the claim then carries only identity fields.
func (c *CloudProvider) toNodeClaim(server pool.Server, zone string, instanceType *cloudprovider.InstanceType, baseLabels, baseAnnotations map[string]string) *karpv1.NodeClaim {
	labels := map[string]string{}
	for k, v := range baseLabels {
		labels[k] = v
	}
	labels[corev1.LabelTopologyZone] = zone
	labels[karpv1.CapacityTypeLabelKey] = karpv1.CapacityTypeOnDemand
	annotations := map[string]string{}
	for k, v := range baseAnnotations {
		annotations[k] = v
	}
	annotations[AnnotationServerName] = server.Name

	nodeClaim := &karpv1.NodeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Labels:      labels,
			Annotations: annotations,
		},
		Status: karpv1.NodeClaimStatus{
			ProviderID: pool.FormatProviderID(zone, server.ID),
		},
	}
	if instanceType != nil {
		labels[corev1.LabelInstanceTypeStable] = instanceType.Name
		for key, req := range instanceType.Requirements {
			if req.Len() == 1 && req.Operator() == corev1.NodeSelectorOpIn {
				labels[key] = req.Values()[0]
			}
		}
		nodeClaim.Status.Capacity = instanceType.Capacity
		nodeClaim.Status.Allocatable = instanceType.Allocatable()
	}
	return nodeClaim
}
