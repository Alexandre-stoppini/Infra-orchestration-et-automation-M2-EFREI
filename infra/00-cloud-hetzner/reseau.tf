# ---------------------------------------------------------------------------
# Réseau : la machine a une adresse publique. Rien n'y entre que par son
# pare-feu, et seulement depuis votre adresse.
#
# A FAIRE (atelier 11) : une ressource, avec exactement ce nom (calcul.tf
# s'appuie sur hcloud_firewall.k3s) :
#
#   hcloud_firewall.k3s
#     nom "${var.eleve}-k3s" ; trois règles en entrée (direction "in",
#     protocole "tcp"), chacune depuis var.mon_ip seulement :
#       22     SSH, pour que scripts/cloud.ps1 pilote la machine ;
#       6443   l'API Kubernetes, pour kubectl et OpenTofu depuis votre poste ;
#       30443  le frontal de VéloCité, en NodePort, comme sur kind.
#     Rien d'autre en entrée. La sortie reste ouverte (Hetzner l'autorise
#     tant qu'aucune règle "out" n'est écrite) : la machine télécharge k3s
#     et les images.
#     labels = { eleve = var.eleve, projet = "velocite" }
#
# Documentation : https://search.opentofu.org/provider/hetznercloud/hcloud/latest
# (ressource hcloud_firewall, bloc rule : direction, protocol, port,
# source_ips).
# ---------------------------------------------------------------------------
