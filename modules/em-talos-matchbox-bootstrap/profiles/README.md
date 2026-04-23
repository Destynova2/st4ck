# Matchbox profiles

Matchbox serves iPXE profiles + assets from `/var/lib/matchbox` inside
the sidecar container (see `bootstrap/platform-pod.yaml`). The sidecar's
emptyDir volume is laid out as:

```
/var/lib/matchbox/
├── profiles/           # JSON profile definitions (one per cluster role)
├── groups/             # MAC-to-profile bindings
├── assets/
│   └── talos/
│       ├── vmlinuz-amd64
│       └── initramfs-amd64.xz
└── ignition/           # future: butane → ignition manifests (unused for Talos)
```

At P14 the ConfigMap `matchbox-profiles` (mounted at `/etc/matchbox/profiles`)
ships a single placeholder profile that echoes the contract below. The
actual Talos kernel + initramfs are pulled from the Talos Factory by a
follow-up plat (Karpenter NodeClass rollout, issue #1 Phase B).

## Placeholder profile contract

```json
{
  "id": "talos-placeholder",
  "name": "talos-placeholder",
  "boot": {
    "kernel": "/assets/talos/vmlinuz-amd64",
    "initrd": ["/assets/talos/initramfs-amd64.xz"],
    "args": [
      "initrd=initramfs-amd64.xz",
      "talos.platform=metal",
      "talos.config=http://127.0.0.1:8080/generic?mac=${mac:hexhyp}"
    ]
  }
}
```

## Test from inside the pod

```
kubectl -n bootstrap exec -c matchbox platform -- \
  wget -qO- http://127.0.0.1:8080/profiles/talos-placeholder
```

Matchbox responds with 200 + JSON when the profile is reachable.

## Next steps (out of P14 scope)

- Pull kernel + initrd from Talos Factory into the emptyDir on pod start.
- Publish per-MAC ignition/cloud-init templates for tenant machine configs.
- Wire Karpenter's EC2NodeClass analogue (custom provider from issue #1)
  to POST profile/group JSON to Matchbox when a node is provisioned.
