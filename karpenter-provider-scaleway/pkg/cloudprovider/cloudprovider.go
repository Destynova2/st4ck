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
	"sort"
	"sync"
	"time"

	"github.com/awslabs/operatorpkg/status"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/utils/clock"
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

	// pendingClaimTTL bounds only claims whose StartServer was never
	// acknowledged (e.g. a Create that panicked between claim and start).
	// A claim whose StartServer succeeded NEVER expires on wall-clock: it
	// is released only when the API stops reporting the server as stopped,
	// or when the server is powered off/leaves the pool. This is what
	// prevents two NodeClaims from ever sharing a providerID when Scaleway
	// is slow to reflect the stopped→starting transition.
	pendingClaimTTL = 2 * time.Minute
)

// serverClaim ties an in-flight Create to its NodeClaim so that a retry of
// the same NodeClaim resumes its own claim instead of consuming another
// server, and a different NodeClaim can never steal a started server.
type serverClaim struct {
	owner     types.UID // NodeClaim UID
	ownerName string    // NodeClaim name, for logs
	at        time.Time
	started   bool // StartServer acknowledged (or its effect observed)
}

type CloudProvider struct {
	kubeClient client.Client
	backend    pool.Backend
	inventory  *pool.Inventory
	clock      clock.Clock

	mu     sync.Mutex
	claims map[string]serverClaim // serverID → in-flight Create ownership
}

var _ cloudprovider.CloudProvider = (*CloudProvider)(nil)

func New(kubeClient client.Client, backend pool.Backend, inventory *pool.Inventory) *CloudProvider {
	return &CloudProvider{
		kubeClient: kubeClient,
		backend:    backend,
		inventory:  inventory,
		clock:      clock.RealClock{},
		claims:     map[string]serverClaim{},
	}
}

// Create picks a stopped pool member, powers it on and returns the NodeClaim
// hydrated with ProviderID, Capacity, Allocatable and labels (copied by
// karpenter-core launch.go). Pool exhaustion should have been prevented by
// Offering.Available=false; the residual race on the last server returns an
// InsufficientCapacityError.
func (c *CloudProvider) Create(ctx context.Context, nodeClaim *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	nodeClass, err := c.resolveNodeClassFromNodeClaim(ctx, nodeClaim)
	if err != nil {
		if errors.IsNotFound(err) {
			// Missing NodeClass is a configuration/readiness failure, not a
			// capacity shortage: ICE would delete the NodeClaim and record
			// misleading insufficient-capacity events (Codex Major #6).
			return nil, cloudprovider.NewNodeClassNotReadyError(err)
		}
		return nil, err
	}
	if ready := nodeClass.StatusConditions().Get(status.ConditionReady); ready.IsFalse() {
		return nil, cloudprovider.NewNodeClassNotReadyError(stderrors.New(ready.Message))
	}

	instanceType, err := c.buildInstanceType(ctx, nodeClass, nil, false)
	if err != nil {
		return nil, fmt.Errorf("resolving instance type for node class %q, %w", nodeClass.Name, err)
	}

	// One rejected server must not starve another startable candidate
	// (re-review Major): a definitive per-server power-on rejection
	// (ErrNotStartable) quarantines that server for this call and the loop
	// progresses to the next candidate. When none remains,
	// claimStoppedServer returns the clean InsufficientCapacityError.
	// Bounded: each iteration excludes one more server.
	var server pool.Server
	excluded := map[string]struct{}{}
	for {
		claimed, err := c.claimStoppedServer(ctx, nodeClass, nodeClaim, excluded)
		if err != nil {
			return nil, err
		}
		server = claimed.server
		err = c.startClaimedServer(ctx, nodeClass, claimed)
		if err == nil {
			break
		}
		if stderrors.Is(err, pool.ErrNotStartable) {
			excluded[server.ID] = struct{}{}
			continue
		}
		return nil, err
	}
	// Flip Offering.Available on the next scheduling loop if this was the
	// last stopped server.
	c.inventory.Invalidate(nodeClass.Spec.Zone, nodeClass.Spec.PoolTag)

	return c.toNodeClaim(server, nodeClass.Spec.Zone, instanceType, nodeClaim.Labels, nodeClaim.Annotations), nil
}

