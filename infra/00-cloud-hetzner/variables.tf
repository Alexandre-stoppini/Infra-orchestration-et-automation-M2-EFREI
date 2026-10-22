variable "eleve" {
  description = "Votre identifiant, velocite-prenom-nom : il nomme et étiquette tout ce que vous créez. $env:TF_VAR_eleve."
  type        = string

  validation {
    condition     = can(regex("^velocite-[a-z0-9-]{2,40}$", var.eleve))
    error_message = "Format attendu : velocite-prenom-nom, en minuscules, sans accent."
  }
}

variable "mon_ip" {
  description = "Votre adresse IP publique, en /32 : la seule qui joindra la machine."
  type        = string

  validation {
    condition     = can(cidrhost(var.mon_ip, 0)) && endswith(var.mon_ip, "/32")
    error_message = "Une seule adresse, au format a.b.c.d/32."
  }
}

variable "emplacement" {
  description = "Centre de données Hetzner : nbg1 (Nuremberg), fsn1 (Falkenstein), hel1 (Helsinki)."
  type        = string
  default     = "nbg1"
}

variable "type_serveur" {
  description = "cx33 : 4 vCPU, 8 Go, 80 Go de disque. Facturé à l'heure, environ 1,4 centime."
  type        = string
  default     = "cx33"
}

variable "version_k3s" {
  description = "Version de k3s, alignée sur le Kubernetes du module (1.36)."
  type        = string
  default     = "v1.36.5+k3s1"
}

variable "phrase_etat" {
  description = "Phrase de passe du chiffrement du state : $env:TF_VAR_phrase_etat."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.phrase_etat) >= 16
    error_message = "16 caractères minimum."
  }
}
