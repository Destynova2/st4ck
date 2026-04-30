terraform {
  # State path injected at init time by the Makefile:
  #   /state/{namespace}/{env}/{instance}/{region}/registry-mirror
  # Stage is region-scoped (one SCR namespace per region) and idempotent
  # — re-applying with the same name is a no-op.
  backend "http" {}
}