// startClaimedServer powers on a claimed server and disambiguates
// StartServer failures (Codex Major #5, narrowed by the re-review): an
// error does NOT mean the start did not happen. The server is re-read; if
// it left `stopped` the start took effect and Create succeeds. If it is
// definitively still stopped, the claim is released and the error is
// classified: a per-server rejection (pool.ErrNotStartable — wrong state,
// locked, out of stock) propagates as-is so the caller can progress to the
// next candidate; anything else (auth, API, config) is a plain retryable
// error that must never become a capacity signal. If the re-read itself
// fails, the claim is kept as started (fail closed against a double
// power-on) and the core retries Create, which resumes the claim.
func (c *CloudProvider) startClaimedServer(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass, claimed claimedServer) error {
	server := claimed.server
	if claimed.started {
		// Resumed claim whose StartServer already succeeded (or whose
		// outcome was ambiguous): never issue a second power-on, even if
		// Scaleway still reports the server as stopped — a stale read must
		// not undo the "claim kept" safety (re-review Major).
		return nil
	}
	if server.Status.Class() != pool.ClassStartable {
		// The server left `stopped` without us starting it (e.g. a pending
		// claim raced an out-of-band power-on): treat as started.
		c.markClaimStarted(server.ID)
		return nil
	}
	startErr := c.backend.StartServer(ctx, nodeClass.Spec.Zone, server.ID)
	if startErr == nil {
		c.markClaimStarted(server.ID)
		return nil
	}
	reread, rerr := c.backend.GetServer(ctx, nodeClass.Spec.Zone, server.ID)
	if rerr != nil {
		c.markClaimStarted(server.ID)
		return fmt.Errorf("starting server %q (outcome ambiguous, claim kept), %w", server.ID, startErr)
	}
	if reread.Status.Class() != pool.ClassStartable {
		// The start took effect despite the error.
		c.markClaimStarted(server.ID)
		return nil
	}
	// Definitively still stopped: the start was refused. Release the claim
	// and classify the cause.
	c.unclaim(server.ID)
	if stderrors.Is(startErr, pool.ErrNotStartable) {
		// Per-server rejection: the caller quarantines this server and
		// tries the next candidate; ICE only comes from claimStoppedServer
		// once no startable candidate remains.
		return fmt.Errorf("server %q rejected power-on, %w", server.ID, startErr)
	}
	// Unknown cause (auth/API/config): retryable, never a capacity outcome.
	return fmt.Errorf("starting server %q, %w", server.ID, startErr)
}

// Delete powers off the server behind the NodeClaim, respecting the
// karpenter-core contract: nil while termination (or any provider-side
// operation) is in progress — the core keeps retrying — and
// NodeClaimNotFoundError only once the server is `stopped` or truly absent.
// Blocked/failed statuses return an explicit error (fail closed): the
// finalizer stays until an operator intervenes.
func (c *CloudProvider) Delete(ctx context.Context, nodeClaim *karpv1.NodeClaim) error {
	if nodeClaim.Status.ProviderID == "" {
		c.unclaimOwner(nodeClaim.UID)
		return cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("nodeclaim %q has no provider ID, nothing was launched", nodeClaim.Name))
	}
	server, zone, err := c.serverFromProviderID(ctx, nodeClaim.Status.ProviderID)
	if err != nil {
		if cloudprovider.IsNodeClaimNotFoundError(err) {
			// The core is about to drop the finalizer: this NodeClaim's
			// claims must not outlive it (re-review Critical).
			c.unclaimOwner(nodeClaim.UID)
		}
		return err
	}
	switch server.Status.Class() {
	case pool.ClassStartable:
		// Deliberately powered off: the instance is terminated. Release the
		// finalized owner's claims — a started claim surviving its deleted
		// NodeClaim while Scaleway still reports `stopped` would hide that
		// capacity from every future Create until a controller restart
		// (re-review Critical). Claims held by OTHER live NodeClaims on
		// this server are preserved.
		c.unclaimOwner(nodeClaim.UID)
		return cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("server %q is %s", server.ID, server.Status))
	case pool.ClassLive:
		if err := c.backend.StopServer(ctx, zone, server.ID); err != nil {
			return fmt.Errorf("stopping server %q, %w", server.ID, err)
		}
		c.unclaim(server.ID)
		c.unclaimOwner(nodeClaim.UID)
		c.invalidateInventoryFor(ctx, zone, server)
		return nil
	case pool.ClassTerminating, pool.ClassTransient:
		// Power-off (or another provider-side operation) in progress: not
		// terminated yet. The core retries Delete until `stopped`.
		return nil
	default: // ClassBlocked, ClassFailed
		return fmt.Errorf("server %q is %s (%s): cannot power off, manual intervention required", server.ID, server.Status, server.Status.Class())
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
// error) also keeps the legit maintenance flow converging: de-tagging a
// server releases its NodeClaim finalizer without touching the hardware.
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

