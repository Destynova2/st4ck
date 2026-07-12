package main

import (
	"os"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/log"

	"sigs.k8s.io/karpenter/pkg/cloudprovider/overlay"
	corecontrollers "sigs.k8s.io/karpenter/pkg/controllers"
	"sigs.k8s.io/karpenter/pkg/controllers/state"
	coreoperator "sigs.k8s.io/karpenter/pkg/operator"

	scalewaycloudprovider "github.com/st4ck/karpenter-provider-scaleway/pkg/cloudprovider"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/controllers/nodeclass"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
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

	undecoratedCloudProvider := scalewaycloudprovider.New(op.GetClient(), backend, inventory)
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
		Start(ctx)
}
