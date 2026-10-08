# ─── Self-init: KV v2 for application secrets ────────────────
initialize "kv" {
  request "mount-kv" {
    operation = "update"
    path      = "sys/mounts/secret"
    data = {
      type    = "kv"
      options = { version = "2" }
    }
  }
}