// GetInstanceTypes exposes one static instance type per NodePool, derived
// from the pool's offer. The type is always returned (a type used by a live
// NodeClaim must never disappear); only Offering.Available flips when the
// pool runs out of stopped servers.
func (c *CloudProvider) GetInstanceTypes(ctx context.Context, nodePool *karpv1.NodePool) ([]*cloudprovider.InstanceType, error) {
	nodeClass, err := c.resolveNodeClassFromNodePool(ctx, nodePool)
	if err != nil {
		return nil, err
	}
	servers, err := c.inventory.Snapshot(ctx, nodeClass.Spec.Zone, nodeClass.Spec.PoolTag)
	if err != nil {
		return nil, fmt.Errorf("snapshotting pool for node class %q, %w", nodeClass.Name, err)
	}
	it, err := c.buildInstanceType(ctx, nodeClass, servers, true)
	if err != nil {
		return nil, fmt.Errorf("resolving instance type for node class %q, %w", nodeClass.Name, err)
	}
	return []*cloudprovider.InstanceType{it}, nil
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

// claimedServer is a pool server bound to a NodeClaim by the claim guard,
// together with the claim's started state — startClaimedServer must know
// whether a resumed claim already issued its power-on, because a stale
// `stopped` server snapshot cannot tell.
type claimedServer struct {
	server  pool.Server
	started bool
}

// claimStoppedServer picks a server for the NodeClaim, in this order:
//  1. resume — a claim already owned by this NodeClaim (UID) is returned
//     as-is, whatever the server status: a retried Create must converge on
//     the same server (and the same providerID), never consume a second one;
//  2. otherwise the lowest-ID stopped server without an active claim, and
//     not excluded by the caller (servers that rejected power-on earlier in
//     the same Create call).
//
// A claim is active while its StartServer succeeded (started, no wall-clock
// expiry — Codex Critical #1) or, for never-started claims, within
// pendingClaimTTL. Claims are released when the server is observed
// non-stopped or gone from the pool listing. The residual race on the last
// server surfaces as an InsufficientCapacityError (LLD C2).
func (c *CloudProvider) claimStoppedServer(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass, nodeClaim *karpv1.NodeClaim, excluded map[string]struct{}) (claimedServer, error) {
	// Fresh list on purpose: the inventory cache could hand the same
	// stopped server to two consecutive Create calls.
	servers, err := c.backend.ListServers(ctx, nodeClass.Spec.Zone, nodeClass.Spec.PoolTag)
	if err != nil {
		return claimedServer{}, fmt.Errorf("listing pool servers, %w", err)
	}
	sort.Slice(servers, func(i, j int) bool { return servers[i].ID < servers[j].ID })

	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.clock.Now()

	// Resume this NodeClaim's own claim if it holds one.
	for _, server := range servers {
		if cl, ok := c.claims[server.ID]; ok && cl.owner == nodeClaim.UID {
			cl.at = now
			c.claims[server.ID] = cl
			return claimedServer{server: server, started: cl.started}, nil
		}
	}

	// Purge claims for servers that left the pool listing (de-tagged or
	// deleted): they cannot be picked anymore, keeping them would leak.
	listed := make(map[string]struct{}, len(servers))
	for _, server := range servers {
		listed[server.ID] = struct{}{}
	}
	for id := range c.claims {
		if _, ok := listed[id]; !ok {
			delete(c.claims, id)
		}
	}

	for _, server := range servers {
		if server.Status.Class() != pool.ClassStartable {
			// Transition observed: the claim fulfilled its purpose.
			delete(c.claims, server.ID)
			continue
		}
		if _, ok := excluded[server.ID]; ok {
			continue
		}
		if cl, ok := c.claims[server.ID]; ok {
			if cl.started || now.Sub(cl.at) < pendingClaimTTL {
				continue
			}
			// Pending claim whose StartServer never got acknowledged and
			// whose TTL expired: reclaimable.
		}
		c.claims[server.ID] = serverClaim{owner: nodeClaim.UID, ownerName: nodeClaim.Name, at: now}
		return claimedServer{server: server}, nil
	}
	return claimedServer{}, cloudprovider.NewInsufficientCapacityError(
		fmt.Errorf("no stopped server left in pool %q (zone %s)", nodeClass.Spec.PoolTag, nodeClass.Spec.Zone))
}

func (c *CloudProvider) markClaimStarted(serverID string) {
	c.mu.Lock()
	if cl, ok := c.claims[serverID]; ok {
		cl.started = true
		c.claims[serverID] = cl
	}
	c.mu.Unlock()
}

func (c *CloudProvider) unclaim(serverID string) {
	c.mu.Lock()
	delete(c.claims, serverID)
	c.mu.Unlock()
}

// unclaimOwner releases every claim held by a NodeClaim whose finalizer is
// being dropped. Karpenter never reuses a NodeClaim: once Delete has
// answered NodeClaimNotFound, no retry of that NodeClaim's Create can come,
// so its claims are dead weight that would strand stopped capacity forever.
func (c *CloudProvider) unclaimOwner(owner types.UID) {
	c.mu.Lock()
	for id, cl := range c.claims {
		if cl.owner == owner {
			delete(c.claims, id)
		}
	}
	c.mu.Unlock()
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
