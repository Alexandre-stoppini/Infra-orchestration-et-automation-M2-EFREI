output "grafana" {
  description = "Accès à Grafana depuis le poste."
  value       = "kubectl -n observabilite port-forward svc/grafana 3000:80, puis http://localhost:3000 (compte admin)"
}

output "grafana_mot_de_passe" {
  description = "tofu output -raw grafana_mot_de_passe"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "argo" {
  description = "Accès à l'interface d'Argo Workflows depuis le poste."
  value       = "kubectl -n argo port-forward svc/argo-workflows-server 2746:2746, puis http://localhost:2746"
}

output "prometheus" {
  description = "Accès à Prometheus et à Alertmanager depuis le poste."
  value       = "kubectl -n observabilite port-forward svc/prometheus-server 9090:80 ; svc/prometheus-alertmanager 9093:9093"
}
