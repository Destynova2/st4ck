# ADR-027 — OpenClarity for multi-scanner vulnerability + SBOM

**Date**: 2026-04-25
**Status**: Accepted
**Deciders**: ludwig
**Supersedes**: nothing (Trivy operator stays during transition)

## Context

After the first end-to-end deploy of `dev-mgmt-fr-par`, the Trivy operator was found scan-jobbing every cluster image (~50) but failing with cache lock contention:

```
ERROR Failed to acquire cache or database lock
FATAL unable to initialize fs cache: cache may be in use by another process: timeout
```

In Trivy operator's default `Standalone` mode, each scan job downloads the ~500MB-1GB Trivy DB into its own emptyDir. With multiple jobs running in parallel (default `concurrentScanJobsLimit: 3`), they hit each other's lockfile in /tmp/trivy.

Two ways out:

1. **Trivy server mode**: deploy a single `trivy-server` pod with PVC, all scan jobs become clients. Solves the lock issue, scan jobs become lightweight.

2. **OpenClarity** (Linux Foundation / OpenSSF, formerly Anchore's KubeClarity): a multi-scanner platform that runs Trivy + Grype + Syft in parallel against each discovered image, dedupes findings, exposes a UI/API backed by Postgres.

## Decision

Adopt **OpenClarity** as the primary multi-scanner platform, while keeping Trivy operator running during a transition period.

### Why two scanners (Trivy + Grype) instead of just Trivy server mode?

| Trivy DB | Grype DB |
|---|---|
| NVD | NVD |
| RedHat Security | RedHat Security |
| Alpine Security | Alpine Security |
| Debian Security Tracker | Debian Security Tracker |
| Ubuntu USN | Ubuntu USN |
| Amazon Linux | Amazon Linux |
| RockyLinux/AlmaLinux | RockyLinux/AlmaLinux |
| Wolfi/Chainguard | — |
| GHSA (limited) | **GHSA full** |
| **VEX feeds** | VEX support (less mature) |

Each scanner finds CVEs the other misses (estimated ~5-10% delta in cluster image scans per OpenClarity benchmarks). Defense-in-depth without paying for Snyk Enterprise.

### Why OpenClarity over Anchore Enterprise / KubeClarity / others?

- **Anchore Enterprise**: paid, vendor lock-in
- **KubeClarity** (legacy name): rebranded to OpenClarity in 2024 under LF/OpenSSF — same project, broader scope
- **Snyk Container**: paid, SaaS by default
- **Wiz / Orca / Aqua Cloud**: paid SaaS
- **Trivy server mode alone**: 1 scanner, no UI, no Grype dedupe

OpenClarity is the only open-source option that bundles 2+ scanners + UI + API in one chart.

### Why not just Trivy server mode + Grype as a CI step?

Considered. Tradeoff:

| Aspect | OpenClarity (continuous) | Trivy server + Grype CI |
|---|---|---|
| Scan cadence | Every 6h cluster-wide | Pre-push only |
| Catches drift | Yes (CVEs published after image build) | No |
| Setup complexity | Helm + Postgres + UI | Helm + Woodpecker step |
| Resource cost | ~500MB RAM (UI + API + Postgres + scanners) | ~200MB RAM (server only) |
| Single pane of glass | Yes (UI dedupe across scanners) | No (Trivy reports + Woodpecker artifacts) |
| Maturity | CNCF sandbox-equivalent (LF/OpenSSF, ~2k★) | Both mature |

**OpenClarity wins on ongoing visibility**: a CVE published 3 days after we pushed an image is invisible to a CI-only pipeline. OpenClarity's 6h re-scan catches it.

## Migration plan

### Phase 1 — both running (current)

- Trivy operator: `concurrentScanJobsLimit: 1` (band-aid for the lock issue, scans serialize but no lock contention)
- OpenClarity: full install, Trivy + Grype + Syft scanners enabled
- Both write findings to their own backends (Trivy CRs + OpenClarity Postgres)
- 2 sources of truth, but operator can correlate

### Phase 2 — OpenClarity primary (~1 sprint after Phase 1)

- Disable Trivy operator scan jobs: `operator.vulnerabilityScannerEnabled: false`
- Keep Trivy operator for compliance scans (kube-bench equivalent)
- All vulnerability dashboards point to OpenClarity API

### Phase 3 — full migration (~1 quarter)

- Remove Trivy operator entirely
- OpenClarity as sole vulnerability + SBOM source
- Polaris-style policy CRs migrated to Kyverno + OpenClarity webhook

### Rollback plan

If OpenClarity proves unstable (CNCF sandbox-equivalent maturity):
- Disable OpenClarity Helm release
- Revert Trivy operator to `concurrentScanJobsLimit: 1` (or higher with Trivy server mode)
- File issue against OpenClarity, retry next quarter

## Consequences

### Positive

- 2 scanners catch more CVEs than 1
- UI for vulnerability triage (operator-friendly vs `kubectl get vulnerabilityreports`)
- Continuous re-scan catches drift between image build and current CVE feeds
- Open source, no vendor lock-in
- LF / OpenSSF governance — stable steward

### Negative

- ~500MB RAM extra (UI + API + Postgres pods)
- Embedded Postgres single-replica (state loss if pod dies — acceptable for vuln data, can be re-scanned)
- CNCF sandbox-equivalent — less mature than Trivy operator alone
- Two scanners = two image-pull-bandwidth hits per scan cycle

### Risks

| Risk | Mitigation |
|---|---|
| OpenClarity bug blocks scans entirely | Trivy operator still running in Phase 1 → fallback always exists |
| Embedded Postgres dies | Vuln data is scanner-derived — re-scan rebuilds it |
| Helm chart breaking changes (sandbox) | Pin chart version in `var.openclarity_version`, controlled upgrade |
| Resource pressure on small clusters | `requests` set conservatively, `limits` cap memory at 2GB per scanner |

## Followups

- Phase 2 trigger: 30 days of OpenClarity stable in `dev-mgmt-fr-par`
- Switch embedded Postgres to external CNPG cluster (mirror identity stack pattern from ADR-026)
- Wire OpenClarity webhook into Kyverno admission policies (block deploy on critical CVE)
- Export OpenClarity metrics to VictoriaMetrics
