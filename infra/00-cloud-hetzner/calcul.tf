# ---------------------------------------------------------------------------
# Calcul et stockage : un serveur Ubuntu, k3s installé au premier démarrage.
# ---------------------------------------------------------------------------

# La clé SSH naît ici : dans le state (chiffré) et dans un fichier ignoré par Git.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "k3s" {
  name       = var.eleve
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "cle_ssh" {
  filename        = "${path.module}/.cles/${var.eleve}"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# A FAIRE (atelier 11) : le serveur, avec exactement ce nom, que outputs.tf
# et scripts/cloud.ps1 attendent :
#
#   hcloud_server.k3s
#     name         var.eleve
#     image        "ubuntu-24.04"
#     server_type  var.type_serveur ; location : var.emplacement
#     ssh_keys     la clé SSH Hetzner ci-dessus (son id)
#     firewall_ids le pare-feu de reseau.tf (son id) : sans lui, la machine
#                  serait joignable par tout Internet sur chacun de ses ports
#     public_net   une adresse IPv4 publique, pas d'IPv6 (bloc public_net,
#                  ipv4_enabled et ipv6_enabled)
#     user_data    le script de premier démarrage, user_data.sh.tftpl, rendu
#                  par templatefile avec une seule valeur :
#                  version_k3s = var.version_k3s
#     labels       { eleve = var.eleve, projet = "velocite", jetable = "oui" }
#
# Documentation : https://search.opentofu.org/provider/hetznercloud/hcloud/latest
# (ressource hcloud_server).
