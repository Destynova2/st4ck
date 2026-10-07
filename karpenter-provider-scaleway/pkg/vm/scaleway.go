package vm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"

	instance "github.com/scaleway/scaleway-sdk-go/api/instance/v1"
	"github.com/scaleway/scaleway-sdk-go/scw"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
)

type Scaleway struct{ api *instance.API }

func NewScaleway() (*Scaleway, error) {
	c, err := scw.NewClient(scw.WithEnv())
	if err != nil {
		return nil, err
	}
	return &Scaleway{api: instance.NewAPI(c)}, nil
}

func (b *Scaleway) image(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass) (*instance.Image, error) {
	r, err := b.api.GetImage(&instance.GetImageRequest{Zone: scw.Zone(nc.Spec.Zone), ImageID: nc.Spec.ImageID}, scw.WithContext(ctx))
	if err != nil {
		return nil, err
	}
	i := r.Image
	if i == nil || i.Project != nc.Spec.ProjectID || string(i.State) != "available" || len(i.ExtraVolumes) != 0 || i.RootVolume == nil || i.RootVolume.VolumeType != instance.VolumeVolumeTypeLSSD {
		return nil, fmt.Errorf("a private available image with only a local SSD root disk is required")
	}
	arch := string(i.Arch)
	if arch == "x86_64" {
		arch = "amd64"
	}
	if arch != nc.Spec.Architecture {
		return nil, fmt.Errorf("image architecture does not match node class")
	}
	return i, nil
}

func (b *Scaleway) Validate(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass) error {
	i, err := b.image(ctx, nc)
	if err != nil {
		return err
	}
	r, err := b.api.ListServersTypes(&instance.ListServersTypesRequest{Zone: scw.Zone(nc.Spec.Zone)}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		return err
	}
	size := scw.Size(nc.Spec.EphemeralDiskGiB) * (1 << 30)
	for _, name := range nc.Spec.InstanceTypes {
		t := r.Servers[name]
		if t == nil || t.VolumesConstraint == nil || t.PerVolumeConstraint == nil || t.PerVolumeConstraint.LSSD == nil {
			return fmt.Errorf("instance type %s does not advertise local SSD capacity", name)
		}
		limits := t.PerVolumeConstraint.LSSD
		if size < limits.MinSize || size > limits.MaxSize || i.RootVolume.Size < limits.MinSize || i.RootVolume.Size > limits.MaxSize || size+i.RootVolume.Size > t.VolumesConstraint.MaxSize {
			return fmt.Errorf("image and EPHEMERAL disks exceed local SSD constraints for %s", name)
		}
	}
	return nil
}

func (b *Scaleway) Shapes(ctx context.Context, zone string) ([]Shape, error) {
	r, err := b.api.ListServersTypes(&instance.ListServersTypesRequest{Zone: scw.Zone(zone)}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		return nil, err
	}
	a, err := b.api.GetServerTypesAvailability(&instance.GetServerTypesAvailabilityRequest{Zone: scw.Zone(zone)}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		return nil, err
	}
	var result []Shape
	for name, t := range r.Servers {
		if t.Gpu != nil && *t.Gpu > 0 {
			continue
		}
		arch := string(t.Arch)
		if arch == "x86_64" {
			arch = "amd64"
		}
		if arch != "amd64" && arch != "arm64" {
			continue
		}
		available := false
		if stock, ok := a.Servers[name]; ok {
			available = string(stock.Availability) == "available" || string(stock.Availability) == "scarce"
		}
		// Retired types still describe running NodeClaims. Removing them would
		// trigger core InstanceTypeNotFound drift and break Get hydration.
		available = available && !t.EndOfService
		result = append(result, Shape{Name: name, Architecture: arch, CPU: int64(t.Ncpus), Memory: int64(t.RAM), Price: float64(t.HourlyPrice), Available: available})
	}
	return result, nil
}

func convert(s *instance.Server) Server {
	return Server{ID: s.ID, Zone: string(s.Zone), Project: s.Project, Type: s.CommercialType, State: string(s.State), Tags: s.Tags}
}

