terraform {
  required_version = ">= 1.8.1"
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      # kreuzwerker/docker releases below 3.7.0 (including the 2.23.1 the
      # upstream tofu/main/k3d project pins) fail OpenTofu's provider
      # signature check ("authentication signature from unknown issuer") --
      # the provider's signing key was rotated and older releases were never
      # re-signed. Use a version that is.
      version = ">= 3.7.0, < 4.0.0"
    }
    k3d = {
      source  = "moio/k3d"
      version = "0.0.12"
    }
  }
}
