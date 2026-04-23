# ─────────────────────────────────────────────────────────────────────
# Paste this into ~/.config/scw/config.yaml (replaces the whole file).
# Generated from `tofu -chdir=envs/scaleway/iam output -raw scw_config_snippet`.
# ─────────────────────────────────────────────────────────────────────

active_profile: st4ck-readonly     # Claude/AI uses this by default (readonly on ${project_name}).

profiles:

  # ─── admin ──────────────────────────────────────────────────────────
  # Your org-wide admin key (SCWFSMBKM0G0... etc.).
  # Use `scw config activate-profile admin` ONLY when you need to apply
  # stages that require org-level rights (initial IAM, project creation).
  # Keep these values updated manually — Terraform doesn't manage them.
  admin:
    access_key: PASTE-YOUR-ADMIN-ACCESS-KEY
    secret_key: PASTE-YOUR-ADMIN-SECRET-KEY
    default_organization_id: ${org_id}
    default_project_id: ${org_id}          # 'default' project id == org id in Scaleway
    default_region: ${region}
    default_zone: ${region}-1
%{ if readonly_enabled ~}

  # ─── st4ck-readonly (Claude/AI safe profile) ────────────────────────
  # Scope: ${project_name} project ONLY. Cannot reach other org projects.
  # Permission set: AllProductsReadOnly (+ IAMReadOnly if enabled).
  st4ck-readonly:
    access_key: ${readonly_access_key}
    secret_key: ${readonly_secret_key}
    default_project_id: ${project_id}
    default_region: ${region}
    default_zone: ${region}-1
%{ endif ~}
%{ if writeable_enabled ~}

  # ─── st4ck-admin (writeable profile, st4ck-only) ────────────────────
  # Scope: ${project_name} project ONLY. Full access inside the project.
  # Use `scw config activate-profile st4ck-admin` when you want to apply
  # infra changes on st4ck without exposing org-wide admin.
  st4ck-admin:
    access_key: ${writeable_access_key}
    secret_key: ${writeable_secret_key}
    default_project_id: ${project_id}
    default_region: ${region}
    default_zone: ${region}-1
%{ endif ~}
