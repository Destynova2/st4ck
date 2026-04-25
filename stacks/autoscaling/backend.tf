terraform {
  # State path injected at init time by the Makefile:
  #   /state/{namespace}/{env}/{instance}/{region}/autoscaling
  backend "http" {}
}
