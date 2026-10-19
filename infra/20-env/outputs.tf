output "namespace" {
  value = module.espace.namespace
}

output "url_frontal" {
  description = "Adresse du frontal de cet environnement, depuis le poste."
  value       = var.env == "dev" ? "https://localhost:8443" : "https://localhost:9443"
}

output "certificat_ac" {
  description = "Certificat de l'autorité interne, pour vérifier le frontal (curl.exe --cacert)."
  value       = module.secrets.certificat_ac
}

output "mots_de_passe_comptes" {
  description = "Mots de passe des comptes fixes. tofu output -json mots_de_passe_comptes"
  value       = module.secrets.mots_de_passe_comptes
  sensitive   = true
}