func (b *Scaleway) List(ctx context.Context, zone, project string, tags []string) ([]Server, error) {
	r, err := b.api.ListServers(&instance.ListServersRequest{Zone: scw.Zone(zone), Project: &project, Tags: tags}, scw.WithContext(ctx), scw.WithAllPages())
	if err != nil {
		return nil, err
	}
	var result []Server
	for _, s := range r.Servers {
		// API filtering is not an authorization boundary.
		if s.Project != project {
			continue
		}
		match := true
		for _, tag := range tags {
			if !slices.Contains(s.Tags, tag) {
				match = false
			}
		}
		if match {
			result = append(result, convert(s))
		}
	}
	return result, nil
}

func (b *Scaleway) Get(ctx context.Context, zone, id string) (Server, error) {
	r, err := b.api.GetServer(&instance.GetServerRequest{Zone: scw.Zone(zone), ServerID: id}, scw.WithContext(ctx))
	if err != nil {
		var missing *scw.ResourceNotFoundError
		if errors.As(err, &missing) {
			return Server{}, ErrNotFound
		}
		return Server{}, err
	}
	return convert(r.Server), nil
}

func (b *Scaleway) Create(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass, name, shape string, tags []string) (Server, error) {
	i, err := b.image(ctx, nc)
	if err != nil {
		return Server{}, err
	}
	no := false
	yes := true
	size := scw.Size(nc.Spec.EphemeralDiskGiB) * (1 << 30)
	r, err := b.api.CreateServer(&instance.CreateServerRequest{
		Zone: scw.Zone(nc.Spec.Zone), Name: name, Project: &nc.Spec.ProjectID,
		CommercialType: shape, Image: &nc.Spec.ImageID, DynamicIPRequired: &no,
		SecurityGroup: &nc.Spec.SecurityGroupID, Tags: tags,
		Volumes: map[string]*instance.VolumeServerTemplate{
			"0": {Boot: &yes, Size: &i.RootVolume.Size, VolumeType: instance.VolumeVolumeTypeLSSD},
			"1": {Name: &name, Size: &size, VolumeType: instance.VolumeVolumeTypeLSSD},
		},
	}, scw.WithContext(ctx))
	if err != nil {
		return Server{}, err
	}
	return convert(r.Server), nil
}

func (b *Scaleway) Configure(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass, s Server, config []byte) error {
	r, err := b.api.GetServer(&instance.GetServerRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID}, scw.WithContext(ctx))
	if err != nil {
		return err
	}
	attached := false
	for _, nic := range r.Server.PrivateNics {
		if nic.PrivateNetworkID == nc.Spec.PrivateNetworkID {
			attached = true
		}
	}
	if !attached {
		_, err = b.api.CreatePrivateNIC(&instance.CreatePrivateNICRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID, PrivateNetworkID: nc.Spec.PrivateNetworkID}, scw.WithContext(ctx))
		if err != nil {
			return err
		}
	}
	return b.api.SetServerUserData(&instance.SetServerUserDataRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID, Key: "cloud-init", Content: bytes.NewReader(config)}, scw.WithContext(ctx))
}

func (b *Scaleway) Start(ctx context.Context, s Server) error {
	_, err := b.api.ServerAction(&instance.ServerActionRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID, Action: instance.ServerActionPoweron}, scw.WithContext(ctx))
	return err
}

func (b *Scaleway) Delete(ctx context.Context, s Server) error {
	r, err := b.api.GetServer(&instance.GetServerRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID}, scw.WithContext(ctx))
	if err != nil {
		return err
	}
	for _, v := range r.Server.Volumes {
		if string(v.VolumeType) != "l_ssd" {
			return fmt.Errorf("refusing termination with non-local disk %s", v.ID)
		}
	}
	if s.State == "stopped" {
		_, err = b.api.ServerAction(&instance.ServerActionRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID, Action: instance.ServerActionTerminate}, scw.WithContext(ctx))
	} else if s.State == "running" {
		_, err = b.api.ServerAction(&instance.ServerActionRequest{Zone: scw.Zone(s.Zone), ServerID: s.ID, Action: instance.ServerActionPoweroff}, scw.WithContext(ctx))
	} else if s.State != "stopping" && s.State != "starting" && s.State != "locked" {
		return fmt.Errorf("cannot terminate VM in state %s", s.State)
	}
	return err
}
