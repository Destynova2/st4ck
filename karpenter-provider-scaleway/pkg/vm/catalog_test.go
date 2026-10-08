package vm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	instance "github.com/scaleway/scaleway-sdk-go/api/instance/v1"
	"github.com/scaleway/scaleway-sdk-go/scw"
)

func TestRetiredShapeRemainsVisibleButUnavailable(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/availability") {
			json.NewEncoder(w).Encode(map[string]any{"servers": map[string]any{"retired": map[string]any{"availability": "available"}}, "total_count": 1})
			return
		}
		if strings.HasSuffix(r.URL.Path, "/products/servers") {
			json.NewEncoder(w).Encode(map[string]any{"servers": map[string]any{"retired": map[string]any{
				"arch": "x86_64", "ncpus": 4, "ram": 8 << 30, "hourly_price": 0.2, "end_of_service": true,
			}}, "total_count": 1})
			return
		}
		t.Errorf("unexpected catalog request: %s", r.URL.Path)
		http.Error(w, "unexpected", http.StatusBadRequest)
	}))
	defer api.Close()
	c, err := scw.NewClient(scw.WithAPIURL(api.URL), scw.WithAuth("SCWXXXXXXXXXXXXXXXXX", "11111111-1111-4111-8111-111111111111"))
	if err != nil {
		t.Fatal(err)
	}
	backend := &Scaleway{api: instance.NewAPI(c)}
	shapes, err := backend.Shapes(context.Background(), "fr-par-2")
	if err != nil {
		t.Fatal(err)
	}
	if len(shapes) != 1 || shapes[0].Name != "retired" || shapes[0].Available {
		t.Fatalf("live NodeClaims need retired shape metadata without new capacity: %+v", shapes)
	}
}
