// kwok e2e harness controller (level 5 of docs/how-to/test-local.md):
// karpenter-core v1.14 wired with the Scaleway EM CloudProvider on a seeded
// in-memory FakeBackend, run against a kwok cluster. Two harness-only
// additions to the production wiring of cmd/controller:
//
//   - a node simulator playing the Talos kubelet: when a NodeClaim carries a
//     scaleway-em:// provider ID, it creates the corresponding kwok-managed
//     Node with spec.providerID set to the exact same bytes (LLD C3) and the
//     karpenter.sh/unregistered taint, like the pre-imaged machineconfig
//     would (modules/em-talos-bootstrap step 5);
//   - a debug HTTP endpoint exposing the FakeBackend pool state so run.sh
//     can assert power transitions (ready after Create, stopped after
//     Delete) from outside the process.
//
// Never deployed; compiled and launched by hack/kwok-e2e/run.sh.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	controllerruntime "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider/overlay"
	corecontrollers "sigs.k8s.io/karpenter/pkg/controllers"
	"sigs.k8s.io/karpenter/pkg/controllers/state"
	coreoperator "sigs.k8s.io/karpenter/pkg/operator"

	scalewaycloudprovider "github.com/st4ck/karpenter-provider-scaleway/pkg/cloudprovider"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/controllers/nodeclass"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

// inventoryTTL is shorter than production (10 s): the e2e asserts the
// Offering.Available flip within seconds.
const inventoryTTL = 2 * time.Second

func main() {
	zone := envOr("E2E_ZONE", "fr-par-2")
	poolTag := envOr("E2E_POOL_TAG", "st4ck.io/karpenter-pool=metal")
	offerName := envOr("E2E_OFFER", "EM-A116X-SSD")
	debugAddr := envOr("E2E_DEBUG_ADDR", "127.0.0.1:8085")
	serverCount, err := strconv.Atoi(envOr("E2E_SERVERS", "3"))
	if err != nil || serverCount < 1 {
		fmt.Fprintln(os.Stderr, "E2E_SERVERS must be a positive integer")
		os.Exit(1)
	}

	backend := pool.NewFakeBackend()
	backend.AddOffer(pool.Offer{
		ID:           "offer-sim",
		Name:         offerName,
		CPUThreads:   32,
		MemoryBytes:  128 << 30,
		PricePerHour: 1.25,
	})
	for i := range serverCount {
		backend.AddServer(pool.Server{
			ID:        fmt.Sprintf("e2e00000-0000-4000-8000-%012d", i),
			Name:      fmt.Sprintf("em-sim-%d", i),
			Zone:      zone,
			Status:    pool.StatusStopped,
			OfferName: offerName,
			Tags:      []string{poolTag, "st4ck.io/karpenter-managed=true"},
		})
	}

	ctx, op := coreoperator.NewOperator()
	inventory := pool.NewInventory(backend, inventoryTTL)
	undecoratedCloudProvider := scalewaycloudprovider.New(op.GetClient(), backend, inventory)
	cloudProvider := overlay.Decorate(undecoratedCloudProvider, op.GetClient(), op.InstanceTypeStore)
	clusterState := state.NewCluster(op.Clock, op.GetClient(), cloudProvider)

	// Direct (uncached) client for the simulator and debug endpoint: they
	// live outside the manager lifecycle.
	simClient, err := client.New(controllerruntime.GetConfigOrDie(), client.Options{Scheme: scheme.Scheme})
	if err != nil {
		log.FromContext(ctx).Error(err, "failed building simulator client")
		os.Exit(1)
	}
	go runNodeSimulator(ctx, simClient)
	go serveDebug(ctx, backend, zone, poolTag, debugAddr)

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

// runNodeSimulator plays the pre-imaged Talos kubelet: for every launched
// NodeClaim with a scaleway-em:// provider ID it creates the matching
// kwok-managed Node (byte-identical spec.providerID + unregistered taint).
// kwok's controller then takes over the node lifecycle (Ready, heartbeats);
// node deletion is karpenter-core's job during termination.
func runNodeSimulator(ctx context.Context, kubeClient client.Client) {
	logger := log.FromContext(ctx).WithName("node-simulator")
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		nodeClaims := &karpv1.NodeClaimList{}
		if err := kubeClient.List(ctx, nodeClaims); err != nil {
			logger.V(1).Info("listing nodeclaims failed", "error", err)
			continue
		}
		nodes := &corev1.NodeList{}
		if err := kubeClient.List(ctx, nodes); err != nil {
			logger.V(1).Info("listing nodes failed", "error", err)
			continue
		}
		joined := map[string]struct{}{}
		for i := range nodes.Items {
			joined[nodes.Items[i].Spec.ProviderID] = struct{}{}
		}
		for i := range nodeClaims.Items {
			nodeClaim := &nodeClaims.Items[i]
			providerID := nodeClaim.Status.ProviderID
			if providerID == "" || !strings.HasPrefix(providerID, pool.ProviderIDPrefix) {
				continue
			}
			if nodeClaim.DeletionTimestamp != nil {
				continue
			}
			if _, ok := joined[providerID]; ok {
				continue
			}
			node := simulatedNode(nodeClaim)
			if err := kubeClient.Create(ctx, node); err != nil {
				if !apierrors.IsAlreadyExists(err) {
					logger.Error(err, "failed creating simulated node", "node", node.Name)
				}
				continue
			}
			logger.Info("simulated kubelet join", "node", node.Name, "providerID", providerID)
		}
	}
}

func simulatedNode(nodeClaim *karpv1.NodeClaim) *corev1.Node {
	name := nodeClaim.Annotations[scalewaycloudprovider.AnnotationServerName]
	if name == "" {
		name = "sim-" + nodeClaim.Name
	}
	labels := map[string]string{}
	maps.Copy(labels, nodeClaim.Labels)
	labels[corev1.LabelHostname] = name
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   name,
			Labels: labels,
			// kwok only manages nodes carrying this annotation.
			Annotations: map[string]string{"kwok.x-k8s.io/node": "fake"},
		},
		Spec: corev1.NodeSpec{
			// The byte-identity contract under test (LLD C3): same string
			// the kubelet would register with on real hardware.
			ProviderID: nodeClaim.Status.ProviderID,
			// Real nodes get it via registerWithTaints; karpenter-core
			// refuses to register nodes launched without it.
			Taints: []corev1.Taint{karpv1.UnregisteredNoExecuteTaint},
		},
		Status: corev1.NodeStatus{
			Capacity:    nodeClaim.Status.Capacity,
			Allocatable: nodeClaim.Status.Allocatable,
			Phase:       corev1.NodePending,
		},
	}
}

// serveDebug exposes the fake pool state (GET /servers) so the harness
// script can assert power transitions without reaching into the process.
func serveDebug(ctx context.Context, backend *pool.FakeBackend, zone, tag, addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /servers", func(w http.ResponseWriter, r *http.Request) {
		servers, err := backend.ListServers(r.Context(), zone, tag)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(servers)
	})
	server := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.FromContext(ctx).Error(err, "debug endpoint failed", "addr", addr)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
