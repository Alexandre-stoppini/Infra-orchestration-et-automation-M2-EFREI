terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.1"
    }
  }

  # Le state de cette couche contient tous les secrets de l'environnement
  # (mots de passe, clés, certificats). Il est chiffré : sans la phrase de
  # passe, le fichier ne se lit pas. Perdre la phrase de passe, c'est perdre
  # le state, pas le cluster.
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
