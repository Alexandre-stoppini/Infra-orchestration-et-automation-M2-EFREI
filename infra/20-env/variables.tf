variable "env" {
  description = "Nom de l'environnement : dev ou prod. Doit correspondre au workspace."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "Deux environnements seulement : dev ou prod."
  }
}

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

variable "quota" {
  description = "Plafonds de l'environnement : ce que tous ses pods réunis peuvent demander."
  type = object({
    cpu_demande    = string
    memoire_limite = string
    stockage       = string
    nb_pvc         = number
    nb_pods        = number
  })
}

variable "duree_certificats_h" {
  description = "Durée de validité des certificats serveur, en heures."
  type        = number
  default     = 2160 # 90 jours
}
