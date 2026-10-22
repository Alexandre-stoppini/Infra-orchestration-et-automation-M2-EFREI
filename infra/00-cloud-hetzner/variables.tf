variable "eleve" {
  description = "L'identifiant de votre équipe, velocite-equipeN (N, le numéro reçu avec le token) : il nomme et étiquette tout ce que vous créez. $env:TF_VAR_eleve."
  type        = string

  validation {
    condition     = can(regex("^velocite-(equipe[1-9][0-9]?|prof)$", var.eleve))
    error_message = "TF_VAR_eleve : format attendu velocite-equipeN, avec le numéro de votre équipe, celui du message Moodle qui donne le token (par exemple velocite-equipe3), en minuscules."
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

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1"], var.emplacement)
    error_message = "TF_VAR_emplacement : nbg1, fsn1 ou hel1, en minuscules."
  }
}

variable "type_serveur" {
  description = "cx33 : 4 vCPU, 8 Go, 80 Go de disque. Facturé à l'heure, environ 1,4 centime."
  type        = string
  default     = "cx33"

  # Le compte du cours a 36 vCPU partagés pour 8 équipes : une machine plus
  # grosse prendrait la place d'une autre équipe.
  validation {
    condition     = var.type_serveur == "cx33"
    error_message = "type_serveur : cx33 seulement. Le compte du cours a 36 vCPU pour 8 équipes : une machine plus grosse prendrait la place d'une autre équipe."
  }
}

variable "version_k3s" {
  description = "Version de k3s, alignée sur le Kubernetes du module (1.36)."
  type        = string
  default     = "v1.36.5+k3s1"

  validation {
    condition     = can(regex("^v1\\.36\\.[0-9]+\\+k3s[0-9]+$", var.version_k3s))
    error_message = "version_k3s : une version 1.36 de k3s, au format v1.36.5+k3s1."
  }
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
