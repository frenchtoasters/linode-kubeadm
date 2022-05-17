terraform {
  cloud {
    organization = "cloudwork"
    workspaces {
      name = "Town_Dev"
    }
  }
  required_providers {
    linode = {
      source  = "linode/linode"
      version = ">=1.26.1"
    }
    remote = {
      source  = "tenstad/remote"
      version = "0.0.24"
    }
  }
}

