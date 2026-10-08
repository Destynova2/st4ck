package cloudprovider

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/awslabs/operatorpkg/status"
	"github.com/google/uuid"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/vm"
	yamlstream "go.yaml.in/yaml/v3"
	coordinationv1 "k8s.io/api/coordination/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
	"sigs.k8s.io/karpenter/pkg/scheduling"
	"sigs.k8s.io/karpenter/pkg/utils/resources"
)

type VM struct {
	Client                 client.Client
	Backend                vm.Backend
	Store                  reservation.Store
	ClusterID, ClusterName string
}

var _ core.CloudProvider = (*VM)(nil)

func (c *VM) Name() string { return "scaleway-vm" }
func (c *VM) GetSupportedNodeClasses() []status.Object {
	return []status.Object{&v1alpha1.ScalewayVMNodeClass{}}
}
func (c *VM) RepairPolicies() []core.RepairPolicy                                    { return nil }
func (c *VM) IsDrifted(context.Context, *karpv1.NodeClaim) (core.DriftReason, error) { return "", nil }
func (c *VM) clusterTag() string                                                     { return "st4ck-cluster=" + c.ClusterID }
func claimTag(uid types.UID) string                                                  { return "st4ck-claim=" + string(uid) }
func vmKey(uid types.UID) string                                                     { return "vm-claim/" + string(uid) }

func (c *VM) nodeClass(ctx context.Context, ref *karpv1.NodeClassReference) (*v1alpha1.ScalewayVMNodeClass, error) {
	if ref == nil || ref.Group != v1alpha1.Group || ref.Kind != "ScalewayVMNodeClass" {
		return nil, fmt.Errorf("invalid VM node class reference")
	}
	nc := &v1alpha1.ScalewayVMNodeClass{}
	err := c.Client.Get(ctx, types.NamespacedName{Name: ref.Name}, nc)
	return nc, err
}

func (c *VM) Validate(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass) error {
	if c.ClusterID == "" || c.ClusterName == "" {
		return fmt.Errorf("cluster ID and Talos cluster name are required")
	}
	for _, id := range []string{nc.Spec.ProjectID, nc.Spec.ImageID, nc.Spec.PrivateNetworkID, nc.Spec.SecurityGroupID} {
		if _, err := uuid.Parse(id); err != nil {
			return fmt.Errorf("project, image, network and security group must be UUIDs")
		}
	}
	if nc.Spec.Zone == "" || len(nc.Spec.InstanceTypes) == 0 || nc.Spec.EphemeralDiskGiB < 10 {
		return fmt.Errorf("zone, instance allowlist and local disk >=10 GiB required")
	}
	if nc.Spec.Architecture != "amd64" && nc.Spec.Architecture != "arm64" {
		return fmt.Errorf("unsupported architecture")
	}
	if _, err := c.bootstrap(ctx, nc, "scaleway://validation/validation"); err != nil {
		return err
	}
	return c.Backend.Validate(ctx, nc)
}

