terraform {
  # Init via:
  #   tofu init -reconfigure \
  #     -backend-config="address=http://localhost:8080/state/st4ck/_image/{region}"
  backend "http" {}
}
