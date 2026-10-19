# ---------------------------------------------------------------------------
# Couche 00 - le cluster.
#
# Compute : un control-plane et des workers (des conteneurs Docker, ici).
# Réseau  : sous-réseaux des pods et des services, ports publiés sur le poste.
# Stockage : la classe de stockage "standard" de kind (local-path), utilisée
#            par les volumes persistants des bases.
#
# Cette couche change rarement. La détruire détruit tout ce qui est au-dessus.
# ---------------------------------------------------------------------------

# A FAIRE (atelier 3) : une ressource kind_cluster nommée "velocite" qui
#   1. prend son nom dans var.nom_cluster et son image dans var.image_noeud ;
#   2. attend que le cluster soit prêt avant de rendre la main ;
#   3. fixe les sous-réseaux : pods 10.244.0.0/16, services 10.96.0.0/12 ;
#   4. déclare un noeud control-plane qui publie chaque élément de
#      var.ports_exposes (port de noeud vers port du poste), sur 127.0.0.1
#      seulement : un bloc "dynamic" évite de répéter le bloc ;
#   5. ajoute var.nb_workers noeuds worker, étiquetés
#      velocite.fr/pool = applicatif (encore un bloc "dynamic").
#
# Documentation du provider : https://search.opentofu.org/provider/tehcyx/kind/latest
# (onglet Documentation, ressource kind_cluster, bloc kind_config).
