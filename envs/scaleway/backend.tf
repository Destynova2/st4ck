terraform {
  # State path is parameterized at `tofu init` time:
  #   tofu init -reconfigure \
  #     -backend-config="address=http://localhost:8080/state/st4ck/dev/alice/fr-par/cluster" \
  #     -backend-config="lock_address=http://localhost:8080/state/st4ck/dev/alice/fr-par/cluster" \
  #     -backend-config="unlock_address=http://localhost:8080/state/st4ck/dev/alice/fr-par/cluster"
  #
  # The Makefile injects these from ENV/INSTANCE/REGION.
  backend "http" {}
}
