package cloudprovider

import (
	"context"
	"os"
	"reflect"
	"testing"

	yamlstream "go.yaml.in/yaml/v3"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
)

func TestVMBootstrapRejectsUnmodelledResourceSettings(t *testing.T) {
	for name, kubelet := range map[string]string{
		"max-pods-config":    "extraConfig: {maxPods: 20}",
		"pods-per-core":      "extraConfig: {podsPerCore: 1}",
		"system-reserved":    "extraConfig: {systemReserved: {memory: 2Gi}}",
		"reserved-cpus":      "extraConfig: {reservedSystemCPUs: '0-1'}",
		"max-pods-flag":      "extraArgs: {max-pods: '20'}",
		"pods-per-core-flag": "extraArgs: {pods-per-core: '1'}",
		"kube-reserved-flag": "extraArgs: {kube-reserved: 'cpu=2,memory=2Gi'}",
		"system-flag":        "extraArgs: {system-reserved: 'memory=2Gi'}",
		"cpus-flag":          "extraArgs: {reserved-cpus: '0-1'}",
		"eviction-hard":      "extraConfig: {evictionHard: {memory.available: 2Gi}}",
		"eviction-soft":      "extraConfig: {evictionSoft: {memory.available: 2Gi}}",
		"eviction-reclaim":   "extraConfig: {evictionMinimumReclaim: {memory.available: 2Gi}}",
		"eviction-merge":     "extraConfig: {mergeDefaultEvictionSettings: true}",
		"eviction-flag":      "extraArgs: {eviction-hard: 'memory.available<2Gi'}",
		"config-flag":        "extraArgs: {config: '/other-config'}",
		"taint-flag":         "extraArgs: {register-with-taints: 'other=foo:NoSchedule'}",
		"taint-conflict":     "extraConfig: {registerWithTaints: [{key: karpenter.sh/unregistered, effect: NoSchedule}]}",
		"taint-value":        "extraConfig: {registerWithTaints: [{key: karpenter.sh/unregistered, effect: NoExecute, value: unexpected}]}",
		"taint-malformed":    "extraConfig: {registerWithTaints: 'bad'}",
	} {
		t.Run(name, func(t *testing.T) {
			c, backend, claim := vmFixture(t)
			ctx := context.Background()
			secret := &corev1.Secret{}
			key := client.ObjectKey{Namespace: "autoscaling", Name: "worker"}
			if err := c.Client.Get(ctx, key, secret); err != nil {
				t.Fatal(err)
			}
			secret.Data["machineconfig"] = []byte("machine:\n  type: worker\n  kubelet:\n    " + kubelet + "\ncluster:\n  clusterName: test\n")
			if err := c.Client.Update(ctx, secret); err != nil {
				t.Fatal(err)
			}
			if _, err := c.Create(ctx, claim); err == nil || backend.creates != 0 {
				t.Fatalf("inconsistent resources reached VM creation: creates=%d, error=%v", backend.creates, err)
			}
			leases, err := c.Store.All(ctx)
			if err != nil || len(leases) != 0 {
				t.Fatalf("invalid bootstrap allocated a reservation: %v, %v", leases, err)
			}
		})
	}
}

func TestVMBootstrapPinsAdvertisedPodCapacity(t *testing.T) {
	c, backend, claim := vmFixture(t)
	created, err := c.Create(context.Background(), claim)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := yamlstream.Unmarshal(backend.config, &config); err != nil {
		t.Fatal(err)
	}
	extra := config["machine"].(map[string]any)["kubelet"].(map[string]any)["extraConfig"].(map[string]any)
	golden, err := os.ReadFile("testdata/bootstrap-extra.json")
	if err != nil {
		t.Fatal(err)
	}
	var expected map[string]any
	if err := yamlstream.Unmarshal(golden, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(extra, expected) {
		t.Fatalf("VM bootstrap differs from EM cross-contract fixture: %v", extra)
	}
	if extra["maxPods"] != int(created.Status.Capacity.Pods().Value()) {
		t.Fatalf("bootstrap maxPods=%v, advertised=%s", extra["maxPods"], created.Status.Capacity.Pods())
	}
	if extra["evictionHard"].(map[string]any)["memory.available"] != evictionMemory {
		t.Fatal("bootstrap eviction headroom differs from advertisement")
	}
	overhead := created.Status.Capacity.Memory().DeepCopy()
	overhead.Sub(*created.Status.Allocatable.Memory())
	if overhead.Cmp(resource.MustParse("1124Mi")) != 0 {
		t.Fatalf("memory overhead=%s, want 1Gi + 100Mi", overhead.String())
	}
	em := newInstanceType(pool.Offer{Name: "metal", CPUThreads: 8, MemoryBytes: 16 << 30}, "fr-par-2", true)
	emOverhead := em.Overhead.Total()
	if emOverhead.Memory().Cmp(overhead) != 0 {
		t.Fatal("EM and VM reserve different memory")
	}
}

func TestBootstrapSafetyPreservesTaintsAndIsIdempotent(t *testing.T) {
	extra := map[string]any{"registerWithTaints": []any{map[string]any{"key": "dedicated", "value": "elastic", "effect": "NoSchedule"}}}
	for range 2 {
		if err := configureBootstrapSafety(extra); err != nil {
			t.Fatal(err)
		}
	}
	taints := extra["registerWithTaints"].([]any)
	if len(taints) != 2 || taints[0].(map[string]any)["key"] != "dedicated" || taints[1].(map[string]any)["key"] != "karpenter.sh/unregistered" || taints[1].(map[string]any)["effect"] != "NoExecute" {
		t.Fatalf("initial taints corrupted: %v", taints)
	}
}

func TestVMDoesNotScheduleIntoEvictionHeadroom(t *testing.T) {
	c, backend, claim := vmFixture(t)
	backend.shapes = backend.shapes[:1]
	request := resource.NewQuantity(backend.shapes[0].Memory, resource.BinarySI)
	request.Sub(resource.MustParse("1Gi"))
	request.Sub(resource.MustParse("50Mi"))
	claim.Spec.Resources.Requests[corev1.ResourceMemory] = *request
	if _, err := c.Create(context.Background(), claim); !core.IsInsufficientCapacityError(err) || backend.creates != 0 {
		t.Fatalf("eviction headroom consumed: creates=%d, error=%v", backend.creates, err)
	}
	request.Sub(resource.MustParse("50Mi"))
	claim.Spec.Resources.Requests[corev1.ResourceMemory] = *request
	if _, err := c.Create(context.Background(), claim); err != nil || backend.creates != 1 {
		t.Fatalf("exact allocatable should fit: creates=%d, error=%v", backend.creates, err)
	}
}