func (c *VM) bootstrap(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass, id string) ([]byte, error) {
	s := &corev1.Secret{}
	if nc.Spec.BootstrapSecret == "" {
		return nil, fmt.Errorf("bootstrap Secret is required")
	}
	if err := c.Client.Get(ctx, types.NamespacedName{Namespace: c.Store.Namespace, Name: nc.Spec.BootstrapSecret}, s); err != nil {
		return nil, err
	}
	decoder := yamlstream.NewDecoder(bytes.NewReader(s.Data["machineconfig"]))
	var documents []map[string]any
	for {
		var document map[string]any
		err := decoder.Decode(&document)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("invalid Talos config")
		}
		if document != nil {
			documents = append(documents, document)
		}
	}
	if len(documents) == 0 {
		return nil, fmt.Errorf("empty Talos config")
	}
	config := documents[0]
	machine, ok := config["machine"].(map[string]any)
	if !ok || machine["type"] != "worker" {
		return nil, fmt.Errorf("bootstrap must be a Talos worker config")
	}
	cluster, ok := config["cluster"].(map[string]any)
	if !ok || cluster["clusterName"] != c.ClusterName {
		return nil, fmt.Errorf("bootstrap belongs to a different Talos cluster")
	}
	kubelet, ok := machine["kubelet"].(map[string]any)
	if !ok {
		kubelet = map[string]any{}
		machine["kubelet"] = kubelet
	}
	args, ok := kubelet["extraArgs"].(map[string]any)
	if !ok {
		args = map[string]any{}
		kubelet["extraArgs"] = args
	}
	args["provider-id"] = id
	for _, flag := range []string{"kube-reserved", "system-reserved", "reserved-cpus", "max-pods", "pods-per-core", "eviction-hard", "eviction-soft", "eviction-soft-grace-period", "eviction-minimum-reclaim", "merge-default-eviction-settings", "register-with-taints", "config", "config-dir"} {
		if _, exists := args[flag]; exists {
			return nil, fmt.Errorf("VM kubelet extraArgs.%s bypasses provider resource accounting", flag)
		}
	}
	extra, ok := kubelet["extraConfig"].(map[string]any)
	if !ok {
		extra = map[string]any{}
		kubelet["extraConfig"] = extra
	}
	if configured, exists := extra["maxPods"]; exists && configured != defaultPodsPerNode {
		return nil, fmt.Errorf("VM maxPods must match provider capacity: %d", defaultPodsPerNode)
	}
	if configured, exists := extra["podsPerCore"]; exists && configured != 0 {
		return nil, fmt.Errorf("VM podsPerCore must be zero to preserve provider pod capacity")
	}
	if configured, exists := extra["systemReserved"]; exists {
		reserved, ok := configured.(map[string]any)
		if !ok || len(reserved) != 0 {
			return nil, fmt.Errorf("VM systemReserved is not modelled by provider resource accounting")
		}
	}
	if configured, exists := extra["reservedSystemCPUs"]; exists && configured != "" {
		return nil, fmt.Errorf("VM reservedSystemCPUs is not modelled by provider resource accounting")
	}
	extra["maxPods"] = defaultPodsPerNode
	// Keep advertised allocatable aligned with the kubelet configuration.
	reserve := map[string]any{"cpu": "500m", "memory": "1Gi"}
	if configured, exists := extra["kubeReserved"]; exists {
		r, ok := configured.(map[string]any)
		if !ok || len(r) != 2 || r["cpu"] != "500m" || r["memory"] != "1Gi" {
			return nil, fmt.Errorf("VM kubeReserved must match provider reserve: cpu=500m, memory=1Gi")
		}
	}
	extra["kubeReserved"] = reserve
	if err := configureBootstrapSafety(extra); err != nil {
		return nil, err
	}
	var output bytes.Buffer
	encoder := yamlstream.NewEncoder(&output)
	for _, document := range documents {
		if err := encoder.Encode(document); err != nil {
			return nil, err
		}
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func (c *VM) GetInstanceTypes(ctx context.Context, np *karpv1.NodePool) ([]*core.InstanceType, error) {
	nc, err := c.nodeClass(ctx, np.Spec.Template.Spec.NodeClassRef)
	if err != nil {
		return nil, err
	}
	if err = c.Validate(ctx, nc); err != nil {
		return nil, core.NewNodeClassNotReadyError(err)
	}
	return c.instanceTypes(ctx, nc)
}

func (c *VM) instanceTypes(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass) ([]*core.InstanceType, error) {
	shapes, err := c.Backend.Shapes(ctx, nc.Spec.Zone)
	if err != nil {
		return nil, err
	}
	var result []*core.InstanceType
	for _, s := range shapes {
		if !slices.Contains(nc.Spec.InstanceTypes, s.Name) || s.Architecture != nc.Spec.Architecture || s.Price <= 0 {
			continue
		}
		result = append(result, vmInstanceType(s, nc.Spec.Zone))
	}
	slices.SortFunc(result, func(a, b *core.InstanceType) int {
		if a.Offerings[0].Price < b.Offerings[0].Price {
			return -1
		}
		if a.Offerings[0].Price > b.Offerings[0].Price {
			return 1
		}
		return strings.Compare(a.Name, b.Name)
	})
	return result, nil
}

func vmInstanceType(s vm.Shape, zone string) *core.InstanceType {
	it := newInstanceType(pool.Offer{Name: s.Name, Architecture: s.Architecture, CPUThreads: s.CPU, MemoryBytes: s.Memory, PricePerHour: s.Price}, zone, s.Available)
	it.Requirements[corev1.LabelArchStable] = scheduling.NewRequirement(corev1.LabelArchStable, corev1.NodeSelectorOpIn, s.Architecture)
	return it
}

func (c *VM) Create(ctx context.Context, claim *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	nc, err := c.nodeClass(ctx, claim.Spec.NodeClassRef)
	if err != nil {
		return nil, core.NewNodeClassNotReadyError(err)
	}
	if err = c.Validate(ctx, nc); err != nil {
		return nil, core.NewNodeClassNotReadyError(err)
	}
	typesList, err := c.instanceTypes(ctx, nc)
	if err != nil {
		return nil, err
	}
	reqs := scheduling.NewNodeSelectorRequirementsWithMinValues(claim.Spec.Requirements...)
	var chosen *core.InstanceType
	for _, it := range typesList {
		if it.Offerings[0].Available && reqs.IsCompatible(it.Requirements, scheduling.AllowUndefinedWellKnownLabels) && resources.Fits(claim.Spec.Resources.Requests, it.Allocatable()) {
			chosen = it
			break
		}
	}
	// Even without currently free stock, retry an existing creation intent.
	l, err := c.Store.Get(ctx, vmKey(claim.UID))
	if apierrors.IsNotFound(err) {
		if chosen == nil {
			return nil, core.NewInsufficientCapacityError(fmt.Errorf("no allowed VM fits requests and requirements"))
		}
		l, _, err = c.Store.Acquire(ctx, vmKey(claim.UID), claim.UID, map[string]string{"zone": nc.Spec.Zone, "project": nc.Spec.ProjectID, "type": chosen.Name, "node-class": nc.Name})
	}
	if err != nil {
		return nil, err
	}
	if reservation.Owner(l) != string(claim.UID) {
		return nil, fmt.Errorf("VM intent owner mismatch")
	}
	if l.Annotations[reservation.Prefix+"zone"] != nc.Spec.Zone || l.Annotations[reservation.Prefix+"project"] != nc.Spec.ProjectID {
		return nil, fmt.Errorf("VM node class changed during provisioning")
	}
	phase := l.Annotations[reservation.Prefix+"phase"]
	if phase == "deleting" {
		return nil, fmt.Errorf("VM is terminating")
	}
	servers, err := c.Backend.List(ctx, nc.Spec.Zone, nc.Spec.ProjectID, []string{c.clusterTag(), claimTag(claim.UID)})
	if err != nil {
		return nil, err
	}
	if len(servers) > 1 {
		return nil, fmt.Errorf("multiple VMs share a claim UID; refusing automatic recovery")
	}
	var server vm.Server
	if len(servers) == 1 {
		server = servers[0]
	} else {
		if phase != "" {
			return nil, fmt.Errorf("VM create outcome unknown; reservation retained, no duplicate POST")
		}
		if err = c.Store.Set(ctx, l, "phase", "creating"); err != nil {
			return nil, err
		}
		server, err = c.Backend.Create(ctx, nc, "karpenter-"+string(claim.UID), l.Annotations[reservation.Prefix+"type"], []string{c.clusterTag(), claimTag(claim.UID)})
		if err != nil {
			return nil, err
		}
	}
	if !c.owns(server, l) {
		return nil, fmt.Errorf("VM ownership mismatch")
	}
	if l.Annotations[reservation.Prefix+"server"] != server.ID {
		if err = c.Store.Set(ctx, l, "server", server.ID); err != nil {
			return nil, err
		}
	}
	if phase != "starting" && phase != "running" {
		if server.State != "stopped" {
			return nil, fmt.Errorf("unconfigured VM must be stopped")
		}
		config, e := c.bootstrap(ctx, nc, vm.ProviderID(server.Zone, server.ID))
		if e != nil {
			return nil, e
		}
		if err = c.Backend.Configure(ctx, nc, server, config); err != nil {
			return nil, err
		}
		if err = c.Store.Set(ctx, l, "phase", "starting"); err != nil {
			return nil, err
		}
		if err = c.Backend.Start(ctx, server); err != nil {
			return nil, err
		}
	}
	return c.hydrate(ctx, server, claim.Labels, claim.Annotations)
}

func (c *VM) owns(s vm.Server, l *coordinationv1.Lease) bool {
	return s.Project == l.Annotations[reservation.Prefix+"project"] && s.Zone == l.Annotations[reservation.Prefix+"zone"] && slices.Contains(s.Tags, c.clusterTag()) && slices.Contains(s.Tags, claimTag(types.UID(reservation.Owner(l))))
}

func (c *VM) hydrate(ctx context.Context, s vm.Server, labels, annotations map[string]string) (*karpv1.NodeClaim, error) {
	r := &karpv1.NodeClaim{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{}, Annotations: map[string]string{}}, Status: karpv1.NodeClaimStatus{ProviderID: vm.ProviderID(s.Zone, s.ID)}}
	for k, v := range labels {
		r.Labels[k] = v
	}
	for k, v := range annotations {
		r.Annotations[k] = v
	}
	shapes, err := c.Backend.Shapes(ctx, s.Zone)
	if err != nil {
		return nil, err
	}
	for _, shape := range shapes {
		if shape.Name == s.Type {
			it := vmInstanceType(shape, s.Zone)
			r.Status.Capacity = it.Capacity
			r.Status.Allocatable = it.Allocatable()
			for key, req := range it.Requirements {
				if req.Len() == 1 {
					r.Labels[key] = req.Values()[0]
				}
			}
			return r, nil
		}
	}
	return nil, fmt.Errorf("VM shape %q no longer in catalog", s.Type)
}

