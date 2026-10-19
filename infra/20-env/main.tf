# ---------------------------------------------------------------------------
# Couche 20 - un environnement (dev ou prod), dans le cluster.
#
# Un workspace OpenTofu par environnement : même code, deux states.
#   tofu workspace select -or-create dev
#   tofu apply -var-file envs/dev.tfvars
#
# Ce que crée cette couche : le namespace et ses garde-fous (quota, limites
# par défaut, réseau fermé par défaut), puis tous les secrets de
# l'environnement. Les applications sont déployées ensuite par Kustomize
# (dossier deploy/), qui ne contient aucun secret.
# ---------------------------------------------------------------------------

locals {
  namespace = "velocite-${var.env}"
}

# Garde-fou : appliquer les valeurs de prod dans le workspace dev écraserait
# les secrets de dev. On refuse avant d'agir.
resource "terraform_data" "garde_workspace" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace == var.env
      error_message = "Workspace ${terraform.workspace} mais env = ${var.env}. Faites : tofu workspace select ${var.env}"
    }
  }
}

module "espace" {
  source    = "./modules/espace"
  namespace = local.namespace
  env       = var.env
  quota     = var.quota
}

module "secrets" {
  source              = "./modules/secrets"
  namespace           = module.espace.namespace
  duree_certificats_h = var.duree_certificats_h
}
