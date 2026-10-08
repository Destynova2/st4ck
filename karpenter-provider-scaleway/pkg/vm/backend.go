package vm

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
)

var ErrNotFound = errors.New("VM not found")

type Shape struct {
	Name, Architecture string
	CPU, Memory        int64
	Price              float64
	Available          bool
}

type Server struct {
	ID, Zone, Project, Type, State string
	Tags                           []string
}

type Backend interface {
	Validate(context.Context, *v1alpha1.ScalewayVMNodeClass) error
	Shapes(context.Context, string) ([]Shape, error)
	List(context.Context, string, string, []string) ([]Server, error)
	Get(context.Context, string, string) (Server, error)
	Create(context.Context, *v1alpha1.ScalewayVMNodeClass, string, string, []string) (Server, error)
	Configure(context.Context, *v1alpha1.ScalewayVMNodeClass, Server, []byte) error
	Start(context.Context, Server) error
	// Delete terminates only this instance and its local disks, never arbitrary SBS volumes.
	Delete(context.Context, Server) error
}

func ProviderID(zone, id string) string { return "scaleway://" + zone + "/" + id }
func ParseProviderID(value string) (string, string, error) {
	if !strings.HasPrefix(value, "scaleway://") {
		return "", "", fmt.Errorf("invalid VM provider ID")
	}
	parts := strings.Split(strings.TrimPrefix(value, "scaleway://"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("invalid VM provider ID")
	}
	return parts[0], parts[1], nil
}
