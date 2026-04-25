terraform {
  # Init via:
  #   tofu init -reconfigure \
  #     -backend-config="address=http://localhost:8080/state/st4ck/{env}/{instance}/{region}/ci"
  # (Makefile injects these.)
  backend "http" {}
}
