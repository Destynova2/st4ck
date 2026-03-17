terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    gitea = {
      source  = "go-gitea/gitea"
      version = "~> 0.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "vault" {
  address         = "http://127.0.0.1:8200"
  skip_tls_verify = true
  auth_login_userpass {
    username = "bootstrap-admin"
    password = var.bao_admin_password
  }
}

provider "gitea" {
  base_url = var.gitea_internal_url
  username = var.ci_admin
  password = var.ci_password
}