func (c *VM) Delete(ctx context.Context, claim *karpv1.NodeClaim) error {
	l, err := c.Store.Get(ctx, vmKey(claim.UID))
	if apierrors.IsNotFound(err) {
		if claim.Status.ProviderID == "" {
			return core.NewNodeClaimNotFoundError(vm.ErrNotFound)
		}
		zone, id, e := vm.ParseProviderID(claim.Status.ProviderID)
		if e != nil {
			return e
		}
		_, e = c.Backend.Get(ctx, zone, id)
		if errors.Is(e, vm.ErrNotFound) {
			return core.NewNodeClaimNotFoundError(e)
		}
		return fmt.Errorf("no VM creation record; manual reconciliation required")
	}
	if err != nil {
		return err
	}
	if reservation.Owner(l) != string(claim.UID) {
		return fmt.Errorf("refusing to delete another NodeClaim's VM")
	}
	id := l.Annotations[reservation.Prefix+"server"]
	if claim.Status.ProviderID != "" {
		zone, claimed, e := vm.ParseProviderID(claim.Status.ProviderID)
		if e != nil {
			return e
		}
		if zone != l.Annotations[reservation.Prefix+"zone"] || id != claimed {
			return fmt.Errorf("provider ID differs from owned VM")
		}
	}
	if id == "" {
		servers, e := c.Backend.List(ctx, l.Annotations[reservation.Prefix+"zone"], l.Annotations[reservation.Prefix+"project"], []string{c.clusterTag(), claimTag(claim.UID)})
		if e != nil {
			return e
		}
		if len(servers) > 1 {
			return fmt.Errorf("ambiguous VM ownership")
		}
		if len(servers) == 1 {
			id = servers[0].ID
			if err = c.Store.Set(ctx, l, "server", id); err != nil {
				return err
			}
		} else {
			if l.Annotations[reservation.Prefix+"phase"] != "" {
				return fmt.Errorf("cannot finalize an ambiguous VM create")
			}
			if err = c.Store.Release(ctx, l, claim.UID); err != nil {
				return err
			}
			return core.NewNodeClaimNotFoundError(vm.ErrNotFound)
		}
	}
	server, err := c.Backend.Get(ctx, l.Annotations[reservation.Prefix+"zone"], id)
	if errors.Is(err, vm.ErrNotFound) {
		if err = c.Store.Release(ctx, l, claim.UID); err != nil {
			return err
		}
		return core.NewNodeClaimNotFoundError(vm.ErrNotFound)
	}
	if err != nil {
		return err
	}
	if !c.owns(server, l) {
		return fmt.Errorf("refusing to delete a foreign VM")
	}
	if err = c.Store.Set(ctx, l, "phase", "deleting"); err != nil {
		return err
	}
	return c.Backend.Delete(ctx, server)
}

