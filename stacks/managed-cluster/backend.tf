terraform {
  # State path injected at init time by the Makefile:
  #   /state/{namespace}/{env}/{instance}/{region}/managed-cluster
  # For a tenant context, env='tenant' and instance='<tenant-name>'.
  backend "http" {}
}
