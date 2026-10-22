output "ip_publique" {
  description = "Adresse publique de la machine."
  value       = hcloud_server.k3s.ipv4_address
}

output "contexte_kubectl" {
  description = "Contexte ajouté à ~/.kube/config par scripts/cloud.ps1."
  value       = "hetzner-${var.eleve}"
}

output "cle_ssh" {
  description = "Fichier de la clé SSH (ignoré par Git)."
  value       = local_sensitive_file.cle_ssh.filename
}

output "cout" {
  description = "Ce que coûte la machine tant qu'elle existe, allumée ou éteinte."
  value       = "${var.type_serveur} : environ 1,4 centime d'euro par heure, jusqu'à scripts/cloud.ps1 -Etape detruire"
}
