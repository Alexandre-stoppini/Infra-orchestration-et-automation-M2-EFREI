variable "nom_cluster" {
  description = "Nom du cluster kind. Le contexte kubectl sera kind-<nom>."
  type        = string
  default     = "velocite"
}

variable "image_noeud" {
  description = "Image des noeuds kind : fixe la version de Kubernetes. Épinglée par empreinte."
  type        = string
  # Kubernetes 1.36.4, image publiée avec kind v0.33.0, tirée de
  # mirror.gcr.io : la copie de Docker Hub tenue par Google, même empreinte.
  # Pas 1.37 : le provider tehcyx/kind 0.11.0 embarque kind 0.31, qui écrit
  # une configuration kubeadm (v1beta3) que Kubernetes 1.37 refuse.
  default = "mirror.gcr.io/kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"
}

variable "nb_workers" {
  description = "Nombre de noeuds worker en plus du control-plane. 0 sur un poste à 8 Go."
  type        = number
  default     = 1

  validation {
    condition     = var.nb_workers >= 0 && var.nb_workers <= 3
    error_message = "Entre 0 et 3 workers : au-delà, un poste de travail ne suit plus."
  }
}

variable "ports_exposes" {
  description = "Ports NodePort du cluster publiés sur le poste (127.0.0.1 seulement)."
  type = list(object({
    node_port  = number
    port_poste = number
  }))
  default = [
    { node_port = 30443, port_poste = 8443 }, # frontal VéloCité, environnement dev
    { node_port = 30444, port_poste = 9443 }, # frontal VéloCité, environnement prod
  ]
}