func (c *VM) Get(ctx context.Context, id string) (*karpv1.NodeClaim, error) {
	zone, key, err := vm.ParseProviderID(id)
	if err != nil {
		return nil, err
	}
	s, err := c.Backend.Get(ctx, zone, key)
	if errors.Is(err, vm.ErrNotFound) {
		return nil, core.NewNodeClaimNotFoundError(err)
	}
	if err != nil {
		return nil, err
	}
	for _, tag := range s.Tags {
		if strings.HasPrefix(tag, "st4ck-claim=") {
			l, e := c.Store.Get(ctx, vmKey(types.UID(strings.TrimPrefix(tag, "st4ck-claim="))))
			if e != nil {
				return nil, e
			}
			if c.owns(s, l) && l.Annotations[reservation.Prefix+"server"] == s.ID {
				return c.hydrate(ctx, s, nil, nil)
			}
		}
	}
	return nil, fmt.Errorf("VM ownership could not be verified")
}

func (c *VM) List(ctx context.Context) ([]*karpv1.NodeClaim, error) {
	leases, err := c.Store.All(ctx)
	if err != nil {
		return nil, err
	}
	var result []*karpv1.NodeClaim
	for _, l := range leases {
		if !strings.HasPrefix(l.Annotations[reservation.Prefix+"resource"], "vm-claim/") {
			continue
		}
		servers, e := c.Backend.List(ctx, l.Annotations[reservation.Prefix+"zone"], l.Annotations[reservation.Prefix+"project"], []string{c.clusterTag(), claimTag(types.UID(reservation.Owner(&l)))})
		if e != nil {
			return nil, e
		}
		for _, s := range servers {
			if c.owns(s, &l) {
				result = append(result, &karpv1.NodeClaim{Status: karpv1.NodeClaimStatus{ProviderID: vm.ProviderID(s.Zone, s.ID)}})
			}
		}
	}
	return result, nil
}
