# Versions figées, comme les autres couches. Les versions des charts Helm
# sont dans main.tf, à côté de chaque release.
terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
  }

  # Le state contient le mot de passe administrateur de Grafana : chiffré,
  # avec la même phrase de passe que la couche 20.
  encryption {
    key_provider "pbkdf2" "phrase" {
      passphrase = var.phrase_etat
    }
    method "aes_gcm" "chiffrement" {
      keys = key_provider.pbkdf2.phrase
    }
    state {
      method   = method.aes_gcm.chiffrement
      enforced = true
    }
    plan {
      method   = method.aes_gcm.chiffrement
      enforced = true
    }
  }
}
