package main

import (
	"os"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"sigs.k8s.io/karpenter/pkg/cloudprovider/overlay"
	corecontrollers "sigs.k8s.io/karpenter/pkg/controllers"
	"sigs.k8s.io/karpenter/pkg/controllers/state"
	coreoperator "sigs.k8s.io/karpenter/pkg/operator"

	scalewaycloudprovider "github.com/st4ck/karpenter-provider-scaleway/pkg/cloudprovider"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/controllers/nodeclass"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/controllers/termination"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/vm"
)

// inventoryTTL keeps GetInstanceTypes' ListServers pressure within the LLD
// polling budget (≤ 1 req/10 s) while staying fresh enough for the
// Offering.Available flip.
const inventoryTTL = 10 * time.Second

func main() {
	ctx, op := coreoperator.NewOperator()

	backend, err := pool.NewScalewayBackend()
	if err != nil {
		log.FromContext(ctx).Error(err, "failed creating scaleway backend")
		os.Exit(1)
	}
	inventory := pool.NewInventory(backend, inventoryTTL)

	// Ownership and bootstrap Secrets require strongly consistent reads, not
	// the controller-runtime informer cache.
	direct, err := client.New(op.GetConfig(), client.Options{Scheme: op.GetScheme()})
	if err != nil {
		panic(err)
	}
	namespace := os.Getenv("POD_NAMESPACE")
	if namespace == "" || os.Getenv("CLUSTER_ID") == "" || os.Getenv("TALOS_CLUSTER_NAME") == "" {
		panic("POD_NAMESPACE, CLUSTER_ID and TALOS_CLUSTER_NAME are required")
	}
	store := reservation.Store{Client: direct, Namespace: namespace}
	vmBackend, err := vm.NewScaleway()
	if err != nil {
		panic(err)
	}
	vmProvider := &scalewaycloudprovider.VM{Client: direct, Backend: vmBackend, Store: store, ClusterID: os.Getenv("CLUSTER_ID"), ClusterName: os.Getenv("TALOS_CLUSTER_NAME")}
	hybrid := &scalewaycloudprovider.Hybrid{
		Metal: scalewaycloudprovider.New(direct, backend, inventory, namespace), VM: vmProvider,
	}
	undecoratedCloudProvider := &scalewaycloudprovider.Protected{CloudProvider: hybrid, Client: direct}
	cloudProvider := overlay.Decorate(undecoratedCloudProvider, op.GetClient(), op.InstanceTypeStore)
	clusterState := state.NewCluster(op.Clock, op.GetClient(), cloudProvider)

	op.
		WithControllers(ctx, corecontrollers.NewControllers(
			ctx,
			op.Manager,
			op.Clock,
			op.GetClient(),
			op.EventRecorder,
			cloudProvider,
			undecoratedCloudProvider,
			clusterState,
			op.InstanceTypeStore,
		)...).
		WithControllers(ctx, nodeclass.NewController(op.GetClient(), backend)).
		WithControllers(ctx, &nodeclass.VMController{Client: op.GetClient(), Provider: vmProvider}).
		WithControllers(ctx, &termination.Controller{Provider: undecoratedCloudProvider}).
		Start(ctx)
}
