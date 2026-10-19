# ---------------------------------------------------------------------------
# Tous les secrets d'un environnement, générés ici et nulle part ailleurs.
#
# Aucun secret n'est écrit dans le dépôt : ils naissent au premier apply,
# vivent dans le state (chiffré) et dans des Secrets Kubernetes. Les noms de
# clés sont ceux que les services lisent dans /run/secrets, comme en Compose.
# ---------------------------------------------------------------------------

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    random     = { source = "hashicorp/random" }
    tls        = { source = "hashicorp/tls" }
  }
}

variable "namespace" { type = string }
variable "duree_certificats_h" { type = number }

locals {
  mots_de_passe = toset([
    "postgres_password", "pg_svc_api", "pg_svc_ingest", "pg_svc_batch",
    "pg_svc_seed", "redis_api", "redis_sonde", "admin_password",
    "service_password", "datasci_password", "analyst_password",
    "support_password",
  ])
  services_s3    = toset(["api", "seed", "batch"])
  parametres_tls = "sslmode=verify-full&sslrootcert=/run/secrets/ca.crt"
  noms_postgres  = ["postgres", "postgres.${var.namespace}.svc", "postgres.${var.namespace}.svc.cluster.local"]
  noms_nginx     = ["nginx", "nginx.${var.namespace}.svc", "nginx.${var.namespace}.svc.cluster.local", "localhost"]
}

# ------------------------------------------------------------ mots de passe

resource "random_password" "mdp" {
  for_each = local.mots_de_passe
  length   = 32
  special  = false # ils voyagent dans des URL de connexion
}

resource "random_password" "jetons" {
  for_each = toset(["jwt_secret", "ingest_device_key", "garage_admin_token", "garage_metrics_token"])
  length   = 48
  special  = false
}

resource "random_id" "hex32" {
  for_each    = toset(["pseudo_key", "garage_rpc_secret"])
  byte_length = 32
}

# Format imposé par Garage : identifiant GK + 24 hexadécimaux, secret de 64.
resource "random_id" "cle_s3" {
  for_each    = local.services_s3
  byte_length = 12
}

resource "random_id" "secret_s3" {
  for_each    = local.services_s3
  byte_length = 32
}

# --------------------------------------------------------------------- TLS

resource "tls_private_key" "ac" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ac" {
  private_key_pem       = tls_private_key.ac.private_key_pem
  is_ca_certificate     = true
  set_subject_key_id    = true
  validity_period_hours = 8760
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name  = "VeloCite AC ${var.namespace}"
    organization = "VeloCite - support de cours"
  }
}

resource "tls_private_key" "serveur" {
  for_each    = toset(["nginx", "postgres"])
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "serveur" {
  for_each        = tls_private_key.serveur
  private_key_pem = each.value.private_key_pem
  dns_names       = each.key == "nginx" ? local.noms_nginx : local.noms_postgres
  ip_addresses    = each.key == "nginx" ? ["127.0.0.1"] : []
  subject {
    common_name = each.key
  }
}

resource "tls_locally_signed_cert" "serveur" {
  for_each              = tls_cert_request.serveur
  cert_request_pem      = each.value.cert_request_pem
  ca_private_key_pem    = tls_private_key.ac.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ac.cert_pem
  set_subject_key_id    = true
  validity_period_hours = var.duree_certificats_h
  early_renewal_hours   = 720 # renouvelé au premier apply du dernier mois
  allowed_uses          = ["digital_signature", "key_agreement", "server_auth"]
}

# --------------------------------------------------------- Secrets Kubernetes

locals {
  mdp = { for k, v in random_password.mdp : k => v.result }
  url_db = { for svc in ["api", "ingest", "batch", "seed"] :
    "database_url_${svc}" => "postgresql://svc_${svc}:${local.mdp["pg_svc_${svc}"]}@postgres:5432/velocite?${local.parametres_tls}"
  }
}

# A FAIRE (atelier 4) : le Secret "velocite-db". Ses clés :
#   postgres_password, pg_svc_api, pg_svc_ingest, pg_svc_batch, pg_svc_seed
#     (les mots de passe générés plus haut, dans local.mdp)
#   database_url_api, database_url_ingest, database_url_batch, database_url_seed
#     (déjà calculées dans local.url_db)
# Indice : merge() assemble deux maps en une.

resource "kubernetes_secret_v1" "redis" {
  metadata {
    name      = "velocite-redis"
    namespace = var.namespace
  }
  data = {
    "redis_users.acl" = join("\n", [
      "user default off",
      "user api on >${local.mdp["redis_api"]} ~rl:* ~cache:* -@all +@read +@write +@connection -@dangerous",
      "user sonde on >${local.mdp["redis_sonde"]} -@all +ping +@connection",
    ])
    redis_sonde   = local.mdp["redis_sonde"]
    redis_url_api = "redis://api:${local.mdp["redis_api"]}@redis:6379/0"
  }
}

# A FAIRE (atelier 4) : le Secret "velocite-app". Ses clés :
#   admin_password, service_password, datasci_password, analyst_password,
#   support_password (dans local.mdp)
#   jwt_secret et ingest_device_key (random_password.jetons)
#   pseudo_key (random_id.hex32, au format hexadécimal)

resource "kubernetes_secret_v1" "garage" {
  metadata {
    name      = "velocite-garage"
    namespace = var.namespace
  }
  data = merge(
    {
      garage_rpc_secret    = random_id.hex32["garage_rpc_secret"].hex
      garage_admin_token   = random_password.jetons["garage_admin_token"].result
      garage_metrics_token = random_password.jetons["garage_metrics_token"].result
    },
    { for s in local.services_s3 : "s3_${s}_key_id" => "GK${random_id.cle_s3[s].hex}" },
    { for s in local.services_s3 : "s3_${s}_secret" => random_id.secret_s3[s].hex },
  )
}

resource "kubernetes_secret_v1" "tls_nginx" {
  metadata {
    name      = "velocite-tls-nginx"
    namespace = var.namespace
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_locally_signed_cert.serveur["nginx"].cert_pem
    "tls.key" = tls_private_key.serveur["nginx"].private_key_pem_pkcs8
  }
}

resource "kubernetes_secret_v1" "tls_postgres" {
  metadata {
    name      = "velocite-tls-postgres"
    namespace = var.namespace
  }
  data = {
    "postgres.crt" = tls_locally_signed_cert.serveur["postgres"].cert_pem
    "postgres.key" = tls_private_key.serveur["postgres"].private_key_pem_pkcs8
  }
}

# Le certificat de l'autorité n'est pas un secret : n'importe quel client
# doit pouvoir le lire pour vérifier les serveurs.
resource "kubernetes_config_map_v1" "ac" {
  metadata {
    name      = "velocite-ca"
    namespace = var.namespace
  }
  data = {
    "ca.crt" = tls_self_signed_cert.ac.cert_pem
  }
}

output "certificat_ac" {
  value = tls_self_signed_cert.ac.cert_pem
}

output "mots_de_passe_comptes" {
  value     = { for k in ["admin_password", "service_password", "datasci_password", "analyst_password", "support_password"] : k => local.mdp[k] }
  sensitive = true
}
