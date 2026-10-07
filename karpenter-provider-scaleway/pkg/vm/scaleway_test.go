package vm

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	instance "github.com/scaleway/scaleway-sdk-go/api/instance/v1"
	"github.com/scaleway/scaleway-sdk-go/scw"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
)

func TestSDKVMRequestsUsePrivateNetworkingAndTalosUserData(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	var create map[string]any
	var userData string
	var actions []string
	volumeType := "l_ssd"
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		path := r.URL.Path
		switch {
		case strings.Contains(path, "/images/"):
			json.NewEncoder(w).Encode(map[string]any{"image": map[string]any{"id": id, "project": id, "arch": "x86_64", "state": "available", "root_volume": map[string]any{"id": id, "size": 10 << 30, "volume_type": "l_ssd"}}})
		case strings.HasSuffix(path, "/servers") && r.Method == http.MethodPost:
			if err := json.NewDecoder(r.Body).Decode(&create); err != nil {
				t.Error(err)
			}
			json.NewEncoder(w).Encode(map[string]any{"server": map[string]any{"id": id, "zone": "fr-par-2", "project": id, "state": "stopped", "commercial_type": "small"}})
		case strings.Contains(path, "/user_data/"):
			if !strings.HasSuffix(path, "/cloud-init") {
				t.Error("wrong Talos user-data key")
			}
			data, _ := io.ReadAll(r.Body)
			userData = string(data)
			w.WriteHeader(http.StatusNoContent)
		case strings.HasSuffix(path, "/action"):
			var action map[string]string
			json.NewDecoder(r.Body).Decode(&action)
			actions = append(actions, action["action"])
			io.WriteString(w, `{"task":{"id":"test"}}`)
		case strings.HasSuffix(path, "/servers/"+id):
			json.NewEncoder(w).Encode(map[string]any{"server": map[string]any{"id": id, "zone": "fr-par-2", "project": id, "state": "stopped", "private_nics": []any{map[string]any{"private_network_id": id}}, "volumes": map[string]any{"0": map[string]any{"id": id, "volume_type": volumeType}}}})
		default:
			t.Errorf("unexpected request %s %s", r.Method, path)
			http.Error(w, "unexpected", 500)
		}
	}))
	defer api.Close()
	c, err := scw.NewClient(scw.WithAPIURL(api.URL), scw.WithAuth("SCWXXXXXXXXXXXXXXXXX", id))
	if err != nil {
		t.Fatal(err)
	}
	b := &Scaleway{api: instance.NewAPI(c)}
	nc := &v1alpha1.ScalewayVMNodeClass{Spec: v1alpha1.ScalewayVMNodeClassSpec{Zone: "fr-par-2", ProjectID: id, ImageID: id, PrivateNetworkID: id, SecurityGroupID: id, Architecture: "amd64", EphemeralDiskGiB: 20}}
	s, err := b.Create(context.Background(), nc, "node", "small", []string{"owner=test"})
	if err != nil {
		t.Fatal(err)
	}
	if create["dynamic_ip_required"] != false || create["security_group"] != id || create["image"] != id {
		t.Fatalf("unsafe create request: %v", create)
	}
	volumes := create["volumes"].(map[string]any)
	if volumes["0"].(map[string]any)["size"] != float64(10<<30) || volumes["1"].(map[string]any)["size"] != float64(20<<30) {
		t.Fatal("incorrect root/EPHEMERAL sizing")
	}
	if err = b.Configure(context.Background(), nc, s, []byte("test-worker-config")); err != nil {
		t.Fatal(err)
	}
	if userData != "test-worker-config" {
		t.Fatal("missing user-data")
	}
	if err = b.Delete(context.Background(), s); err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 || actions[0] != "terminate" {
		t.Fatal("local instance not terminated")
	}
	volumeType = "sbs_volume"
	if err = b.Delete(context.Background(), s); err == nil || len(actions) != 1 {
		t.Fatal("remote disk deletion was not blocked")
	}
}
