variable "contexte_kubectl" {
  description = "Contexte kubeconfig du cluster (sortie de la couche 00)."
  type        = string
  default     = "kind-velocite"
}

variable "phrase_etat" {
  description = "Phrase de passe du chiffrement du state. Jamais dans un fichier : $env:TF_VAR_phrase_etat."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.phrase_etat) >= 16
    error_message = "16 caractères minimum."
  }
}

variable "leger" {
  description = "Profil léger pour un poste à 8 Go : sans Loki ni Alloy, rétention courte."
  type        = bool
  default     = false
}

variable "environnements" {
  description = "Namespaces applicatifs dont Alloy collecte les logs."
  type        = list(string)
  default     = ["velocite-dev", "velocite-prod"]
}
