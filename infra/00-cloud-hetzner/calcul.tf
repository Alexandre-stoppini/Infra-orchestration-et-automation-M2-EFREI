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

# ---------------------------------------------------------------------------
# Atelier 11, pièce 2 sur 3 : le serveur (Fiche_Atelier11_J5, étape 2).
#
# Le bloc est déjà écrit, ligne par ligne. Chaque endroit à compléter est
# marqué en majuscules : remplacez la marque par une valeur, sans toucher au
# reste. Quand il n'en reste plus aucune, la pièce est finie. Presque toutes les réponses existent déjà :
# une variable de variables.tf (var.xxx), ou une ressource de ce dossier
# (son id). Écrivez-les sans guillemets : une valeur en dur, recopiée,
# serait fausse dès que la variable change.
# ---------------------------------------------------------------------------
resource "hcloud_server" "k3s" {
  # 2.a Le nom de la machine : celui de votre équipe, que porte une variable
  #     de variables.tf. C'est aussi le nom que cherche scripts/cloud.ps1.
  name = "A FAIRE"

  # 2.b Le système : Ubuntu 24.04 LTS, l'image testée avec k3s pour ce cours.
  image = "ubuntu-24.04"

  # 2.c Le type de machine (son nombre de vCPU, donc son prix) : la variable
  #     de variables.tf qui le porte. Elle est verrouillée sur le type prévu.
  server_type = "A FAIRE"

  # 2.d Le centre de données : la variable de variables.tf qui le porte. Si
  #     Hetzner répond "server type not available", on change la variable
  #     ($env:TF_VAR_emplacement = "fsn1"), jamais cette ligne.
  location = "A FAIRE"

  # 2.e La clé SSH qui ouvrira la machine : l'id de la ressource
  #     hcloud_ssh_key écrite plus haut dans ce fichier, dans une liste.
  ssh_keys = ["A FAIRE"]

  # 2.f Le pare-feu de reseau.tf : son id, dans la liste. Sans lui, la
  #     machine serait joignable par tout Internet sur chacun de ses ports.
  #     Ici la marque est en fin de ligne (la liste attend un nombre, pas un
  #     texte) : écrivez la valeur entre les crochets, puis effacez la marque.
  firewall_ids = [] # A FAIRE 2.f

  # Une adresse IPv4 publique, pas d'IPv6 : le pare-feu ne filtre qu'en IPv4
  # dans ce cours, et une adresse IPv6 coûterait une porte de plus à garder.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # 2.g Le script de premier démarrage, user_data.sh.tftpl (pièce 3), rendu
  #     par templatefile avec une seule valeur : la version de k3s, que porte
  #     une variable de variables.tf.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    version_k3s = "A FAIRE"
  })

  labels = {
    eleve   = var.eleve
    projet  = "velocite"
    jetable = "oui"
  }

  # Les garde-fous : tofu plan s'arrête ici, en français, avant de rien
  # créer. Ne les retirez pas.
  lifecycle {
    precondition {
      condition     = !strcontains(file("${path.module}/user_data.sh.tftpl"), join(" ", ["A", "FAIRE"]))
      error_message = "user_data.sh.tftpl : il reste une valeur à compléter dans le script de premier démarrage (pièce 3). La machine démarrerait sans k3s."
    }
    postcondition {
      condition     = self.name == var.eleve
      error_message = "calcul.tf, name : le nom de la machine est la variable de votre équipe (var.eleve), sans guillemets."
    }
    postcondition {
      condition     = self.server_type == var.type_serveur
      error_message = "calcul.tf, server_type : le type est la variable var.type_serveur, sans guillemets."
    }
    postcondition {
      condition     = self.location == var.emplacement
      error_message = "calcul.tf, location : le centre de données est la variable var.emplacement, sans guillemets."
    }
    postcondition {
      condition     = try(length(self.firewall_ids), 0) > 0
      error_message = "calcul.tf, firewall_ids : la liste est vide. Mettez-y l'id du pare-feu de reseau.tf : sans lui, la machine est ouverte à tout Internet."
    }
    postcondition {
      condition     = self.image == "ubuntu-24.04"
      error_message = "calcul.tf, image : gardez ubuntu-24.04, l'image testée avec k3s pour ce cours."
    }
  }
}
