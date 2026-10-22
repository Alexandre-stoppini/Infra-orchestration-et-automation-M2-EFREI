# ---------------------------------------------------------------------------
# Couche 00, variante cloud : le cluster chez Hetzner au lieu de kind.
#
# Elle seule remplace infra/00-cluster : infra/20-env et deploy/ s'appliquent
# ensuite sans modification, avec le contexte kubectl "hetzner-<eleve>"
# (scripts/cloud.ps1).
#
# Réseau   : l'adresse publique de la machine, et un pare-feu ouvert à UNE
#            adresse, la vôtre (reseau.tf, à écrire).
# Calcul   : un serveur qui fait tourner k3s (Kubernetes léger).
# Stockage : son disque (les volumes des bases y vivent), et le state de
#            cette couche, sur votre poste, chiffré.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.69.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.1"
    }
  }

  # Le state reste sur votre poste (terraform.tfstate, ignoré par Git). Il
  # contient la clé SSH de la machine : chiffré par votre phrase.
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

# Le token vient de $env:HCLOUD_TOKEN, jamais d'un fichier. Il n'ouvre que
# votre projet Hetzner : vous ne voyez pas les machines des autres.
provider "hcloud" {}
