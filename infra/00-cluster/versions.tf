# Versions figées : le même code produit le même cluster dans six mois.
# Les empreintes des providers téléchargés sont dans .terraform.lock.hcl,
# qui se versionne.
terraform {
  required_version = ">= 1.13.0, < 2.0.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "= 0.11.0"
    }
  }
}
