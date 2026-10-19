# ---------------------------------------------------------------------------
# Couche 10 - les outils partagés du cluster.
#
# Installés une fois par cluster, communs à dev et prod :
#   - metrics-server        consommation CPU et mémoire (kubectl top, HPA)
#   - Argo Workflows        orchestration du bilan quotidien
#   - Prometheus            métriques, règles d'alerte, Alertmanager,
#                           Pushgateway, kube-state-metrics
#   - Grafana               tableaux de bord
#   - Loki + Alloy          logs (absents en profil léger)
#
# Les règles d'alerte et les tableaux de bord ne sont pas ici : ils sont dans
# observability/, à la racine du dépôt. Cette couche les lit. Modifier une
# alerte, c'est modifier un fichier versionné, puis tofu apply.
#
# Ordre : 00-cluster, puis 10-outils, puis 20-env (une fois par
# environnement).
# ---------------------------------------------------------------------------

locals {
  observabilite = "../../observability"

  # Pods des outils : contrôlés en "restricted", comme les applications.
  # Le mode "warn" affiche un avertissement à chaque écart, sans bloquer.
  psa = {
    "pod-security.kubernetes.io/enforce" = "restricted"
    "pod-security.kubernetes.io/warn"    = "restricted"
    "pod-security.kubernetes.io/audit"   = "restricted"
  }

  sources_grafana = concat(
    [{
      name      = "Prometheus"
      uid       = "prometheus"
      type      = "prometheus"
      url       = "http://prometheus-server.observabilite.svc"
      access    = "proxy"
      isDefault = true
    }],
    var.leger ? [] : [{
      name   = "Loki"
      uid    = "loki"
      type   = "loki"
      url    = "http://loki.observabilite.svc:3100"
      access = "proxy"
    }],
  )
}

resource "kubernetes_namespace_v1" "outils" {
  for_each = toset(["argo", "observabilite"])
  metadata {
    name   = each.key
    labels = merge(local.psa, { "velocite.fr/couche" = "10-outils" })
  }
}

# ------------------------------------------------------------- metrics-server

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  values     = [file("${path.module}/valeurs/metrics-server.yaml")]
  wait       = true
  timeout    = 300
}

# -------------------------------------------------------------- Argo Workflows

resource "helm_release" "argo" {
  name       = "argo-workflows"
  namespace  = kubernetes_namespace_v1.outils["argo"].metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-workflows"
  version    = "2.0.12"
  values     = [file("${path.module}/valeurs/argo-workflows.yaml")]
  wait       = true
  timeout    = 600
}

# ----------------------------------------------------------------- Prometheus

resource "helm_release" "prometheus" {
  name       = "prometheus"
  namespace  = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "29.36.1"
  values = [
    file("${path.module}/valeurs/prometheus.yaml"),
    yamlencode({
      server = {
        retention = var.leger ? "1d" : "3d"
      }
      serverFiles = {
        "alerting_rules.yml"  = yamldecode(file("${local.observabilite}/regles/alertes.yaml"))
        "recording_rules.yml" = yamldecode(file("${local.observabilite}/regles/enregistrement.yaml"))
      }
    }),
  ]
  wait    = true
  timeout = 600
}

# -------------------------------------------------------------------- Grafana

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

# Un tableau de bord par fichier JSON de observability/dashboards/.
resource "kubernetes_config_map_v1" "tableaux" {
  metadata {
    name      = "grafana-tableaux-velocite"
    namespace = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  }
  data = {
    for f in fileset("${local.observabilite}/dashboards", "*.json") :
    f => file("${local.observabilite}/dashboards/${f}")
  }
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = "13.5.0"
  values = [
    file("${path.module}/valeurs/grafana.yaml"),
    yamlencode({
      admin = { existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name }
      datasources = {
        "datasources.yaml" = { apiVersion = 1, datasources = local.sources_grafana }
      }
      dashboardsConfigMaps = {
        velocite = kubernetes_config_map_v1.tableaux.metadata[0].name
      }
    }),
  ]
  wait    = true
  timeout = 600
}

# ------------------------------------------------------- Loki et Alloy (logs)

resource "helm_release" "loki" {
  count      = var.leger ? 0 : 1
  name       = "loki"
  namespace  = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = "18.15.1"
  values     = [file("${path.module}/valeurs/loki.yaml")]
  wait       = true
  timeout    = 600
}

resource "helm_release" "alloy" {
  count      = var.leger ? 0 : 1
  name       = "alloy"
  namespace  = kubernetes_namespace_v1.outils["observabilite"].metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.13.1"
  values = [
    file("${path.module}/valeurs/alloy.yaml"),
    yamlencode({
      alloy = {
        configMap = {
          content = templatefile("${local.observabilite}/collecte.alloy.tftpl", {
            namespaces = jsonencode(concat(var.environnements, ["argo"]))
          })
        }
      }
    }),
  ]
  wait    = true
  timeout = 300

  depends_on = [helm_release.loki]
}
