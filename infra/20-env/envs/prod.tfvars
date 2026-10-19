# Environnement de production : plusieurs réplicas, plus de marge.
env = "prod"

quota = {
  cpu_demande    = "3"
  memoire_limite = "6Gi"
  stockage       = "20Gi"
  nb_pvc         = 6
  nb_pods        = 40
}
