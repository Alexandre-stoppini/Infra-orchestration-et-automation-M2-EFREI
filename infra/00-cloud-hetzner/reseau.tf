# ---------------------------------------------------------------------------
# Réseau : la machine a une adresse publique. Rien n'y entre que par son
# pare-feu, et seulement depuis votre adresse.
#
# Atelier 11, pièce 1 sur 3 : le pare-feu (Fiche_Atelier11_J5, étape 1 ;
# slide 29, le réseau pièce par pièce).
#
# Le bloc est déjà écrit. Il ne vous reste que deux valeurs à décider, dans
# "locals" juste en dessous : chaque endroit à compléter est marqué en
# majuscules ; remplacez la marque par la bonne valeur, sans toucher au reste.
# Quand il n'en reste plus aucune, la pièce est finie. Puis :
#   tofu -chdir=infra/00-cloud-hetzner fmt
# ---------------------------------------------------------------------------
locals {
  # 1.a Les ports ouverts en entrée. À gauche, le numéro du port, en texte
  #     (entre guillemets) ; à droite, à quoi il sert : cette phrase s'affiche
  #     dans la console Hetzner, gardez-la. Trois ports, pas un de plus :
  #     - SSH : scripts/cloud.ps1 envoie le code et construit les images ;
  #     - l'API Kubernetes : kubectl et OpenTofu, depuis votre poste ;
  #     - le frontal de VéloCité, publié en NodePort comme sur kind (son
  #       numéro est dans deploy/overlays/dev/kustomization.yaml).
  #     Les numéros sont sur la slide 29.
  ports_entrants = {
    "A FAIRE port SSH"        = "SSH, pour scripts/cloud.ps1"
    "A FAIRE port API"        = "API Kubernetes, pour kubectl et OpenTofu"
    "A FAIRE port du frontal" = "frontal VéloCité (NodePort)"
  }

  # 1.b D'où ces ports sont joignables : une liste d'UNE seule adresse, la
  #     vôtre, en /32. Ne l'écrivez pas en dur : scripts/cloud.ps1 la lit
  #     pour vous et la donne à OpenTofu dans une variable déjà déclarée
  #     dans variables.tf. Écrivez le nom de cette variable (var.xxx), sans
  #     guillemets, entre les crochets, puis effacez la marque en fin de
  #     ligne (la liste attend une adresse, pas un texte).
  sources_autorisees = [] # A FAIRE 1.b
}

resource "hcloud_firewall" "k3s" {
  name = "${var.eleve}-k3s"

  # Une règle par port de local.ports_entrants : rien d'autre n'entre. Aucune
  # règle "out" : la sortie reste ouverte, la machine télécharge k3s et les
  # images.
  dynamic "rule" {
    for_each = local.ports_entrants
    content {
      description = rule.value
      direction   = "in"
      protocol    = "tcp"
      port        = rule.key
      source_ips  = local.sources_autorisees
    }
  }

  labels = { eleve = var.eleve, projet = "velocite" }

  # Les garde-fous : tofu plan s'arrête ici, en français, si le pare-feu
  # ouvre trop. Ne les retirez pas.
  lifecycle {
    precondition {
      condition     = toset(keys(local.ports_entrants)) == toset(["22", "6443", "30443"])
      error_message = "reseau.tf, ports_entrants : il faut exactement trois ports, ceux de la slide 29, chacun entre guillemets. Un port de plus ouvre la machine à Internet ; un port de moins, et cloud.ps1, kubectl ou le navigateur ne la joignent plus."
    }
    precondition {
      condition     = length(local.sources_autorisees) == 1 && alltrue([for s in local.sources_autorisees : can(cidrhost(s, 0)) && endswith(s, "/32")])
      error_message = "reseau.tf, sources_autorisees : une seule adresse, en /32, et c'est la variable var.mon_ip. Jamais 0.0.0.0/0 ni ::/0 : ce serait ouvrir la machine à tout Internet."
    }
  }
}
