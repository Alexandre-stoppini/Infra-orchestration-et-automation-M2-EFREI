# Environnement de développement : un réplica par service, petites marges.
env = "dev"

quota = {
  cpu_demande    = "2"
  memoire_limite = "4Gi"
  stockage       = "10Gi"
  nb_pvc         = 6
  nb_pods        = 30
}
